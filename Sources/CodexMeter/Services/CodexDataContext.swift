import CryptoKit
import Darwin
import Dispatch
import Foundation

struct CodexDataSource: Equatable, Sendable {
    let root: URL
    let home: URL?
    let id: String

    init(root: URL, fileManager: FileManager = .default) {
        let normalized = root.standardizedFileURL.resolvingSymlinksInPath()
        self.root = normalized
        id = Self.digest(normalized.path)
        let isSessionDirectory = ["sessions", "archived_sessions"].contains(normalized.lastPathComponent)
        let isHome = normalized.lastPathComponent == ".codex" || ["sessions", "archived_sessions", "auth.json", "hooks.json"].contains {
            fileManager.fileExists(atPath: normalized.appendingPathComponent($0).path)
        }
        // A grant for a session directory does not grant access to its parent.
        home = !isSessionDirectory && isHome ? normalized : nil
    }

    static func defaultRoot(bundlePath: String? = Bundle.main.object(forInfoDictionaryKey: "CodexHome") as? String,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let bundlePath, !bundlePath.isEmpty { return URL(fileURLWithPath: bundlePath, isDirectory: true) }
        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return (environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? userHome)
            .appendingPathComponent(".codex", isDirectory: true)
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func permissionPaths(monitorBase: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-monitor")) -> PermissionPaths? {
        home.map { PermissionPaths(codexHome: $0, monitorHome: monitorBase.appendingPathComponent("sources/\(id)", isDirectory: true)) }
    }
}

/// Login secrets stay in memory for a request; only a digest is used for cache identity.
struct CodexCredentials: Sendable {
    let token: String
    let accountID: String
    let identity: String
    let modifiedAt: Date
    let revision: String

    private struct Auth: Decodable {
        struct Tokens: Decodable {
            let access_token: String
            let account_id: String
            let id_token: String?
        }
        let tokens: Tokens
        let auth_mode: String?
        let OPENAI_API_KEY: String?
    }

    static func read(home: URL?) -> Self? {
        guard let home else { return nil }
        let url = home.appendingPathComponent("auth.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
              let data = try? Data(contentsOf: url),
              let auth = try? JSONDecoder().decode(Auth.self, from: data),
              auth.auth_mode == nil || auth.auth_mode == "chatgpt",
              auth.OPENAI_API_KEY?.isEmpty != false,
              !auth.tokens.access_token.isEmpty, !auth.tokens.account_id.isEmpty else { return nil }
        // The unverified JWT is only a local partition hint, never an authorization check.
        let subject = jwtSubject(auth.tokens.id_token) ?? jwtSubject(auth.tokens.access_token) ?? CodexDataSource.digest(auth.tokens.access_token)
        let modifiedAt = attributes[.modificationDate] as? Date ?? .now
        return Self(token: auth.tokens.access_token, accountID: auth.tokens.account_id,
                    identity: CodexDataSource.digest(auth.tokens.account_id + "\u{0}" + subject),
                    modifiedAt: modifiedAt,
                    revision: CodexDataSource.digest(String(modifiedAt.timeIntervalSince1970) + data.base64EncodedString()))
    }

    private static func jwtSubject(_ token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["sub"] as? String
    }
}

struct QuotaScope: Equatable, Sendable {
    let id: String
    let since: Date
}

struct CodexDataContext: Equatable, Sendable {
    let source: CodexDataSource
    let accountIdentity: String?
    let since: Date
    var id: String { CodexDataSource.digest(source.id + (accountIdentity ?? "unknown") + String(since.timeIntervalSince1970)) }
    var quotaScope: QuotaScope? { accountIdentity.map { _ in QuotaScope(id: id, since: since) } }

    static func resolve(source: CodexDataSource, defaults: UserDefaults, now: Date = .now,
                        initialObservation: Bool = false) -> Self {
        struct Record: Codable { let account: String?; let since: Date; let revision: String? }
        let credentials = CodexCredentials.read(home: source.home)
        let key = "codexMeter.accountScope.v1." + source.id
        let prior = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        let record: Record
        if let prior, prior.account == credentials?.identity {
            // While not observing this directory, a switch away and back is
            // indistinguishable from token refresh. Bound unlabelled quotas again.
            let changedWhileAway = initialObservation && prior.revision != credentials?.revision
            let since = changedWhileAway ? max(prior.since, credentials?.modifiedAt ?? now) : prior.since
            record = Record(account: prior.account, since: since, revision: credentials?.revision)
        } else {
            // Unlabelled session quotas preceding a login change cannot be attributed safely.
            record = Record(account: credentials?.identity, since: prior == nil ? (credentials?.modifiedAt ?? now) : now,
                            revision: credentials?.revision)
        }
        if prior?.account != record.account || prior?.since != record.since || prior?.revision != record.revision,
           let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: key) }
        return Self(source: source, accountIdentity: record.account, since: record.since)
    }
}

/// Watch only the selected home and its auth file, including atomic auth replacement.
@MainActor
final class CodexAccountMonitor {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var generation = UUID()
    func stop() { generation = UUID(); sources.forEach { $0.cancel() }; sources = [] }
    func watch(home: URL?, onChange: @escaping @MainActor @Sendable () -> Void) {
        stop()
        guard let home else { return }
        let request = generation
        for url in [home, home.appendingPathComponent("auth.json")] {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete, .attrib], queue: .global(qos: .utility))
            source.setEventHandler { @Sendable [weak self] in
                Task { @MainActor [weak self] in
                    guard self?.generation == request else { return }
                    onChange()
                }
            }
            source.setCancelHandler { @Sendable in close(descriptor) }
            sources.append(source)
            source.resume()
        }
    }
}
