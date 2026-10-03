import Foundation
import Testing
@testable import CodexMeter

struct EnergyEfficiencyTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    @MainActor @Test func emptyPermissionHistoryHasNoWritesOrMaintenanceDeadline() throws {
        let fixture = try permissionFixture()
        let store = PermissionStore(persistenceURL: fixture.file, defaults: fixture.defaults)
        for tick in 0..<120 {
            store.expireAndPrune(now: now.addingTimeInterval(Double(tick) * 30))
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
        #expect(store.nextMaintenanceDate(now: now) == nil)
    }

    @MainActor @Test func permissionsWriteOnlyOnActualExpiryAndScheduleRetentionOnce() throws {
        let fixture = try permissionFixture()
        let store = PermissionStore(persistenceURL: fixture.file, defaults: fixture.defaults)
        let event = CodexPermissionEvent(eventId: "synthetic", receivedAt: now,
            sessionId: "demo", turnId: "turn", project: .init(name: "Demo", cwd: "/demo"),
            permission: .init(mode: "default", toolName: "Bash"), codex: .init(model: "test"))
        #expect(store.ingest(event, now: now) == .inserted)
        #expect(store.nextMaintenanceDate(now: now) == now.addingTimeInterval(300))
        let marker = now.addingTimeInterval(-86_400)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: fixture.file.path)
        store.expireAndPrune(now: now.addingTimeInterval(299))
        let unchangedDate = try FileManager.default.attributesOfItem(atPath: fixture.file.path)[.modificationDate] as? Date
        #expect(unchangedDate == marker)
        #expect(store.events.first?.status == .new)
        store.expireAndPrune(now: now.addingTimeInterval(300))
        #expect(store.events.first?.status == .expired)
        let persisted = try JSONDecoder().decode([CodexPermissionEvent].self, from: Data(contentsOf: fixture.file))
        #expect(persisted.first?.status == .expired)
        #expect(store.nextMaintenanceDate(now: now.addingTimeInterval(300)) == now.addingTimeInterval(86_400.001))
        store.expireAndPrune(now: now.addingTimeInterval(86_401))
        #expect(store.events.isEmpty)
        #expect(store.nextMaintenanceDate(now: now.addingTimeInterval(86_401)) == nil)
    }

    @Test func backgroundAndPowerPressureSlowRefreshWithoutIgnoringUserInterval() {
        #expect(RefreshPolicy.energyInterval(configured: 300, foreground: true, lowPower: false, thermalState: .nominal) == 300)
        #expect(RefreshPolicy.energyInterval(configured: 300, foreground: false, lowPower: false, thermalState: .nominal) == 900)
        #expect(RefreshPolicy.energyInterval(configured: 300, foreground: false, lowPower: true, thermalState: .nominal) == 1_800)
        #expect(RefreshPolicy.energyInterval(configured: 300, foreground: true, lowPower: false, thermalState: .serious) == 3_600)
        #expect(RefreshPolicy.energyInterval(configured: 300, foreground: false, lowPower: true, thermalState: .critical) == 3_600)
        #expect(RefreshPolicy.energyInterval(configured: 7_200, foreground: false, lowPower: true, thermalState: .critical) == 7_200)
    }

    @Test func unchangedQuotaNeverWritesDefaultsAgain() throws {
        let defaults = try #require(CountingDefaults(suiteName: "codexmeter-energy-test-" + UUID().uuidString))
        var snapshot = UsageSnapshot.empty
        snapshot.mainMenuRate = RateWindow(usedPercent: 5, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400))
        snapshot.lastUpdated = now
        QuotaRateCache.save(snapshot, defaults: defaults, now: now)
        let initialWrites = defaults.writeCount
        #expect(initialWrites == 1)
        for tick in 1...120 { QuotaRateCache.save(snapshot, defaults: defaults, now: now.addingTimeInterval(Double(tick))) }
        #expect(defaults.writeCount == initialWrites)
        snapshot.mainMenuRate = RateWindow(usedPercent: 6, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400))
        QuotaRateCache.save(snapshot, defaults: defaults, now: now)
        #expect(defaults.writeCount == initialWrites + 1)
    }

    @Test func speedRedrawsStopWhenSamplesExpireAndCoalesceBurstCompletions() {
        #expect(RecentReplySpeed.refreshDates([], now: now) == [now])
        let expired = ReplySpeedSample(completedAt: now.addingTimeInterval(-901), outputTokens: 100, turnSeconds: 10)
        let future = ReplySpeedSample(completedAt: now.addingTimeInterval(1), outputTokens: 100, turnSeconds: 10)
        #expect(RecentReplySpeed.refreshDates([expired, future], now: now) == [now])
        let samples = (0..<899).map { ReplySpeedSample(completedAt: now.addingTimeInterval(-Double($0)), outputTokens: 100, turnSeconds: 10) }
        let dates = RecentReplySpeed.refreshDates(samples, now: now)
        #expect(dates.first == now)
        #expect(dates.count <= 17)
        #expect(dates == dates.sorted())
        #expect(RecentReplySpeed.refreshDates(samples, now: now.addingTimeInterval(960)) == [now.addingTimeInterval(960)])
    }

    @Test func scannerSkipsPluginsAndRootHistoryButKeepsActiveAndArchivedSessions() async throws {
        let base = try tempDirectory()
        let root = base.appendingPathComponent(".codex", isDirectory: true)
        let session = root.appendingPathComponent("sessions/2026/10/03", isDirectory: true)
        let archive = root.appendingPathComponent("archived_sessions", isDirectory: true)
        let plugins = root.appendingPathComponent("plugins/cache/many", isDirectory: true)
        for directory in [session, archive, plugins] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let line = try tokenLine()
        try line.write(to: session.appendingPathComponent("active.jsonl"), atomically: true, encoding: .utf8)
        try line.write(to: archive.appendingPathComponent("old.jsonl"), atomically: true, encoding: .utf8)
        try line.write(to: root.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)
        for index in 0..<200 { try line.write(to: plugins.appendingPathComponent("unrelated-\(index).jsonl"), atomically: true, encoding: .utf8) }
        let reader = CodexUsageReader()
        let snapshot = try await reader.load(now: now, codexHome: root)
        #expect(snapshot.fileCount == 2)
        #expect(snapshot.allTime.total == 200)
        #expect(await reader.enumeratedEntryCount < 12)
        #expect(await reader.parsedFileCount == 2)
    }

    private final class CountingDefaults: UserDefaults, @unchecked Sendable {
        var writeCount = 0
        override func set(_ value: Any?, forKey key: String) {
            writeCount += 1
            super.set(value, forKey: key)
        }
    }

    private func permissionFixture() throws -> (file: URL, defaults: UserDefaults) {
        let directory = try tempDirectory()
        let defaults = try #require(UserDefaults(suiteName: "codexmeter-permission-energy-" + UUID().uuidString))
        defaults.register(defaults: [PermissionPreferences.retentionHoursKey: 24])
        return (directory.appendingPathComponent("events.json"), defaults)
    }

    private func tempDirectory() throws -> URL {
        // Synthetic inputs only; retain artifacts rather than deleting them.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codexmeter-energy-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tokenLine() throws -> String {
        let json: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: now), "type": "event_msg",
            "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 90, "output_tokens": 10, "total_tokens": 100]]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self) + "\n"
    }
}
