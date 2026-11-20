import Foundation
import Testing
@testable import CodexMeter

struct UsageComparisonTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    @Test func readerComparesCompletedHoursAndPreservesTokenBreakdown() async throws {
        let root = TestFixtureDirectory.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("fixture.jsonl")
        let events = [
            """
            {"timestamp":"2026-11-19T11:32:00Z","type":"session_meta","payload":{"cwd":"/demo/app"}}
            """,
            """
            {"timestamp":"2026-11-19T11:33:00Z","type":"turn_context","payload":{"model":"demo-model"}}
            """,
            token(at: "2026-11-19T11:35:00Z", input: 24_000_000, cached: 10_000_000, output: 6_000_000),
            token(at: "2026-11-19T12:02:00Z", input: 30_000_000, cached: 12_000_000, output: 8_000_000),
            token(at: "2026-11-20T11:47:00Z", input: 89_000_000, cached: 34_000_000, output: 28_000_000),
            token(at: "2026-11-20T12:04:00Z", input: 100_000_000, cached: 36_000_000, output: 35_000_000),
        ]
        try (events.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let reader = CodexUsageReader(calendar: calendar)
        let now = try date("2026-11-20T12:09:00Z")
        let first = try await reader.load(now: now, codexHome: root)
        let report = try #require(first.currentUsageComparison(at: now, calendar: calendar))
        #expect(report.totals.today.total == 79_000_000)
        #expect(report.totals.yesterday.total == 30_000_000)
        #expect(report.totals.change == 49_000_000)
        #expect(report.isSpike)
        let project = try #require(report.leadingProject)
        #expect(project.path == "/demo/app")
        #expect(project.hours[11]?.change == 49_000_000)
        #expect(project.models["demo-model"]?.change == 49_000_000)
        #expect(project.totals.today.uncachedInput == 37_000_000)
        #expect(project.totals.today.cachedInputPortion == 22_000_000)
        #expect(project.totals.today.output == 20_000_000)
        #expect(first.today.total == 97_000_000)

        let reused = try await reader.load(now: now.addingTimeInterval(60), codexHome: root)
        #expect(reused.usageComparison == report)
        #expect(await reader.reusedAggregateCount == 1)
        let nextHour = try await reader.load(now: now.addingTimeInterval(3_600), codexHome: root)
        #expect(nextHour.usageComparison?.totals.today.total == 97_000_000)
        #expect(nextHour.usageComparison?.totals.yesterday.total == 38_000_000)
        let tomorrow = try date("2026-11-21T00:00:00Z")
        #expect(first.currentUsageComparison(at: tomorrow, calendar: calendar) == nil)
    }

    @Test func comparisonNeedsBaselineAndRanksIncrementInsteadOfTotal() throws {
        let now = try date("2026-11-20T15:48:00Z")
        let today = try date("2026-11-20T13:00:00Z")
        let yesterday = today.addingTimeInterval(-86_400)
        func record(_ date: Date, _ project: String, _ tokens: Int) -> UsageRecord {
            UsageRecord(date: date, project: project, model: "demo", tokens: tokens)
        }
        let current = [record(today, "/demo/largest", 90_000_000), record(today, "/demo/rising", 40_000_000)]
        #expect(UsageComparison.make(records: current, now: now, calendar: calendar) == nil)
        let report = try #require(UsageComparison.make(
            records: current + [record(yesterday, "/demo/largest", 85_000_000), record(yesterday, "/demo/rising", 20_000_000)],
            now: now, calendar: calendar
        ))
        #expect(report.leadingProject?.path == "/demo/rising")
        #expect(report.totals.change == 25_000_000)
        #expect(!report.isSpike)
    }

    @Test func runwayRequiresFreshWeeklyQuotaAndHandlesDepletion() {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let reset = now.addingTimeInterval(3 * 3_600)
        func runway(used: Double = 80, sampledAgo: Double = 0, minutes: Int = 10_080, speed: Double? = 10) -> QuotaRunway {
            QuotaRunway.evaluate(
                sample: QuotaSampleState(percent: used, sampledAt: now.addingTimeInterval(-sampledAgo), resetsAt: reset, now: now),
                windowMinutes: minutes, measuredVelocity: speed
            )
        }
        #expect(runway() == .estimated(hours: 2, beforeReset: true))
        #expect(runway(speed: 2) == .estimated(hours: 10, beforeReset: false))
        #expect(runway(sampledAgo: QuotaSampleState.lifetime) == .waiting)
        #expect(runway(minutes: 300) == .waiting)
        #expect(runway(used: 0, speed: nil) == .insufficient)
        #expect(runway(used: 100, speed: nil) == .depleted)
    }

    @Test func olderWidgetCacheWithoutMeasuredVelocityStillDecodes() throws {
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let old = WidgetUsageData(todayTokens: 1, weekTokens: 1, monthTokens: 1, contextTokens: 0, contextLimit: 0,
                                  ratePercent: 60, rateWindowMinutes: 10_080, updatedAt: now, sampledAt: now,
                                  rateResetsAt: now.addingTimeInterval(3_600))
        let cache = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(WidgetUsageData.self, from: cache)
        #expect(decoded.quotaVelocity == nil)
        #expect(decoded.quotaRunway(at: now).summary == "预计可撑到重置")
        #expect(decoded.quotaRunway(at: now.addingTimeInterval(900)) == .waiting)
    }

    private func token(at date: String, input: Int, cached: Int, output: Int) -> String {
        """
        {"timestamp":"\(date)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"total_tokens":\(input + output)}}}}
        """
    }
}
