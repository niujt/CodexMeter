import Foundation
import Testing
@testable import CodexMeter

struct PermissionReminderTests {
    @Test
    func sanitizerRedactsSecretsAndLimitsPreview() {
        let raw = "curl 'https://example.test/run?token=url-secret' -H 'Authorization: Bearer header-secret' password=plain-secret"
        let sanitized = PermissionEventSanitizer.sanitizePreview(raw)

        #expect(sanitized?.contains("url-secret") == false)
        #expect(sanitized?.contains("header-secret") == false)
        #expect(sanitized?.contains("plain-secret") == false)
        #expect(sanitized?.contains("***") == true)
        #expect((sanitized?.count ?? 0) <= 240)
    }

    @Test @MainActor
    func storeDeduplicatesWithinThirtySecondsAndExpiresAfterFiveMinutes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "PermissionReminderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(24, forKey: PermissionPreferences.retentionHoursKey)
        let store = PermissionStore(persistenceURL: root.appendingPathComponent("events.json"), defaults: defaults)
        let now = Date.now
        let event = makeEvent(id: "same-event", receivedAt: now)

        #expect(store.ingest(event, now: now) == .inserted)
        #expect(store.ingest(event, now: now.addingTimeInterval(1)) == .duplicate)
        #expect(store.events.count == 1)
        #expect(store.newCount == 1)

        store.expireAndPrune(now: now.addingTimeInterval(301))
        #expect(store.events.first?.status == .expired)
    }

    @Test
    func installerMergesAndUninstallsOnlyOwnedHandler() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let codexHome = root.appendingPathComponent(".codex")
        let monitorHome = root.appendingPathComponent(".codex-monitor")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = PermissionPaths(codexHome: codexHome, monitorHome: monitorHome)
        let original: [String: Any] = [
            "description": "keep me",
            "hooks": [
                "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/tmp/pre-existing"]]]],
                "PermissionRequest": [["matcher": "Bash", "hooks": [["type": "command", "command": "/tmp/existing-permission"]]]]
            ]
        ]
        try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted])
            .write(to: paths.hooksConfig)

        let installer = PermissionHookInstaller(paths: paths)
        try installer.install()
        #expect(installer.status() == .installed)

        let installed = try json(at: paths.hooksConfig)
        let installedHooks = try #require(installed["hooks"] as? [String: Any])
        let permissionGroups = try #require(installedHooks["PermissionRequest"] as? [[String: Any]])
        let commands = permissionGroups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands.contains("/tmp/existing-permission"))
        #expect(commands.filter { $0.contains(PermissionHookInstaller.commandMarker) }.count == 1)
        #expect(installed["description"] as? String == "keep me")

        try installer.install()
        let reinstalled = try json(at: paths.hooksConfig)
        let reinstalledHooks = try #require(reinstalled["hooks"] as? [String: Any])
        let reinstalledGroups = try #require(reinstalledHooks["PermissionRequest"] as? [[String: Any]])
        let reinstalledCommands = reinstalledGroups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(reinstalledCommands.filter { $0.contains(PermissionHookInstaller.commandMarker) }.count == 1)
        let backupsAfterRepeatInstall = try FileManager.default.contentsOfDirectory(atPath: codexHome.path)
            .filter { $0.hasPrefix("hooks.json.codex-monitor-backup-") }
        #expect(backupsAfterRepeatInstall.count == 1)

        try installer.uninstall()
        let uninstalled = try json(at: paths.hooksConfig)
        let uninstalledHooks = try #require(uninstalled["hooks"] as? [String: Any])
        let remainingGroups = try #require(uninstalledHooks["PermissionRequest"] as? [[String: Any]])
        let remainingCommands = remainingGroups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(remainingCommands == ["/tmp/existing-permission"])
        #expect(fileExists(paths.hookScript) == false)
        #expect(uninstalledHooks["PreToolUse"] != nil)
    }

    @Test
    func generatedHookIsFailOpenSilentAndWritesSanitizedEvent() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        #expect(fileExists(python))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = PermissionPaths(
            codexHome: root.appendingPathComponent(".codex"),
            monitorHome: root.appendingPathComponent(".codex-monitor")
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try PermissionHookInstaller(paths: paths).install()

        let input = """
        {"hook_event_name":"PermissionRequest","session_id":"test-session","turn_id":"test-turn","cwd":"/tmp/demo-project","model":"test","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"curl https://example.test?token=top-secret -H 'Authorization: Bearer bearer-secret'","description":"Command requires approval"}}
        """
        let process = Process()
        process.executableURL = python
        process.arguments = [paths.hookScript.path]
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(stdout.fileHandleForReading.readDataToEndOfFile().isEmpty)
        #expect(stderr.fileHandleForReading.readDataToEndOfFile().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: paths.spoolDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let eventFile = try #require(files.first)
        let event = try JSONDecoder().decode(CodexPermissionEvent.self, from: Data(contentsOf: eventFile))
        #expect(event.project.name == "demo-project")
        #expect(event.permission.toolName == "Bash")
        #expect(event.permission.preview?.contains("top-secret") == false)
        #expect(event.permission.preview?.contains("bearer-secret") == false)
    }

    private func makeEvent(id: String, receivedAt: Date) -> CodexPermissionEvent {
        CodexPermissionEvent(
            eventId: id,
            receivedAt: receivedAt,
            sessionId: "session",
            turnId: "turn",
            project: .init(name: "project", cwd: "/tmp/project"),
            permission: .init(mode: "default", toolName: "Bash", description: nil, preview: "echo test"),
            codex: .init(model: "test")
        )
    }

    private func json(at url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
