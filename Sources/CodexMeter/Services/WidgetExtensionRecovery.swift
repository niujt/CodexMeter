import Foundation
import Darwin
import WidgetKit

/// Recover an extension left alive across an in-place app update. Never target
/// WidgetKit's host, another installation, another user, or a current process.
enum WidgetExtensionRecovery {
    struct ProcessIdentity: Equatable {
        let pid: pid_t
        let executablePath: String
        let startedAt: Date
        let userID: uid_t

        func predatesInstalledBinary(at path: String, modifiedAt: Date, userID: uid_t) -> Bool {
            pid > 1 && executablePath == path && self.userID == userID && startedAt < modifiedAt
        }
    }

    @MainActor
    static func recoverAfterUpdate(bundle: Bundle = .main) {
        guard let plugins = bundle.builtInPlugInsURL,
              let widget = Bundle(url: plugins.appendingPathComponent("CodexMeterWidget.appex")),
              widget.bundleIdentifier == "com.codexmeter.CodexMeter.WidgetV4",
              let executable = widget.executableURL,
              let modifiedAt = try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            return
        }
        let path = executable.standardizedFileURL.path
        let retired = retireOutdatedProcesses(at: path, modifiedAt: modifiedAt)
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
    static func retireOutdatedProcesses(at path: String, modifiedAt: Date) -> [pid_t] {
        let userID = getuid()
        var retired: [pid_t] = []
        for process in processes(at: path) {
            guard process.predatesInstalledBinary(at: path, modifiedAt: modifiedAt, userID: userID),
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
            guard pid > 1, executablePath(pid) == path else { return nil }
            return identity(pid)
        }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is the C expression (4 * MAXPATHLEN),
        // which Swift's Clang importer doesn't expose as a constant.
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = bytes.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func identity(_ pid: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size,
              let path = executablePath(pid) else { return nil }
        return ProcessIdentity(pid: pid, executablePath: path,
            startedAt: Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000),
            userID: info.pbi_uid)
    }
}
