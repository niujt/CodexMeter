import Foundation
import Testing
@testable import CodexMeter

struct CodexUsageReaderTests {
    @Test
    func aggregatesCumulativeSessionTotalsAsDeltas() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/07/27")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            event(timestamp: "2026-07-27T01:00:00.000Z", input: 80, output: 20, total: 100),
            event(timestamp: "2026-07-27T02:00:00.000Z", input: 120, output: 30, total: 150)
        ].joined(separator: "\n")
        try lines.write(
            to: sessions.appendingPathComponent("rollout.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reader = CodexUsageReader(calendar: calendar)
        let now = ISO8601DateFormatter().date(from: "2026-07-27T12:00:00Z")!
        let snapshot = try await reader.load(now: now, codexHome: root)

        #expect(snapshot.today.total == 150)
        #expect(snapshot.today.input == 120)
        #expect(snapshot.today.output == 30)
        #expect(snapshot.sessionCount == 1)
        #expect(snapshot.fileCount == 1)
        #expect(snapshot.primaryRate?.usedPercent == 25)
        #expect(snapshot.currentContextUsed == 50)
        #expect(snapshot.contextWindow == 258_400)
    }

    private func event(timestamp: String, input: Int, output: Int, total: Int) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":0,"total_tokens":\(total)},"last_token_usage":{"total_tokens":50},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"resets_at":1785121200}}}}
        """
    }
}
