import Foundation
import Testing
@testable import CodexMeter

struct UsageCacheTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    @Test func restartReusesAllSummariesWithoutStoringConversationText() async throws {
        let fixture = try makeFixture()
        let first = reader(fixture)
        let original = try await first.load(now: now, codexHome: fixture.root)
        #expect(await first.parsedFileCount == 2)
        #expect(await first.reusedFileCount == 0)
        let warm = try await first.load(now: now, codexHome: fixture.root)
        #expect(await first.parsedFileCount == 0)
        #expect(await first.reusedFileCount == 2)
        #expect(warm == original)

        let restarted = reader(fixture)
        let restored = try await restarted.load(now: now, codexHome: fixture.root)
        #expect(await restarted.parsedFileCount == 0)
        #expect(await restarted.reusedFileCount == 2)
        #expect(restored == original)
        #expect(restored.today.total == 430)
        #expect(restored.panelModels.first?.averageTurnSeconds == 20)
        #expect(RecentReplySpeed.summarize(restored.replySpeedSamples, now: now)?.tokensPerSecond == 3)
        let cacheFiles = try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil)
        let data = try Data(contentsOf: #require(cacheFiles.first))
        #expect(data.range(of: Data("NEVER_STORE_THIS_SENTENCE".utf8)) == nil)
    }

    @Test func changedFileIsTheOnlyFileReadAfterRestart() async throws {
        let fixture = try makeFixture()
        _ = try await reader(fixture).load(now: now, codexHome: fixture.root)
        let handle = try FileHandle(forWritingTo: fixture.root.appendingPathComponent("a.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((token(offset: -1, output: 120) + "\n").utf8))
        try handle.close()
        let restarted = reader(fixture)
        let loaded = try await restarted.load(now: now, codexHome: fixture.root)
        #expect(await restarted.parsedFileCount == 1)
        #expect(await restarted.reusedFileCount == 1)
        #expect(loaded.allTime.total == 450)
        let reference = try await CodexUsageReader(calendar: calendar).load(now: now, codexHome: fixture.root)
        #expect(loaded == reference)
    }

    @Test func progressSeparatesFilesCheckedFromFilesActuallyRead() async throws {
        let fixture = try makeFixture()
        let reader = reader(fixture)
        let progress = ProgressRecorder()
        _ = try await reader.loadWithActivity(now: now, codexHome: fixture.root, onActivity: { read, reused in
            await progress.recordActivity(read: read, reused: reused)
        }, onProgress: { _, checked, total in
            await progress.recordProgress(checked: checked, total: total)
        })
        #expect(await progress.read == 2)
        #expect(await progress.reused == 0)
        _ = try await reader.loadWithActivity(now: now, codexHome: fixture.root, onActivity: { read, reused in
            await progress.recordActivity(read: read, reused: reused)
        }, onProgress: { _, checked, total in
            await progress.recordProgress(checked: checked, total: total)
        })
        #expect(await progress.checked == 2)
        #expect(await progress.total == 2)
        #expect(await progress.read == 0)
        #expect(await progress.reused == 2)
    }

    private actor ProgressRecorder {
        var read = 0
        var reused = 0
        var checked = 0
        var total = 0
        func recordActivity(read: Int, reused: Int) { self.read = read; self.reused = reused }
        func recordProgress(checked: Int, total: Int) { self.checked = checked; self.total = total }
    }

    @Test func restartRecalculatesCalendarTotalsAndExpiresSpeedSamples() async throws {
        let fixture = try makeFixture()
        let original = try await reader(fixture).load(now: now, codexHome: fixture.root)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let restarted = reader(fixture)
        let loaded = try await restarted.load(now: tomorrow, codexHome: fixture.root)
        #expect(await restarted.parsedFileCount == 0)
        #expect(loaded.allTime == original.allTime)
        #expect(loaded.today.total == 0)
        #expect(loaded.replySpeedSamples.isEmpty)
        let reference = try await CodexUsageReader(calendar: calendar).load(now: tomorrow, codexHome: fixture.root)
        #expect(loaded == reference)
    }

    @Test func corruptCacheAndForceRefreshRebuildFromSource() async throws {
        let fixture = try makeFixture()
        let original = try await reader(fixture).load(now: now, codexHome: fixture.root)
        let files = try FileManager.default.contentsOfDirectory(at: fixture.cache, includingPropertiesForKeys: nil)
        try Data("invalid cache".utf8).write(to: #require(files.first))
        let rebuilding = reader(fixture)
        #expect(try await rebuilding.load(now: now, codexHome: fixture.root) == original)
        #expect(await rebuilding.parsedFileCount == 2)
        #expect(try await rebuilding.load(now: now, codexHome: fixture.root, force: true) == original)
        #expect(await rebuilding.parsedFileCount == 2)
        let restarted = reader(fixture)
        _ = try await restarted.load(now: now, codexHome: fixture.root)
        #expect(await restarted.parsedFileCount == 0)
    }

    @Test func rootAndTimeZoneChangesNeverReuseWrongAggregates() async throws {
        let fixture = try makeFixture()
        let first = reader(fixture)
        let original = try await first.load(now: now, codexHome: fixture.root)
        let other = fixture.root.deletingLastPathComponent().appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try (token(offset: -1, output: 300) + "\n").write(to: other.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let otherSnapshot = try await first.load(now: now, codexHome: other)
        #expect(otherSnapshot.allTime.total == 400)
        #expect(await first.parsedFileCount == 1)
        #expect(try await first.load(now: now, codexHome: fixture.root) == original)
        #expect(await first.parsedFileCount == 0)
        var changedCalendar = calendar
        changedCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let changedZone = CodexUsageReader(calendar: changedCalendar, cacheDirectory: fixture.cache)
        _ = try await changedZone.load(now: now, codexHome: fixture.root)
        #expect(await changedZone.parsedFileCount == 2)
    }

    @Test func missingFilesArePrunedAndUnwritableCacheDoesNotBlockUsage() async throws {
        let fixture = try makeFixture()
        _ = try await reader(fixture).load(now: now, codexHome: fixture.root)
        // Move the synthetic fixture aside rather than deleting anything.
        try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("b.jsonl"),
                                         to: fixture.root.appendingPathComponent("b.saved"))
        let restarted = reader(fixture)
        let loaded = try await restarted.load(now: now, codexHome: fixture.root)
        #expect(loaded.fileCount == 1)
        #expect(loaded.allTime.total == 200)
        #expect(await restarted.parsedFileCount == 0)
        let reference = try await CodexUsageReader(calendar: calendar).load(now: now, codexHome: fixture.root)
        #expect(loaded == reference)
        let blocked = fixture.root.deletingLastPathComponent().appendingPathComponent("blocked-cache")
        try Data("not a directory".utf8).write(to: blocked)
        let uncached = CodexUsageReader(calendar: calendar, cacheDirectory: blocked)
        #expect(try await uncached.load(now: now, codexHome: fixture.root) == reference)
        #expect(await uncached.cacheWarning != nil)
        try FileManager.default.moveItem(at: blocked, to: blocked.appendingPathExtension("saved"))
        #expect(try await uncached.load(now: now, codexHome: fixture.root) == reference)
        #expect(await uncached.parsedFileCount == 0)
        #expect(await uncached.cacheWarning == nil)
        let recovered = CodexUsageReader(calendar: calendar, cacheDirectory: blocked)
        _ = try await recovered.load(now: now, codexHome: fixture.root)
        #expect(await recovered.parsedFileCount == 0)
    }

    private struct Fixture { let root: URL; let cache: URL }

    private func reader(_ fixture: Fixture) -> CodexUsageReader {
        CodexUsageReader(calendar: calendar, cacheDirectory: fixture.cache)
    }

    private func makeFixture() throws -> Fixture {
        // All inputs are synthetic. Retain temp artifacts per the project deletion rule.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codexmeter-cache-test-" + UUID().uuidString)
        let root = base.appendingPathComponent("sessions", isDirectory: true)
        let cache = base.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, output) in [("a", 100), ("b", 130)] {
            let lines = [
                line(offset: -100, type: "session_meta", payload: ["cwd": "/demo/" + name]),
                line(offset: -95, type: "turn_context", payload: ["model": "gpt-test"]),
                token(offset: -90, output: output - 60),
                line(offset: -60, type: "response_item", payload: ["type": "message", "role": "user", "content": "NEVER_STORE_THIS_SENTENCE"]),
                token(offset: -40, output: output),
                line(offset: -40, type: "event_msg", payload: ["type": "task_complete"])
            ]
            try (lines.joined(separator: "\n") + "\n").write(to: root.appendingPathComponent(name + ".jsonl"), atomically: true, encoding: .utf8)
        }
        return Fixture(root: root, cache: cache)
    }

    private func token(offset: Double, output: Int) -> String {
        line(offset: offset, type: "event_msg", payload: ["type": "token_count", "info": [
            "total_token_usage": ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": output, "total_tokens": 100 + output],
            "last_token_usage": ["total_tokens": 30], "model_context_window": 200_000
        ], "rate_limits": ["limit_id": "codex", "secondary": ["used_percent": 5, "window_minutes": 10_080, "resets_at": now.addingTimeInterval(86_400).timeIntervalSince1970]]])
    }

    private func line(offset: Double, type: String, payload: [String: Any]) -> String {
        let json: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)), "type": type, "payload": payload]
        return String(decoding: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self)
    }
}
