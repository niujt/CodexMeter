import Foundation
import Observation
import CryptoKit

@MainActor @Observable
final class DeepSeekBalanceStore {
    static let shared = DeepSeekBalanceStore()
    private(set) var snapshot: DeepSeekBalanceSnapshot?
    private(set) var isRefreshing = false
    private(set) var hasCredential = false
    private(set) var errorMessage: String?
    private(set) var credentialRevision = UUID()
    @ObservationIgnored private let client: DeepSeekBalanceClient
    @ObservationIgnored private let readKey: () throws -> String?
    @ObservationIgnored private let writeKey: (String) throws -> Void
    @ObservationIgnored private var task: Task<DeepSeekBalanceSnapshot, Error>?
    private var generation = UUID()
    private var fingerprint: String?
    private var lastAttempt: Date?

    init(client: DeepSeekBalanceClient = DeepSeekBalanceClient(),
         readKey: @escaping () throws -> String? = { try APIKeychain(provider: .deepSeek).read() },
         writeKey: @escaping (String) throws -> Void = { try APIKeychain(provider: .deepSeek).save($0) }) {
        self.client = client
        self.readKey = readKey
        self.writeKey = writeKey
    }

    func checkCredential() {
        do { _ = try credential() }
        catch { credentialFailed(error) }
    }

    @discardableResult
    func saveCredential(_ text: String) -> Bool {
        do {
            let key = try APIKeychain.extract(from: text)
            try writeKey(key)
            invalidate()
            credentialRevision = UUID()
            fingerprint = Self.digest(key)
            hasCredential = true
            return true
        } catch { errorMessage = DeepSeekBalanceError.safe(error).localizedDescription; return false }
    }

    func refresh(force: Bool = false, now: Date = .now) async {
        let key: String
        do {
            guard let value = try credential() else { return }
            key = value
        } catch { credentialFailed(error); return }
        guard !isRefreshing else { return }
        if !force, let lastAttempt, snapshot != nil,
           now >= lastAttempt, now.timeIntervalSince(lastAttempt) < 300 { return }
        let ticket = generation
        isRefreshing = true
        lastAttempt = now
        errorMessage = nil
        let client = client
        let pending = Task { try await client.load(key: key, now: now) }
        task = pending
        do {
            let loaded = try await pending.value
            guard ticket == generation else { return }
            snapshot = loaded
        } catch is CancellationError {
            // A credential replacement must never receive an earlier account's result.
        } catch {
            guard ticket == generation else { return }
            errorMessage = DeepSeekBalanceError.safe(error).localizedDescription
        }
        guard ticket == generation else { return }
        isRefreshing = false
        task = nil
    }

    private func credential() throws -> String? {
        let key = try readKey()
        let identity = key.map(Self.digest)
        if fingerprint != identity { invalidate(); fingerprint = identity }
        hasCredential = key != nil
        return key
    }

    private func credentialFailed(_ error: Error) {
        invalidate()
        hasCredential = false
        fingerprint = nil
        errorMessage = DeepSeekBalanceError.safe(error).localizedDescription
    }

    private func invalidate() {
        task?.cancel()
        task = nil
        generation = UUID()
        snapshot = nil
        lastAttempt = nil
        isRefreshing = false
        errorMessage = nil
    }

    private static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
