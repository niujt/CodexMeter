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

    @Test
    func separatesMainAndSparkSevenDayQuota() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/07/30")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let switchedSession = [
            session(model: "gpt-5-codex", timestamp: "2026-07-30T01:00:00.000Z", usedPercent: 13),
            session(model: "gpt-5.3-codex-spark", timestamp: "2026-07-30T02:00:00.000Z", usedPercent: 4)
        ].joined(separator: "\n")
        try switchedSession.write(
            to: sessions.appendingPathComponent("switched-models.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshot = try await CodexUsageReader(calendar: calendar).load(
            now: ISO8601DateFormatter().date(from: "2026-07-30T12:00:00Z")!,
            codexHome: root
        )

        #expect(snapshot.mainMenuRate?.usedPercent == 13)
        #expect(snapshot.sparkRate?.usedPercent == 4)
        #expect(snapshot.sevenDayRate?.usedPercent == 13)
        #expect(snapshot.rateTimeline.count == 1)
        #expect(snapshot.rateTimeline.first?.usedPercent == 13)
    }

    @Test
    func ignoresExpiredSevenDayQuotaAsCurrentRate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/08/04")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try session(model: "gpt-5-codex", timestamp: "2026-08-03T01:00:00.000Z", usedPercent: 100)
            .write(
                to: sessions.appendingPathComponent("expired.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshot = try await CodexUsageReader(calendar: calendar).load(
            now: ISO8601DateFormatter().date(from: "2026-08-04T12:00:00Z")!,
            codexHome: root
        )

        #expect(snapshot.mainMenuRate == nil)
        #expect(snapshot.sevenDayRate == nil)
        #expect(snapshot.rateTimeline.count == 1)
    }

    @Test
    func invalidatesCachedQuotaWhenWindowExpires() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/08/03")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try session(model: "gpt-5-codex", timestamp: "2026-08-03T01:00:00.000Z", usedPercent: 100)
            .write(
                to: sessions.appendingPathComponent("expiring.jsonl"),
                atomically: true,
                encoding: .utf8
            )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reader = CodexUsageReader(calendar: calendar)
        let beforeReset = ISO8601DateFormatter().date(from: "2026-08-03T02:00:00Z")!
        let afterReset = ISO8601DateFormatter().date(from: "2026-08-03T04:00:00Z")!
        let fresh = try await reader.load(now: beforeReset, codexHome: root)
        let expired = try await reader.load(now: afterReset, codexHome: root)

        #expect(fresh.mainMenuRate?.usedPercent == 100)
        #expect(expired.mainMenuRate == nil)
        #expect(expired.sevenDayRate == nil)
    }

    private func session(model: String, timestamp: String, usedPercent: Int) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"\(model)"}}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":100},"last_token_usage":{"total_tokens":50},"model_context_window":258400},"rate_limits":{"limit_id":"\(model)","secondary":{"used_percent":\(usedPercent),"window_minutes":10080,"resets_at":1785726000}}}}
        """
    }

    private func event(timestamp: String, input: Int, output: Int, total: Int) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":0,"output_tokens":\(output),"reasoning_output_tokens":0,"total_tokens":\(total)},"last_token_usage":{"total_tokens":50},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"resets_at":1785236400}}}}
        """
    }
}

struct QuotaRateCacheTests {
    @Test
    func restoresOnlyUnexpiredQuotaRates() {
        let suite = "QuotaRateCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        var source = UsageSnapshot.empty
        source.mainMenuRate = RateWindow(usedPercent: 13, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600))
        source.sparkRate = RateWindow(usedPercent: 4, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(7_200))
        QuotaRateCache.save(source, defaults: defaults, now: now)

        var restored = UsageSnapshot.empty
        QuotaRateCache.restore(into: &restored, defaults: defaults, now: now.addingTimeInterval(60))
        #expect(restored.mainMenuRate?.usedPercent == 13)
        #expect(restored.sparkRate?.usedPercent == 4)
        #expect(restored.mainRateIsCached)
        #expect(restored.sparkRateIsCached)

        var expired = UsageSnapshot.empty
        QuotaRateCache.restore(into: &expired, defaults: defaults, now: now.addingTimeInterval(7_201))
        #expect(expired.mainMenuRate == nil)
        #expect(expired.sparkRate == nil)
    }

    @Test
    func doesNotReplaceFreshQuotaWithCache() {
        let suite = "QuotaRateCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        var cached = UsageSnapshot.empty
        cached.mainMenuRate = RateWindow(usedPercent: 13, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600))
        QuotaRateCache.save(cached, defaults: defaults, now: now)

        var fresh = UsageSnapshot.empty
        fresh.mainMenuRate = RateWindow(usedPercent: 21, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600))
        QuotaRateCache.restoreMissing(into: &fresh, defaults: defaults, now: now)
        #expect(fresh.mainMenuRate?.usedPercent == 21)
        #expect(!fresh.mainRateIsCached)
    }
}
