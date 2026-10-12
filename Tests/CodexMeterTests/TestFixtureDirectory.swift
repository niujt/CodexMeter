import Foundation

/// Synthetic fixtures are retained by default under the project's deletion policy.
enum TestFixtureDirectory {
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HEALTH_TEST_ROOT"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    static func cleanup(_ url: URL) {
        guard ProcessInfo.processInfo.environment["CODEX_HEALTH_TEST_CLEANUP"] == "1",
              url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func cleanupDefaults(_ defaults: UserDefaults, suite: String) {
        guard ProcessInfo.processInfo.environment["CODEX_HEALTH_TEST_CLEANUP"] == "1",
              suite.hasPrefix("CodexMeterTests.") || suite.hasPrefix("PermissionReminderTests.") else { return }
        defaults.removePersistentDomain(forName: suite)
    }
}
