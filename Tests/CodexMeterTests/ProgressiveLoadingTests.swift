import Foundation
import Testing
@testable import CodexMeter

private actor ProgressSamples {
    var values: [(UsageSnapshot, Int, Int)] = []
    func append(_ snapshot: UsageSnapshot, _ completed: Int, _ total: Int) {
        values.append((snapshot, completed, total))
    }
}

struct ProgressiveLoadingTests {
    @Test func publishesPartialAggregatesWithoutChangingFinalResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-progress-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let line = #"{"timestamp":"2026-09-18T01:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"output_tokens":20,"total_tokens":100},"last_token_usage":{"total_tokens":100},"model_context_window":200000}}}"#
        for index in 0..<3 {
            try line.write(to: root.appendingPathComponent("session-\(index).jsonl"), atomically: true, encoding: .utf8)
        }
        let samples = ProgressSamples()
        let now = ISO8601DateFormatter().date(from: "2026-09-18T12:00:00Z")!
        let reader = CodexUsageReader()
        let result = try await reader.load(now: now, codexHome: root) { snapshot, completed, total in
            await samples.append(snapshot, completed, total)
        }
        let updates = await samples.values
        #expect(updates.first?.1 == 0)
        #expect(updates.contains { $0.1 == 1 && $0.0.allTime.total == 100 && $0.2 == 3 })
        #expect(result.allTime.total == 300)
        #expect(result.sessionCount == 3)
        let cached = try await reader.load(now: now, codexHome: root)
        #expect(cached == result)
        #expect(await reader.parsedFileCount == 0)
    }
}
