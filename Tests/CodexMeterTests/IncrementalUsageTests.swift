import Foundation
import Testing
@testable import CodexMeter

struct IncrementalUsageTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    @Test func appendRetainsEOFCompletedTurnAndTrailingUsage() async throws {
        let fixture = try fixture()
        try write([token(-100, output: 100), message(-60, role: "user"),
                   token(-50, output: 300), message(-50, role: "assistant", phase: "final_answer")],
                  to: fixture.file)
        let reader = reader(fixture)
        let first = try await reader.load(now: now, codexHome: fixture.root)
        #expect(first.replySpeedSamples.first?.outputTokens == 200)
        try append("\n" + token(-49, output: 500) + "\n" + event(-49, "task_complete") + "\n", to: fixture.file)
        let grown = try await reader.load(now: now, codexHome: fixture.root)
        #expect(await reader.incrementalFileCount == 1)
        #expect(grown.replySpeedSamples.count == 1)
        #expect(grown.replySpeedSamples.first?.outputTokens == 400)
        #expect(grown == (try await reference(fixture: fixture, at: now)))
    }

    @Test func incompleteFragmentIsReplayedOnceAfterRestart() async throws {
        let fixture = try fixture()
        let next = token(-10, output: 200)
        let cut = next.index(next.startIndex, offsetBy: next.count / 2)
        try write([token(-100, output: 100)], to: fixture.file, newline: true)
        try append(String(next[..<cut]), to: fixture.file)
        let first = try await reader(fixture).load(now: now, codexHome: fixture.root)
        #expect(first.allTime.output == 100)
        try append(String(next[cut...]) + "\n", to: fixture.file)
        let restarted = reader(fixture)
        let grown = try await restarted.load(now: now, codexHome: fixture.root)
        #expect(await restarted.incrementalFileCount == 1)
        #expect(grown.allTime.output == 200)
        #expect(grown.readWarning == nil)
        #expect(grown == (try await reference(fixture: fixture, at: now)))
    }

    @Test func restartResumesAnUnfinishedTurnWithoutPersistingText() async throws {
        let fixture = try fixture()
        try write([token(-100, output: 100), message(-60, role: "user"), token(-50, output: 200)],
                  to: fixture.file, newline: true)
        let first = try await reader(fixture).load(now: now, codexHome: fixture.root)
        #expect(first.replySpeedSamples.isEmpty)
        try append(token(-40, output: 500) + "\n" + event(-40, "task_complete") + "\n", to: fixture.file)
        let restarted = reader(fixture)
        let complete = try await restarted.load(now: now, codexHome: fixture.root)
        #expect(await restarted.incrementalFileCount == 1)
        #expect(complete.replySpeedSamples.first?.outputTokens == 400)
        #expect(complete == (try await reference(fixture: fixture, at: now)))
        let enumerator = try #require(FileManager.default.enumerator(at: fixture.cache, includingPropertiesForKeys: nil))
        for url in enumerator.allObjects.compactMap({ $0 as? URL }) where url.pathExtension == "plist" {
            let bytes = try Data(contentsOf: url)
            #expect(bytes.range(of: Data("PRIVATE_SYNTHETIC_MESSAGE".utf8)) == nil)
        }
    }

    @Test func truncationReplacementAndPrefixRewriteFallBackToFullRead() async throws {
        let fixture = try fixture()
        try write([token(-100, output: 100), token(-50, output: 200)], to: fixture.file, newline: true)
        let reader = reader(fixture)
        _ = try await reader.load(now: now, codexHome: fixture.root)
        let handle = try FileHandle(forWritingTo: fixture.file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((token(-40, output: 50) + "\n").utf8))
        try handle.close()
        let truncated = try await reader.load(now: now, codexHome: fixture.root)
        #expect(await reader.incrementalFileCount == 0)
        #expect(truncated.allTime.output == 50)
        try write([token(-30, output: 700), token(-20, output: 800)], to: fixture.file, newline: true)
        let replacement = try await reader.load(now: now, codexHome: fixture.root)
        #expect(await reader.incrementalFileCount == 0)
        #expect(replacement.allTime.output == 800)
        let rewritten = try FileHandle(forWritingTo: fixture.file)
        try rewritten.write(contentsOf: Data((token(-30, output: 900) + "\n").utf8))
        try rewritten.seekToEnd()
        try rewritten.write(contentsOf: Data((token(-10, output: 1_000) + "\n").utf8))
        try rewritten.close()
        let changed = try await reader.load(now: now, codexHome: fixture.root)
        #expect(await reader.incrementalFileCount == 0)
        #expect(changed == (try await reference(fixture: fixture, at: now)))
    }

    @Test func unchangedFilesReuseDirectoryListingAndAggregateButNewFilesAreDiscovered() async throws {
        let fixture = try fixture()
        try write([token(-100, output: 100)], to: fixture.file, newline: true)
        let reader = reader(fixture)
        let first = try await reader.load(now: now, codexHome: fixture.root)
        #expect(await reader.listedDirectoryCount == 1)
        let warm = try await reader.load(now: now.addingTimeInterval(1), codexHome: fixture.root)
        #expect(first == warm)
        #expect(await reader.listedDirectoryCount == 0)
        #expect(await reader.aggregatedBucketCount == 0)
        #expect(await reader.reusedAggregateCount == 1)
        #expect(await reader.readByteCount == 0)
        try write([token(-90, output: 200)], to: fixture.root.appendingPathComponent("new.jsonl"), newline: true)
        let added = try await reader.load(now: now, codexHome: fixture.root)
        #expect(added.fileCount == 2)
        #expect(await reader.listedDirectoryCount == 1)
        #expect(added == (try await reference(fixture: fixture, at: now)))
        try FileManager.default.moveItem(at: fixture.file, to: fixture.file.appendingPathExtension("saved"))
        let removed = try await reader.load(now: now, codexHome: fixture.root)
        #expect(removed.fileCount == 1)
        #expect(removed == (try await reference(fixture: fixture, at: now)))
    }

    @Test func quotaResetAndFutureCompletionInvalidateAggregateWithoutReparsing() async throws {
        let fixture = try fixture()
        var usage = try JSONSerialization.jsonObject(with: Data(token(-10, output: 100).utf8)) as! [String: Any]
        var payload = usage["payload"] as! [String: Any]
        payload["rate_limits"] = ["limit_id": "codex", "secondary": ["used_percent": 20,
            "window_minutes": 10_080, "resets_at": now.addingTimeInterval(5).timeIntervalSince1970]]
        usage["payload"] = payload
        let quota = String(decoding: try JSONSerialization.data(withJSONObject: usage), as: UTF8.self)
        try write([quota, message(-1, role: "user"), token(1, output: 200), event(1, "task_complete")],
                  to: fixture.file, newline: true)
        let reader = reader(fixture)
        let first = try await reader.load(now: now, codexHome: fixture.root)
        #expect(first.replySpeedSamples.isEmpty)
        let completed = try await reader.load(now: now.addingTimeInterval(2), codexHome: fixture.root)
        #expect(completed.replySpeedSamples.count == 1)
        let reset = try await reader.load(now: now.addingTimeInterval(6), codexHome: fixture.root)
        #expect(reset.mainMenuRate == nil)
        #expect(await reader.parsedFileCount == 0)
        let expected = try await reference(fixture: fixture, at: now.addingTimeInterval(6))
        #expect(reset == expected)
    }

    @Test func appendedReadCostIsBoundedForLongSessions() async throws {
        let fixture = try fixture()
        let lines = (0..<2_000).map { token(-100, output: $0 + 1) }
        try write(lines, to: fixture.file, newline: true)
        let reader = reader(fixture)
        _ = try await reader.load(now: now, codexHome: fixture.root)
        let coldBytes = await reader.readByteCount
        try append(token(-10, output: 2_100) + "\n", to: fixture.file)
        let changed = try await reader.load(now: now, codexHome: fixture.root)
        #expect(await reader.incrementalFileCount == 1)
        #expect(await reader.readByteCount < 20_000)
        #expect(await reader.readByteCount < coldBytes / 10)
        #expect(changed == (try await reference(fixture: fixture, at: now)))
    }

    @Test func appendedAbortRetractsEOFOnlySpeedSample() async throws {
        let fixture = try fixture()
        try write([token(-100, output: 100), message(-60, role: "user"), token(-50, output: 300),
                   message(-50, role: "assistant", phase: "final_answer")], to: fixture.file, newline: true)
        let reader = reader(fixture)
        let first = try await reader.load(now: now, codexHome: fixture.root)
        #expect(first.replySpeedSamples.count == 1)
        try append(event(-49, "task_aborted") + "\n", to: fixture.file)
        let aborted = try await reader.load(now: now, codexHome: fixture.root)
        #expect(aborted.replySpeedSamples.isEmpty)
        #expect(aborted == (try await reference(fixture: fixture, at: now)))
    }

    @Test func oversizedPartialLineKeepsDropStateAcrossAppend() async throws {
        let fixture = try fixture()
        try write([token(-100, output: 100)], to: fixture.file, newline: true)
        try append(String(repeating: "x", count: 17 * 1024 * 1024), to: fixture.file)
        let reader = reader(fixture)
        let first = try await reader.load(now: now, codexHome: fixture.root)
        #expect(first.readWarning != nil)
        try append("\n" + token(-10, output: 200) + "\n", to: fixture.file)
        let recovered = try await reader.load(now: now, codexHome: fixture.root)
        #expect(await reader.incrementalFileCount == 1)
        #expect(await reader.readByteCount < 2 * 1024 * 1024)
        #expect(recovered.allTime.output == 200)
        #expect(recovered == (try await reference(fixture: fixture, at: now)))
    }

    private struct Fixture { let root: URL; let file: URL; let cache: URL }
    private func fixture() throws -> Fixture {
        let base = TestFixtureDirectory.root.appendingPathComponent("codexmeter-incremental-" + UUID().uuidString)
        let root = base.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root, file: root.appendingPathComponent("session.jsonl"), cache: base.appendingPathComponent("cache"))
    }
    private func reader(_ fixture: Fixture) -> CodexUsageReader {
        CodexUsageReader(calendar: calendar, cacheDirectory: fixture.cache)
    }
    private func reference(fixture: Fixture, at date: Date) async throws -> UsageSnapshot {
        try await CodexUsageReader(calendar: calendar).load(now: date, codexHome: fixture.root)
    }
    private func write(_ lines: [String], to file: URL, newline: Bool = false) throws {
        try Data((lines.joined(separator: "\n") + (newline ? "\n" : "")).utf8).write(to: file, options: .atomic)
    }
    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
    private func line(_ offset: Double, type: String, payload: [String: Any]) -> String {
        let json: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)),
                                  "type": type, "payload": payload]
        return String(decoding: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self)
    }
    private func token(_ offset: Double, output: Int) -> String {
        line(offset, type: "event_msg", payload: ["type": "token_count", "info": ["total_token_usage":
            ["input_tokens": 100, "cached_input_tokens": 20, "output_tokens": output, "total_tokens": output + 100]]])
    }
    private func message(_ offset: Double, role: String, phase: String = "") -> String {
        line(offset, type: "response_item", payload: ["type": "message", "role": role,
            "phase": phase, "content": "PRIVATE_SYNTHETIC_MESSAGE"])
    }
    private func event(_ offset: Double, _ type: String) -> String {
        line(offset, type: "event_msg", payload: ["type": type])
    }
}
