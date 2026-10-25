import Foundation
import Testing
@testable import CodexMeter

struct CodexUsageReaderTests {
    @Test
    func aggregatesCumulativeSessionTotalsAsDeltas() async throws {
        let root = TestFixtureDirectory.root
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/07/27")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { TestFixtureDirectory.cleanup(root) }

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
        #expect(snapshot.lastUpdated == ISO8601DateFormatter().date(from: "2026-07-27T02:00:00Z"))

        let cached = try await reader.load(now: now, codexHome: root)
        #expect(cached.currentContextUsed == 50)
        #expect(cached.contextWindow == 258_400)
        #expect(cached.lastUpdated == snapshot.lastUpdated)
        #expect(await reader.parsedFileCount == 0)
    }

    @Test
    func aggregatesCacheHitRateFromInputTokenFields() async throws {
        let root = TestFixtureDirectory.root
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/07/27")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { TestFixtureDirectory.cleanup(root) }

        let samples = [
            modelTokenEvent(model: "gpt-cache", timestamp: "2026-07-27T01:00:00.000Z", input: 100, cachedInput: 25, output: 20, total: 120),
            modelTokenEvent(model: "gpt-cache", timestamp: "2026-07-27T02:00:00.000Z", input: 200, cachedInput: 150, output: 30, total: 230),
            modelTokenEvent(model: "missing-cache", timestamp: "2026-07-27T03:00:00.000Z", input: 100, cachedInput: 0, output: 20, total: 120, includeCachedInput: false),
            modelTokenEvent(model: "zero-input", timestamp: "2026-07-27T04:00:00.000Z", input: 0, cachedInput: 0, output: 20, total: 20)
        ]
        for (index, sample) in samples.enumerated() {
            try sample.write(
                to: sessions.appendingPathComponent("cache-\(index).jsonl"),
                atomically: true,
                encoding: .utf8
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshot = try await CodexUsageReader(calendar: calendar).load(
            now: ISO8601DateFormatter().date(from: "2026-07-27T12:00:00Z")!,
            codexHome: root
        )

        let models = Dictionary(uniqueKeysWithValues: snapshot.topModels.map { ($0.name, $0) })
        #expect(abs((models["gpt-cache"]?.cacheHitRate ?? -1) - (175.0 / 300.0)) < 0.0001)
        #expect(models["missing-cache"]?.cacheHitRate == nil)
        #expect(models["zero-input"]?.cacheHitRate == nil)
    }

    @Test
    func separatesMainAndSparkSevenDayQuota() async throws {
        let root = TestFixtureDirectory.root
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/07/30")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { TestFixtureDirectory.cleanup(root) }

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
        let root = TestFixtureDirectory.root
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/08/04")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { TestFixtureDirectory.cleanup(root) }

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
        let root = TestFixtureDirectory.root
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/08/03")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { TestFixtureDirectory.cleanup(root) }

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

    @Test
    func prefersCanonicalQuotaWhenAnotherBucketReportsLater() async throws {
        let root = TestFixtureDirectory.root
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/08/08")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { TestFixtureDirectory.cleanup(root) }

        let canonicalReset = 1_786_768_697.0
        let alternateReset = 1_786_794_883.0
        try quotaSession(
            model: "gpt-5-codex",
            limitID: "codex",
            timestamp: "2026-08-08T11:54:28.335Z",
            usedPercent: 4,
            reset: canonicalReset
        ).write(
            to: sessions.appendingPathComponent("canonical.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try quotaSession(
            model: "gpt-5.6-luna",
            limitID: "codex_bengalfox",
            timestamp: "2026-08-08T11:54:58.332Z",
            usedPercent: 0,
            reset: alternateReset
        ).write(
            to: sessions.appendingPathComponent("alternate.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-08-08T12:00:00Z")!
        let snapshot = try await CodexUsageReader(calendar: calendar).load(
            now: now,
            codexHome: root
        )

        #expect(snapshot.mainMenuRate?.usedPercent == 4)
        #expect(snapshot.mainMenuRate?.resetsAt == Date(timeIntervalSince1970: canonicalReset))
        #expect(snapshot.selectedRateLimitID == "codex")
    }

    @Test
    func readsCanonicalSevenDayQuotaFromPrimaryWindow() async throws {
        let root = TestFixtureDirectory.root
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/08/11")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { TestFixtureDirectory.cleanup(root) }

        let reset = 1_787_014_816.0
        try primaryQuotaSession(
            timestamp: "2026-08-11T06:24:04.346Z",
            usedPercent: 3,
            reset: reset
        ).write(
            to: sessions.appendingPathComponent("primary-canonical.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let snapshot = try await CodexUsageReader(calendar: calendar).load(
            now: ISO8601DateFormatter().date(from: "2026-08-11T06:30:00Z")!,
            codexHome: root
        )

        #expect(snapshot.mainMenuRate?.usedPercent == 3)
        #expect(snapshot.sevenDayRate?.usedPercent == 3)
        #expect(snapshot.mainMenuRate?.resetsAt == Date(timeIntervalSince1970: reset))
        #expect(snapshot.selectedRateLimitID == "codex")
    }

    @Test
    func doesNotUseAlternateBucketWhileCanonicalBucketWaitsAfterReset() async throws {
        let root = TestFixtureDirectory.root
            .appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions/2026/08/08")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { TestFixtureDirectory.cleanup(root) }

        try quotaSession(
            model: "gpt-5-codex",
            limitID: "codex",
            timestamp: "2026-08-07T11:54:28.335Z",
            usedPercent: 72,
            reset: 1_786_161_996
        ).write(
            to: sessions.appendingPathComponent("expired-canonical.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try quotaSession(
            model: "gpt-5.6-luna",
            limitID: "codex_bengalfox",
            timestamp: "2026-08-08T11:54:58.332Z",
            usedPercent: 0,
            reset: 1_786_794_883
        ).write(
            to: sessions.appendingPathComponent("fresh-alternate.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-08-08T12:00:00Z")!
        let snapshot = try await CodexUsageReader(calendar: calendar).load(
            now: now,
            codexHome: root
        )

        #expect(snapshot.sevenDayRate == nil)
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

    private func modelTokenEvent(
        model: String,
        timestamp: String,
        input: Int,
        cachedInput: Int,
        output: Int,
        total: Int,
        includeCachedInput: Bool = true
    ) -> String {
        let cachedField = includeCachedInput ? ",\"cached_input_tokens\":\(cachedInput)" : ""
        return """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"\(model)"}}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input)\(cachedField),"output_tokens":\(output),"reasoning_output_tokens":0,"total_tokens":\(total)},"last_token_usage":{"total_tokens":50},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":25,"window_minutes":300,"resets_at":1785236400}}}}
        """
    }

    private func quotaSession(
        model: String,
        limitID: String,
        timestamp: String,
        usedPercent: Int,
        reset: Double
    ) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"\(model)"}}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":100},"last_token_usage":{"total_tokens":50},"model_context_window":258400},"rate_limits":{"limit_id":"\(limitID)","secondary":{"used_percent":\(usedPercent),"window_minutes":10080,"resets_at":\(reset)}}}}
        """
    }

    private func primaryQuotaSession(timestamp: String, usedPercent: Int, reset: Double) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":100},"last_token_usage":{"total_tokens":50},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":\(usedPercent),"window_minutes":10080,"resets_at":\(reset)},"secondary":null}}}
        """
    }
}

struct QuotaRateCacheTests {
    @Test
    func restoresOnlyUnexpiredQuotaRates() {
        let suite = "CodexMeterTests.QuotaRateCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { TestFixtureDirectory.cleanupDefaults(defaults, suite: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        var source = UsageSnapshot.empty
        source.mainMenuRate = RateWindow(usedPercent: 13, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600))
        source.sparkRate = RateWindow(usedPercent: 4, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(7_200))
        source.mainRateSampledAt = now; source.sparkRateSampledAt = now
        QuotaRateCache.save(source, scope: QuotaScope(id: "synthetic", since: .distantPast), defaults: defaults, now: now)

        var restored = UsageSnapshot.empty
        QuotaRateCache.restore(into: &restored, scope: QuotaScope(id: "synthetic", since: .distantPast), defaults: defaults, now: now.addingTimeInterval(60))
        #expect(restored.mainMenuRate?.usedPercent == 13)
        #expect(restored.sparkRate?.usedPercent == 4)
        #expect(restored.mainRateIsCached)
        #expect(restored.sparkRateIsCached)

        var expired = UsageSnapshot.empty
        QuotaRateCache.restore(into: &expired, scope: QuotaScope(id: "synthetic", since: .distantPast), defaults: defaults, now: now.addingTimeInterval(7_201))
        #expect(expired.mainMenuRate == nil)
        #expect(expired.sparkRate == nil)
    }

    @Test
    func doesNotReplaceFreshQuotaWithCache() {
        let suite = "CodexMeterTests.QuotaRateCache.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { TestFixtureDirectory.cleanupDefaults(defaults, suite: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        var cached = UsageSnapshot.empty
        cached.mainMenuRate = RateWindow(usedPercent: 13, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600))
        cached.mainRateSampledAt = now
        QuotaRateCache.save(cached, scope: QuotaScope(id: "synthetic", since: .distantPast), defaults: defaults, now: now)

        var fresh = UsageSnapshot.empty
        fresh.mainMenuRate = RateWindow(usedPercent: 21, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600))
        QuotaRateCache.restoreMissing(into: &fresh, scope: QuotaScope(id: "synthetic", since: .distantPast), defaults: defaults, now: now)
        #expect(fresh.mainMenuRate?.usedPercent == 21)
        #expect(!fresh.mainRateIsCached)
    }
}

struct UsageOptimizationTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func fixture() throws -> URL {
        let root = TestFixtureDirectory.root.appendingPathComponent("CodexMeterOptimizationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep synthetic fixtures for inspection; no cleanup of files or user settings.
        return root
    }

    private func token(_ timestamp: String, total: Int) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(total),"cached_input_tokens":0,"total_tokens":\(total)}}}}
        """
    }

    private func model(_ name: String) -> String {
        """
        {"type":"turn_context","payload":{"model":"\(name)"}}
        """
    }

    private func message(_ timestamp: String, role: String, phase: String) -> String {
        """
        {"timestamp":"\(timestamp)","type":"response_item","payload":{"type":"message","role":"\(role)","phase":"\(phase)"}}
        """
    }

    @Test func allocatesCrossMonthDeltasAndModelSwitches() async throws {
        let root = try fixture()
        let lines = [
            "{\"type\":\"session_meta\",\"payload\":{\"cwd\": \"/work/中文项目\"}}",
            model("model-a"), token("2026-07-31T23:00:00Z", total: 100_000),
            model("model-b"), token("2026-08-01T01:00:00Z", total: 110_000)
        ]
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let snapshot = try await CodexUsageReader(calendar: calendar).load(now: date("2026-08-01T12:00:00Z"), codexHome: root)
        #expect(snapshot.today.total == 10_000)
        #expect(snapshot.thisMonth.total == 10_000)
        #expect(snapshot.lastSevenDays.total == 110_000)
        #expect(snapshot.allTime.total == 110_000)
        #expect(snapshot.dailyUsage.map(\.tokens) == [100_000, 10_000])
        #expect(snapshot.topModels.first(where: { $0.name == "model-a" })?.tokens == 100_000)
        #expect(snapshot.topModels.first(where: { $0.name == "model-b" })?.tokens == 10_000)
        #expect(snapshot.todayProjects.first?.path == "/work/中文项目")
        #expect(snapshot.allProjects.first?.sessions == 1)
    }

    @Test func handlesCounterResetAndDuplicateSamples() async throws {
        let root = try fixture()
        let lines = [100, 150, 150, 20, 40].enumerated().map {
            token("2026-08-01T0\($0.offset):00:00Z", total: $0.element)
        }
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let result = try await CodexUsageReader(calendar: calendar).load(now: date("2026-08-01T12:00:00Z"), codexHome: root)
        #expect(result.today.total == 190)
        #expect(result.allTime.total == 190)
    }

    @Test func onlyReparsesChangedFilesAndReaggregatesAtMidnight() async throws {
        let root = try fixture()
        let first = root.appendingPathComponent("first.jsonl")
        let second = root.appendingPathComponent("second.jsonl")
        try token("2026-08-01T01:00:00Z", total: 100).write(to: first, atomically: true, encoding: .utf8)
        try token("2026-08-01T02:00:00Z", total: 200).write(to: second, atomically: true, encoding: .utf8)
        let reader = CodexUsageReader(calendar: calendar)
        let now = date("2026-08-01T12:00:00Z")
        _ = try await reader.load(now: now, codexHome: root)
        #expect(await reader.parsedFileCount == 2)
        _ = try await reader.load(now: now, codexHome: root)
        #expect(await reader.parsedFileCount == 0)
        try token("2026-08-01T01:00:00Z", total: 1_000).write(to: first, atomically: true, encoding: .utf8)
        let changed = try await reader.load(now: now, codexHome: root)
        #expect(await reader.parsedFileCount == 1)
        #expect(changed.today.total == 1_200)
        let nextDay = try await reader.load(now: date("2026-08-02T12:00:00Z"), codexHome: root)
        #expect(await reader.parsedFileCount == 0)
        #expect(nextDay.today.total == 0)
        #expect(nextDay.lastSevenDays.total == 1_200)
        _ = try await reader.load(now: now, codexHome: root, force: true)
        #expect(await reader.parsedFileCount == 2)
    }

    @Test func preservesCachedFileOnPartialFailureAndThrowsOnTotalFailure() async throws {
        let root = try fixture()
        let first = root.appendingPathComponent("first.jsonl")
        let second = root.appendingPathComponent("second.jsonl")
        try token("2026-08-01T01:00:00Z", total: 100).write(to: first, atomically: true, encoding: .utf8)
        try token("2026-08-01T02:00:00Z", total: 200).write(to: second, atomically: true, encoding: .utf8)
        let reader = CodexUsageReader(calendar: calendar)
        let now = date("2026-08-01T12:00:00Z")
        _ = try await reader.load(now: now, codexHome: root)
        try "broken JSON\n".write(to: first, atomically: true, encoding: .utf8)
        let partial = try await reader.load(now: now, codexHome: root)
        #expect(partial.today.total == 300)
        #expect(partial.readWarning != nil)
        try "broken JSON\n".write(to: second, atomically: true, encoding: .utf8)
        await #expect(throws: UsageReadError.self) { try await reader.load(now: now, codexHome: root) }
    }

    @Test func distinguishesEmptyDirectoryFromMissingDirectory() async throws {
        let root = try fixture()
        let reader = CodexUsageReader(calendar: calendar)
        let empty = try await reader.load(codexHome: root)
        #expect(empty.fileCount == 0)
        #expect(empty.readWarning == nil)
        await #expect(throws: (any Error).self) { try await reader.load(codexHome: root.appendingPathComponent("missing")) }
    }

    @Test func waitsForFinalAnswerAndDoesNotDoubleCountCompletion() async throws {
        let root = try fixture()
        let lines = [
            model("model-a"),
            message("2026-08-01T01:00:00Z", role: "user", phase: ""),
            message("2026-08-01T01:00:02Z", role: "assistant", phase: "commentary"),
            token("2026-08-01T01:00:05Z", total: 100),
            message("2026-08-01T01:00:10Z", role: "assistant", phase: "final_answer"),
            "{\"timestamp\":\"2026-08-01T01:00:11Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}",
            message("2026-08-01T02:00:00Z", role: "user", phase: ""),
            message("2026-08-01T02:00:02Z", role: "assistant", phase: "commentary")
        ]
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let snapshot = try await CodexUsageReader(calendar: calendar).load(now: date("2026-08-01T12:00:00Z"), codexHome: root)
        #expect(snapshot.topModels.first?.requests == 1)
        #expect(snapshot.topModels.first?.averageTurnSeconds == 10)
    }

    @Test func parsesBeyondOldTailLimitAndIgnoresIncompleteLastLine() async throws {
        let root = try fixture()
        let file = root.appendingPathComponent("session.jsonl")
        let initial = token("2026-08-01T01:00:00Z", total: 100) + "\n"
        let padding = String(repeating: "{\"type\":\"ignored\"}\n", count: 40_000)
        try (initial + padding + "{\"type\":").write(to: file, atomically: true, encoding: .utf8)
        let snapshot = try await CodexUsageReader(calendar: calendar).load(now: date("2026-08-01T12:00:00Z"), codexHome: root)
        #expect(snapshot.today.total == 100)
        #expect(snapshot.readWarning == nil)
    }

    @Test func sharesRiskClassificationWithoutFalseHealthyStates() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func rate(_ used: Double) -> RateWindow { RateWindow(usedPercent: used, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600)) }
        #expect(QuotaHealth.evaluate(rate: rate(90), percentPerHour: 1, now: now) == .critical)
        #expect(QuotaHealth.evaluate(rate: rate(30), percentPerHour: 100, now: now) == .watch)
        #expect(QuotaHealth.evaluate(rate: rate(30), percentPerHour: 1, now: now) == .healthy)
        #expect(QuotaHealth.evaluate(rate: rate(0), percentPerHour: nil, now: now) == .insufficient)
        #expect(QuotaHealth.evaluate(rate: rate(30), percentPerHour: 1, now: now.addingTimeInterval(3_601)) == .waiting)
    }

    @Test func retainsCanonicalQuotaAcrossSameSessionModelSwitchAndReset() async throws {
        let root = try fixture()
        let beforeReset = date("2026-08-01T12:00:00Z")
        func quota(_ timestamp: String, modelName: String, limitID: String, used: Int, reset: Date) throws -> String {
            var json = try JSONSerialization.jsonObject(with: Data(token(timestamp, total: 100).utf8)) as! [String: Any]
            var payload = json["payload"] as! [String: Any]
            payload["rate_limits"] = ["limit_id": limitID, "secondary": ["used_percent": used, "window_minutes": 10_080, "resets_at": reset.timeIntervalSince1970]]
            json["payload"] = payload
            return model(modelName) + "\n" + String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        }
        let canonical = try quota("2026-08-01T10:00:00Z", modelName: "main", limitID: "codex", used: 80, reset: beforeReset.addingTimeInterval(60))
        let alternate = try quota("2026-08-01T11:00:00Z", modelName: "alternate", limitID: "other-bucket", used: 0, reset: beforeReset.addingTimeInterval(3_600))
        try (canonical + "\n" + alternate).write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let reader = CodexUsageReader(calendar: calendar)
        let before = try await reader.load(now: beforeReset, codexHome: root)
        #expect(before.sevenDayRate?.usedPercent == 80)
        let after = try await reader.load(now: beforeReset.addingTimeInterval(61), codexHome: root)
        #expect(after.sevenDayRate == nil)
        #expect(await reader.parsedFileCount == 0)
    }

    @Test func computesCacheRatioFromDeltasAndLeavesMissingSamplesUnknown() async throws {
        let root = try fixture()
        let lines = [
            model("cached-model"),
            token("2026-07-31T23:00:00Z", total: 100).replacingOccurrences(of: "\"cached_input_tokens\":0", with: "\"cached_input_tokens\":20"),
            token("2026-08-01T01:00:00Z", total: 200).replacingOccurrences(of: "\"cached_input_tokens\":0", with: "\"cached_input_tokens\":100")
        ]
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("cached.jsonl"), atomically: true, encoding: .utf8)
        let missing = model("missing-cache") + "\n" + token("2026-08-01T01:00:00Z", total: 100).replacingOccurrences(of: "\"cached_input_tokens\":0,", with: "")
        try missing.write(to: root.appendingPathComponent("missing-cache.jsonl"), atomically: true, encoding: .utf8)
        let snapshot = try await CodexUsageReader(calendar: calendar).load(now: date("2026-08-07T12:00:00Z"), codexHome: root)
        #expect(snapshot.topModels.first(where: { $0.name == "cached-model" })?.cacheHitRate == 0.8)
        #expect(snapshot.topModels.first(where: { $0.name == "missing-cache" })?.cacheHitRate == nil)
    }

    @Test func widgetExpiryHeartbeatAndWriteFailure() throws {
        let root = try fixture()
        let destination = root.appendingPathComponent("widget.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func usage(_ checkedAt: Date) -> WidgetUsageData {
            WidgetUsageData(todayTokens: 100, weekTokens: 200, monthTokens: 300, contextTokens: 0, contextLimit: 0,
                            ratePercent: 30, rateWindowMinutes: 10_080, updatedAt: checkedAt, sampledAt: now,
                            rateResetsAt: now.addingTimeInterval(3_600))
        }
        let current = usage(now)
        #expect(current.currentRatePercent(at: now) == 30)
        #expect(current.currentRatePercent(at: now.addingTimeInterval(3_600)) == nil)
        var partial = current
        partial.sourceIncomplete = true
        #expect(!partial.isStale(at: now))
        #expect(current.isStale(at: now.addingTimeInterval(1_801)))
        #expect(try WidgetUsageCache.saveIfChanged(current, to: destination))
        #expect(try !WidgetUsageCache.saveIfChanged(usage(now.addingTimeInterval(300)), to: destination))
        #expect(try WidgetUsageCache.saveIfChanged(usage(now.addingTimeInterval(901)), to: destination))
        #expect(WidgetUsageCache.load(from: destination)?.updatedAt == now.addingTimeInterval(901))
        #expect(throws: (any Error).self) { try WidgetUsageCache.saveIfChanged(current, to: root.appendingPathComponent("missing/widget.json")) }
    }
}

struct QuotaObservationRegressionTests {
    @Test func quotaOnlyUpdatesDoNotResetTokenCountersOrContext() async throws {
        let root = TestFixtureDirectory.root.appendingPathComponent("quota-observation-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = now.addingTimeInterval(7 * 86_400).timeIntervalSince1970
        func event(_ offset: Double, info: Any, percent: Double?) throws -> String {
            var payload: [String: Any] = ["type": "token_count", "info": info]
            if let percent { payload["rate_limits"] = ["limit_id": "codex", "primary": ["used_percent": 12, "window_minutes": 300, "resets_at": reset], "secondary": ["used_percent": percent, "window_minutes": 10_080, "resets_at": reset]] }
            let json: [String: Any] = ["type": "event_msg", "timestamp": now.addingTimeInterval(offset).ISO8601Format(), "payload": payload]
            return String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
        }
        let baseline: [String: Any] = ["total_token_usage": ["input_tokens": 80, "output_tokens": 20, "total_tokens": 100], "last_token_usage": ["total_tokens": 50], "model_context_window": 200_000]
        let next: [String: Any] = ["total_token_usage": ["input_tokens": 100, "output_tokens": 30, "total_tokens": 130], "last_token_usage": ["total_tokens": 60], "model_context_window": 200_000]
        let file = sessions.appendingPathComponent("synthetic.jsonl")
        let cache = root.appendingPathComponent("cache")
        let reader = CodexUsageReader(cacheDirectory: cache)
        try event(0, info: baseline, percent: 3).write(to: file, atomically: true, encoding: .utf8)
        #expect(try await reader.load(now: now, codexHome: root).sevenDayRate?.usedPercent == 3)
        let lines = try [event(0, info: baseline, percent: 3), event(10, info: NSNull(), percent: 9)]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let quota = try await reader.load(now: now.addingTimeInterval(10), codexHome: root)
        #expect(quota.sevenDayRate?.usedPercent == 9)
        #expect(quota.mainRateSampledAt == now.addingTimeInterval(10))
        #expect(quota.primaryRateSampledAt == now.addingTimeInterval(10))
        #expect(quota.allTime.total == 100)
        #expect(quota.currentContextUsed == 50)
        #expect(quota.readWarning == nil)
        try (lines + [event(11, info: next, percent: nil)]).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let last = try await reader.load(now: now.addingTimeInterval(60), codexHome: root)
        #expect(last.allTime.total == 130)
        #expect(last.mainRateSampledAt == now.addingTimeInterval(10))
        let restarted = CodexUsageReader(cacheDirectory: cache)
        #expect(try await restarted.load(now: now.addingTimeInterval(60), codexHome: root) == last)
        #expect(await restarted.parsedFileCount == 0)
        try event(10, info: NSNull(), percent: 9).write(to: file, atomically: true, encoding: .utf8)
        let onlyQuota = try await reader.load(now: now.addingTimeInterval(60), codexHome: root, force: true)
        #expect(onlyQuota.sevenDayRate?.usedPercent == 9)
        #expect(onlyQuota.allTime.total == 0)
        #expect(onlyQuota.mainRateSampledAt == now.addingTimeInterval(10))
    }

    @Test func oldQuotaIsNotRenewedBySourceChecksOrUnknownSampleTimes() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func state(_ sampledAt: Date?, _ checkedAt: Date) -> QuotaSampleState {
            QuotaSampleState(percent: 9, sampledAt: sampledAt, resetsAt: now.addingTimeInterval(3_600), now: checkedAt)
        }
        #expect(state(now, now).remaining == 91)
        #expect(state(now, now.addingTimeInterval(899)).remaining == 91)
        let old = state(now, now.addingTimeInterval(900))
        #expect(old.remaining == nil)
        #expect(old.recordedRemaining == 91)
        #expect(old.lastRemaining == 91)
        #expect(old.description.contains("旧采样"))
        #expect(state(nil, now).remaining == nil)
        #expect(state(nil, now).recordedRemaining == nil)
        #expect(state(now.addingTimeInterval(1), now).remaining == nil)
        #expect(state(now.addingTimeInterval(1), now).recordedRemaining == nil)
        #expect(state(now, now.addingTimeInterval(3_600)).lastRemaining == nil)
        #expect(state(now, now.addingTimeInterval(3_600)).recordedRemaining == nil)
        #expect(QuotaSampleState.deadlines(sampledAt: now, resetsAt: now.addingTimeInterval(3_600), now: now).first == now.addingTimeInterval(900))
        let widget = WidgetUsageData(todayTokens: 0, weekTokens: 0, monthTokens: 0, contextTokens: 0, contextLimit: 0,
                                    ratePercent: 9, rateWindowMinutes: 10_080, updatedAt: now.addingTimeInterval(900), sampledAt: now,
                                    rateResetsAt: now.addingTimeInterval(3_600))
        #expect(widget.currentRatePercent(at: now.addingTimeInterval(900)) == nil)
        #expect(widget.recordedRatePercent(at: now.addingTimeInterval(900)) == 9)
        #expect(widget.recordedRatePercent(at: now.addingTimeInterval(3_600)) == nil)
        #expect(widget.quotaSample(at: now.addingTimeInterval(900)).lastRemaining == 91)
    }

    @Test func oldQuotaRemainsVisibleWithoutEnablingCurrentPredictions() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var snapshot = UsageSnapshot.empty
        snapshot.mainMenuRate = RateWindow(usedPercent: 15, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(86_400))
        snapshot.mainRateSampledAt = now.addingTimeInterval(-3_600)
        let sample = QuotaSampleState(percent: snapshot.sevenDayRate?.usedPercent, sampledAt: snapshot.mainRateSampledAt,
                                      resetsAt: snapshot.sevenDayRate?.resetsAt, now: now)
        #expect(sample.isStale)
        #expect(sample.recordedRemaining == 85)
        #expect(sample.currentPercent == nil)
        #expect(snapshot.currentSevenDayRate(at: now) == nil)
        // A new account starts with an empty snapshot; never carry the old display through.
        snapshot = .empty
        #expect(QuotaSampleState(percent: snapshot.sevenDayRate?.usedPercent, sampledAt: snapshot.mainRateSampledAt,
                                resetsAt: snapshot.sevenDayRate?.resetsAt, now: now).recordedRemaining == nil)
    }
}

struct QuotaCacheUpgradeRegressionTests {
    @Test func oldSummaryCacheIsReparsedAndInvalidTokenDataDoesNotBlockQuota() async throws {
        let root = TestFixtureDirectory.root.appendingPathComponent("quota-upgrade-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions")
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let quota = """
        {"type":"event_msg","timestamp":"\(now.ISO8601Format())","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","secondary":{"used_percent":9,"window_minutes":10080,"resets_at":\(Int(now.timeIntervalSince1970)+86400)}}}}
        """
        let file = sessions.appendingPathComponent("synthetic.jsonl")
        try quota.write(to: file, atomically: true, encoding: .utf8)
        let first = CodexUsageReader(cacheDirectory: cache)
        #expect(try await first.load(now: now, codexHome: root).sevenDayRate?.usedPercent == 9)
        let enumerator = try #require(FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil))
        var downgraded = 0
        for url in enumerator.allObjects.compactMap({ $0 as? URL }) where url.pathExtension == "plist" {
            var plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
            plist["version"] = 5
            try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
            downgraded += 1
        }
        #expect(downgraded == 2)
        let upgraded = CodexUsageReader(cacheDirectory: cache)
        #expect(try await upgraded.load(now: now, codexHome: root).sevenDayRate?.usedPercent == 9)
        #expect(await upgraded.parsedFileCount == 1)
        #expect(try String(contentsOf: file, encoding: .utf8) == quota)
        let malformed = quota.replacingOccurrences(of: "\"info\":null", with: "\"info\":{\"total_token_usage\":{\"total_tokens\":\"invalid\"}}")
        try malformed.write(to: file, atomically: true, encoding: .utf8)
        let result = try await upgraded.load(now: now, codexHome: root, force: true)
        #expect(result.sevenDayRate?.usedPercent == 9)
        #expect(result.allTime.total == 0)
        #expect(result.readWarning != nil)
    }
}
