import Foundation
import Testing
@testable import CodexMeter

struct ReplySpeedTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func weightsCompletedTurnsAndIncludesTrailingUsageOnlyOnce() async throws {
        let root = try fixture([
            token(-800, output: 100),
            message(-600, role: "user"),
            token(-590, output: 200),
            message(-585, role: "assistant", phase: "commentary"),
            message(-580, role: "assistant", phase: "final_answer"),
            token(-579, output: 300),
            event(-578, type: "task_complete"),
            event(-577, type: "task_complete"),
            message(-100, role: "user"),
            token(-40, output: 600),
            event(-40, type: "task_complete"),
            token(-30, output: 650), // Usage outside a turn must not enter the numerator.
            message(-20, role: "user"),
            token(-10, output: 1_000) // Incomplete turn must not enter either sum.
        ])
        let snapshot = try await CodexUsageReader().load(now: now, codexHome: root)
        let speed = try #require(RecentReplySpeed.summarize(snapshot.replySpeedSamples, now: now))
        #expect(speed.sampleCount == 2)
        #expect(speed.outputTokens == 500)
        #expect(speed.turnSeconds == 80)
        #expect(speed.tokensPerSecond == 6.25) // Not the arithmetic mean of 10 and 5.
        #expect(snapshot.allTime.output == 1_000)
    }

    @Test func supportsTaskStartWithoutUserAndDoesNotRestartOnUserMessage() async throws {
        let root = try fixture([
            token(-100, output: 100),
            event(-60, type: "task_started"),
            message(-55, role: "user"),
            token(-50, output: 200),
            event(-50, type: "task_complete"),
            event(-40, type: "task_started"),
            token(-30, output: 400),
            event(-30, type: "task_complete")
        ])
        let snapshot = try await CodexUsageReader().load(now: now, codexHome: root)
        let speed = try #require(RecentReplySpeed.summarize(snapshot.replySpeedSamples, now: now))
        #expect(speed.sampleCount == 2)
        #expect(speed.turnSeconds == 20)
        #expect(speed.outputTokens == 300)
    }

    @Test func usesFinalAnswerFallbackAndCountsFollowingTokenAtEOF() async throws {
        let root = try fixture([
            token(-100, output: 100),
            message(-60, role: "user"),
            message(-50, role: "assistant", phase: "final_answer"),
            token(-49, output: 400)
        ])
        let snapshot = try await CodexUsageReader().load(now: now, codexHome: root)
        let speed = try #require(RecentReplySpeed.summarize(snapshot.replySpeedSamples, now: now))
        #expect(speed.tokensPerSecond == 30)
        #expect(speed.sampleCount == 1)
    }

    @Test func excludesUnknownInitialBaselineButAllowsProvenFirstUsage() async throws {
        let uncertain = try fixture([
            message(-60, role: "user"),
            token(-50, output: 9_000, lastOutput: 100),
            event(-50, type: "task_complete")
        ])
        let excluded = try await CodexUsageReader().load(now: now, codexHome: uncertain)
        #expect(excluded.replySpeedSamples.isEmpty)
        let first = try fixture([
            message(-60, role: "user"),
            token(-50, output: 100, lastOutput: 100),
            event(-50, type: "task_complete")
        ])
        let included = try await CodexUsageReader().load(now: now, codexHome: first)
        #expect(RecentReplySpeed.summarize(included.replySpeedSamples, now: now)?.tokensPerSecond == 10)
    }

    @Test func excludesMissingOutputAndInconsistentCounters() async throws {
        let missing = try fixture([
            token(-100, output: 100),
            message(-60, role: "user"),
            token(-55, output: 200, includeOutput: false),
            token(-50, output: 300),
            event(-50, type: "task_complete")
        ])
        let snapshot = try await CodexUsageReader().load(now: now, codexHome: missing)
        #expect(snapshot.replySpeedSamples.isEmpty)
        let decreasing = try fixture([
            token(-100, output: 300, input: 1_000),
            message(-60, role: "user"),
            token(-50, output: 100, input: 2_000),
            event(-50, type: "task_complete")
        ])
        let invalid = try await CodexUsageReader().load(now: now, codexHome: decreasing)
        #expect(invalid.replySpeedSamples.isEmpty)
    }

    @Test func handlesCounterResetAndDoesNotAddReasoningAgain() async throws {
        let root = try fixture([
            token(-100, output: 300, input: 1_000),
            message(-60, role: "user"),
            token(-50, output: 100, input: 100),
            event(-50, type: "task_complete")
        ])
        let snapshot = try await CodexUsageReader().load(now: now, codexHome: root)
        #expect(RecentReplySpeed.summarize(snapshot.replySpeedSamples, now: now)?.tokensPerSecond == 10)
    }

    @Test func excludesAbortedSupersededAndInvalidDurationTurns() async throws {
        let root = try fixture([
            token(-5_000, output: 100),
            message(-4_000, role: "user"),
            token(-300, output: 200),
            event(-300, type: "task_complete"), // Over an hour.
            message(-200, role: "user"),
            token(-199, output: 300),
            event(-198, type: "turn_aborted"),
            message(-190, role: "user"),
            token(-180, output: 400),
            message(-180, role: "assistant", phase: "final_answer"),
            event(-179, type: "task_aborted"),
            message(-170, role: "user"),
            token(-160, output: 500),
            message(-150, role: "user"), // Supersedes an incomplete turn.
            token(-150, output: 600),
            event(-150, type: "task_complete") // Zero duration.
        ])
        let snapshot = try await CodexUsageReader().load(now: now, codexHome: root)
        #expect(snapshot.replySpeedSamples.isEmpty)
    }

    @Test func reaggregatesUnchangedCacheAsWindowExpiresAndFileGrows() async throws {
        let root = try fixture([
            token(-100, output: 100),
            message(-60, role: "user"),
            token(-50, output: 400),
            event(-50, type: "task_complete")
        ])
        let reader = CodexUsageReader()
        let initial = try await reader.load(now: now, codexHome: root)
        let cached = try await reader.load(now: now, codexHome: root)
        #expect(initial == cached)
        #expect(await reader.parsedFileCount == 0)
        let expired = try await reader.load(now: now.addingTimeInterval(851), codexHome: root)
        #expect(expired.replySpeedSamples.isEmpty)
        #expect(await reader.parsedFileCount == 0)
        let file = root.appendingPathComponent("session.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + [message(-20, role: "user"), token(-10, output: 500),
                                                 event(-10, type: "task_complete")].joined(separator: "\n")).utf8))
        let changed = try await reader.load(now: now, codexHome: root)
        #expect(await reader.parsedFileCount == 1)
        #expect(RecentReplySpeed.summarize(changed.replySpeedSamples, now: now)?.sampleCount == 2)
    }

    @Test func usesExactCompletionWindowAndExpiresWithoutRefresh() {
        let samples = [
            ReplySpeedSample(completedAt: now.addingTimeInterval(-901), outputTokens: 9_000, turnSeconds: 1),
            ReplySpeedSample(completedAt: now.addingTimeInterval(-900), outputTokens: 9_000, turnSeconds: 1),
            ReplySpeedSample(completedAt: now.addingTimeInterval(-899), outputTokens: 20, turnSeconds: 2),
            ReplySpeedSample(completedAt: now.addingTimeInterval(1), outputTokens: 9_000, turnSeconds: 1),
            ReplySpeedSample(completedAt: now, outputTokens: 0, turnSeconds: 10),
            ReplySpeedSample(completedAt: now, outputTokens: 100, turnSeconds: .nan)
        ]
        let speed = RecentReplySpeed.summarize(samples, now: now)
        #expect(speed?.sampleCount == 1)
        #expect(speed?.tokensPerSecond == 10)
        let validOnly = Array(samples[2...2])
        #expect(RecentReplySpeed.summarize(validOnly, now: now.addingTimeInterval(2)) == nil)
        #expect(RecentReplySpeed.summarize([], now: now) == nil)
        #expect(UsageFormatters.replySpeed(6.25).contains("tokens/s"))
    }

    private func fixture(_ lines: [String]) throws -> URL {
        // Retain our synthetic temp files; cleanup requires project confirmation.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexmeter-reply-speed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        return root
    }

    private func line(_ offset: Double, type: String, payload: [String: Any]) -> String {
        let json: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)),
                                  "type": type, "payload": payload]
        return String(decoding: try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]), as: UTF8.self)
    }

    private func message(_ offset: Double, role: String, phase: String = "") -> String {
        line(offset, type: "response_item", payload: ["type": "message", "role": role, "phase": phase])
    }

    private func event(_ offset: Double, type: String) -> String {
        line(offset, type: "event_msg", payload: ["type": type])
    }

    private func token(_ offset: Double, output: Int, input: Int = 10_000,
                       lastOutput: Int? = nil, includeOutput: Bool = true) -> String {
        var usage = ["input_tokens": input, "total_tokens": input + output, "reasoning_output_tokens": 40]
        if includeOutput { usage["output_tokens"] = output }
        var info: [String: Any] = ["total_token_usage": usage]
        if let lastOutput { info["last_token_usage"] = ["output_tokens": lastOutput, "total_tokens": input + lastOutput] }
        return line(offset, type: "event_msg", payload: ["type": "token_count", "info": info])
    }
}
