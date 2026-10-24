import Foundation
import Darwin
import Security
import WidgetKit

/// Recover an extension left alive across an in-place app update. Never target
/// WidgetKit's host, another installation, another user, or a current process.
enum WidgetExtensionRecovery {
    struct CodeIdentity: Equatable {
        let identifier: String
        let teamID: String?
        let hash: Data
    }

    struct ProcessIdentity: Equatable {
        let pid: pid_t
        let executablePath: String
        let startedAt: Date
        let userID: uid_t
        let code: CodeIdentity
        var originalExecutablePath: String? = nil

        func requiresReplacement(at path: String, installedCode: CodeIdentity, userID: uid_t) -> Bool {
            pid > 1 && (executablePath == path || originalExecutablePath == path) && self.userID == userID
                && code.identifier == installedCode.identifier && code.teamID == installedCode.teamID
                && code.hash != installedCode.hash
        }
    }

    @MainActor
    static func recoverAfterUpdate(bundle: Bundle = .main) {
        guard let plugins = bundle.builtInPlugInsURL,
              let widget = Bundle(url: plugins.appendingPathComponent("CodexMeterWidget.appex")),
              widget.bundleIdentifier == "com.codexmeter.CodexMeter.WidgetV4",
              let executable = widget.executableURL,
              let installedCode = installedCode(at: executable.path),
              installedCode.identifier == widget.bundleIdentifier else {
            return
        }
        let path = executable.standardizedFileURL.path
        let retired = retireOutdatedProcesses(at: path)
        // Also replace archived views when the cache's displayed values haven't
        // changed. A relaunch must not depend on saveIfChanged writing the file.
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetUsageCache.kind)
        if !retired.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetUsageCache.kind)
            }
        }
    }

    @discardableResult
    static func retireOutdatedProcesses(at path: String, installedCode override: CodeIdentity? = nil) -> [pid_t] {
        let userID = getuid()
        var retired: [pid_t] = []
        for process in processes(at: path) {
            guard let installedCode = override ?? installedCode(at: path, processID: process.pid),
                  process.requiresReplacement(at: path, installedCode: installedCode, userID: userID),
                  identity(process.pid) == process else { continue }
            // Recheck identity immediately before SIGTERM to avoid PID reuse.
            if kill(process.pid, SIGTERM) == 0 { retired.append(process.pid) }
        }
        return retired
    }

    private static func processes(at path: String) -> [ProcessIdentity] {
        let capacity = max(32, Int(proc_listallpids(nil, 0)) + 32)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        return pids.prefix(max(0, Int(count))).compactMap { pid in
            // Moving the old bundle into a backup changes proc_pidpath even
            // though this process was launched from the current installation.
            guard pid > 1,
                  executablePath(pid) == path || originalExecutablePath(pid) == path else { return nil }
            return identity(pid)
        }
    }

    static func executablePath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is the C expression (4 * MAXPATHLEN),
        // which Swift's Clang importer doesn't expose as a constant.
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = bytes.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else {
            // Sparkle unlinks the previous executable. proc_pidpath then returns
            // ENOENT although the extension is still running. The kernel's exec
            // path in KERN_PROCARGS2 survives replacement; never use argv[0].
            guard errno == ENOENT else { return nil }
            return originalExecutablePath(pid)
        }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func originalExecutablePath(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var count = 0
        guard sysctl(&mib, 3, nil, &count, nil, 0) == 0,
              count > MemoryLayout<Int32>.size, count <= 1_048_576 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        guard sysctl(&mib, 3, &bytes, &count, nil, 0) == 0 else { return nil }
        guard let path = originalExecutablePath(from: Array(bytes.prefix(count))) else { return nil }
        // Foundation may launch through /var while proc_pidpath reports
        // /private/var. Resolve an existing installation before comparing paths;
        // retain the kernel path when an update has unlinked the executable.
        guard let canonical = realpath(path, nil) else { return path }
        defer { free(canonical) }
        return String(cString: canonical)
    }

    static func originalExecutablePath(from bytes: [UInt8]) -> String? {
        let path = bytes.dropFirst(MemoryLayout<Int32>.size).prefix { $0 != 0 }
        guard !path.isEmpty, path.first == UInt8(ascii: "/"),
              bytes.count > MemoryLayout<Int32>.size + path.count,
              let value = String(bytes: path, encoding: .utf8) else { return nil }
        return value
    }

    static func identity(_ pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              let path = executablePath(pid), let code = runningCode(pid) else { return nil }
        return ProcessIdentity(pid: pid, executablePath: path,
            startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000),
            userID: info.pbi_uid, code: code, originalExecutablePath: originalExecutablePath(pid))
    }

    static func installedCode(at path: String, processID: pid_t? = nil) -> CodeIdentity? {
        var code: SecStaticCode?
        var attributes: [CFString: Any] = [:]
        if let processID {
            var architecture = proc_archinfo()
            let size = MemoryLayout<proc_archinfo>.size
            guard proc_pidinfo(processID, PROC_PIDARCHINFO, 0, &architecture, Int32(size)) == size else { return nil }
            // Compare the slice actually running, including Rosetta and arm64e
            // subtypes; a native default could otherwise retire current code.
            attributes[kSecCodeAttributeArchitecture] = architecture.p_cputype
            attributes[kSecCodeAttributeSubarchitecture] = architecture.p_cpusubtype
        }
        guard SecStaticCodeCreateWithPathAndAttributes(URL(fileURLWithPath: path) as CFURL, [], attributes as CFDictionary, &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let hash = values[kSecCodeInfoUnique as String] as? Data, hash.count == 20 else { return nil }
        return CodeIdentity(identifier: identifier, teamID: values[kSecCodeInfoTeamIdentifier as String] as? String, hash: hash)
    }

    // Security's guest lookup also fails for an unlinked executable. Read the
    // kernel's live code-signing identity instead of consulting the replaced file.
    private typealias CodeSigningQuery = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
    private static let codeSigningQuery: CodeSigningQuery? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") else { return nil }
        return unsafeBitCast(symbol, to: CodeSigningQuery.self)
    }()

    private static func runningCode(_ pid: pid_t) -> CodeIdentity? {
        guard let query = codeSigningQuery else { return nil }
        var hash = [UInt8](repeating: 0, count: 20)
        guard query(pid, 5 /* CS_OPS_CDHASH */, &hash, hash.count) == 0,
              let identifier = signingString(pid, operation: 11 /* CS_OPS_IDENTITY */) else { return nil }
        return CodeIdentity(identifier: identifier, teamID: signingString(pid, operation: 14 /* CS_OPS_TEAMID */), hash: Data(hash))
    }

    private static func signingString(_ pid: pid_t, operation: UInt32) -> String? {
        guard let query = codeSigningQuery else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4_096)
        guard query(pid, operation, &bytes, bytes.count) == 0 else { return nil }
        let count = bytes[4..<8].reduce(0) { ($0 << 8) | Int($1) }
        guard count > 8, count <= bytes.count else { return nil }
        let value = bytes[8..<count].prefix { $0 != 0 }
        return value.isEmpty ? nil : String(bytes: value, encoding: .utf8)
    }
}
