import Foundation
import Testing
@testable import CodexMeter

struct UsageBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_HEALTH_BENCHMARK"] == "1"))
    func syntheticLongSessionAndManyFiles() async throws {
        let base = TestFixtureDirectory.root.appendingPathComponent("codexmeter-benchmark-" + UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let fileCount = 2_000
        let longEvents = 20_000
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-10))
        func token(_ output: Int) -> String {
            "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"output_tokens\":\(output),\"total_tokens\":\(output + 100)}}}}\n"
        }
        for index in 0..<fileCount {
            let directory = root.appendingPathComponent("day-\(index / 100)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(token(10).utf8).write(to: directory.appendingPathComponent("\(index).jsonl"))
        }
        let longFile = root.appendingPathComponent("long.jsonl")
        try Data((0..<longEvents).map { token($0 + 1) }.joined().utf8).write(to: longFile)
        let reader = CodexUsageReader(calendar: calendar, cacheDirectory: base.appendingPathComponent("cache"))
        var timings: [String: Double] = [:]
        var bytes: [String: Int] = [:]
        var start = ContinuousClock.now
        let cold = try await reader.load(now: now, codexHome: root)
        timings["cold_ms"] = milliseconds(start.duration(to: .now))
        bytes["cold"] = await reader.readByteCount
        start = .now
        let warm = try await reader.load(now: now, codexHome: root)
        timings["warm_ms"] = milliseconds(start.duration(to: .now))
        bytes["warm"] = await reader.readByteCount
        #expect(warm == cold)
        #expect(await reader.listedDirectoryCount == 0)
        #expect(await reader.aggregatedBucketCount == 0)
        let handle = try FileHandle(forWritingTo: longFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(token(longEvents + 100).utf8))
        try handle.close()
        start = .now
        let incremental = try await reader.load(now: now, codexHome: root)
        timings["append_ms"] = milliseconds(start.duration(to: .now))
        bytes["append"] = await reader.readByteCount
        #expect(await reader.incrementalFileCount == 1)
        #expect(await reader.parsedFileCount == 1)
        #expect(await reader.persistedSummaryCount == 1)
        #expect(await reader.readByteCount < 20_000)
        start = .now
        let forced = try await reader.load(now: now, codexHome: root, force: true)
        timings["forced_full_ms"] = milliseconds(start.duration(to: .now))
        bytes["forced_full"] = await reader.readByteCount
        #expect(incremental == forced)
        #expect(forced.fileCount == fileCount + 1)
        let result: [String: Any] = ["synthetic": true, "files": fileCount + 1,
            "long_session_events": longEvents, "timings": timings, "read_bytes": bytes,
            "append_matches_full_parse": incremental == forced]
        let report = base.appendingPathComponent("benchmark.json")
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        print("Synthetic usage benchmark: \(report.path)")
        print("Milliseconds: \(timings); bytes read: \(bytes)")
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
