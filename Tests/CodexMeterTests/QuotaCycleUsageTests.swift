import Foundation
import Testing
@testable import CodexMeter

struct QuotaCycleUsageTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func line(_ offset: Double, total: Int, reset: Date?, used: Int = 10,
                      model: String = "main", limit: String = "codex") throws -> String {
        var payload: [String: Any] = ["type": "token_count", "info": [
            "total_token_usage": ["total_tokens": total, "input_tokens": total]]]
        if let reset {
            payload["rate_limits"] = ["limit_id": limit, "primary": [
                "used_percent": used, "window_minutes": 10_080, "resets_at": reset.timeIntervalSince1970]]
        }
        let date = ISO8601DateFormatter().string(from: now.addingTimeInterval(offset))
        let context: [String: Any] = ["timestamp": date, "type": "turn_context", "payload": ["model": model]]
        let event: [String: Any] = ["timestamp": date, "type": "event_msg", "payload": payload]
        return try [context, event].map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
    }

    @Test func separatesSameDayResetsAndAccumulatesDeltasAcrossSessionsAndRestart() async throws {
        let root = TestFixtureDirectory.root.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("a.jsonl")
        let resetA = now.addingTimeInterval(86_400)
        let resetB = resetA.addingTimeInterval(600)
        let lines = try [line(-600, total: 100, reset: resetA, used: 80),
                         line(-500, total: 150, reset: resetA, used: 90),
                         line(-400, total: 200, reset: resetB, used: 0),
                         line(-300, total: 250, reset: nil)]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try line(-200, total: 30, reset: resetB).write(to: sessions.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        let reader = CodexUsageReader(cacheDirectory: cache)
        let first = try await reader.load(now: now, codexHome: root)
        #expect(first.rateTimeline.count == 2)
        #expect(first.rateTimeline.first { $0.resetsAt == resetA }?.tokens == 150)
        #expect(first.rateTimeline.first { $0.resetsAt == resetB }?.tokens == 130)
        let repeated = try await reader.load(now: now, codexHome: root)
        #expect(repeated == first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        // A session counter reset still contributes its full new delta to the quota cycle.
        try handle.write(contentsOf: Data((line(-100, total: 20, reset: resetB) + "\n").utf8))
        try handle.close()
        let restarted = CodexUsageReader(cacheDirectory: cache)
        let updated = try await restarted.load(now: now, codexHome: root)
        #expect(await restarted.incrementalFileCount == 1)
        #expect(updated.rateTimeline.first { $0.resetsAt == resetA }?.tokens == 150)
        #expect(updated.rateTimeline.first { $0.resetsAt == resetB }?.tokens == 150)
        let forced = try await restarted.load(now: now, codexHome: root, force: true)
        #expect(forced == updated)
    }

    @Test func respectsAccountBoundaryFutureEventsAndSeparateQuotaBuckets() async throws {
        let root = TestFixtureDirectory.root.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let reset = now.addingTimeInterval(86_400)
        let lines = try [line(-600, total: 100, reset: reset),
                         line(-400, total: 140, reset: reset),
                         line(-300, total: 150, reset: reset, model: "codex-spark"),
                         line(-200, total: 170, reset: reset, model: "alternate", limit: "other"),
                         line(100, total: 200, reset: reset)]
        try lines.joined(separator: "\n").write(to: sessions.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let reader = CodexUsageReader()
        let snapshot = try await reader.load(now: now, codexHome: root, quotaSince: now.addingTimeInterval(-500))
        #expect(snapshot.rateTimeline.count == 1)
        #expect(snapshot.rateTimeline.first?.tokens == 40)
        let later = try await reader.load(now: now.addingTimeInterval(100), codexHome: root, quotaSince: now.addingTimeInterval(-500))
        #expect(later.rateTimeline.first?.tokens == 70)
    }
}
