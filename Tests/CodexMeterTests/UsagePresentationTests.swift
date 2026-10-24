import Foundation
import Testing
@testable import CodexMeter

struct UsagePresentationTests {
    @Test func cachedInputIsASubsetAndRemainsInOriginalTotal() {
        let usage = TokenUsage(input: 1_000, cachedInput: 800, output: 200, reasoningOutput: 50, total: 1_200)
        #expect(usage.uncachedInput == 200)
        #expect(usage.cachedInputPortion == 800)
        #expect(usage.uncachedInput + usage.cachedInputPortion == usage.input)
        #expect(usage.uncachedInput + usage.cachedInputPortion + usage.output == usage.total)
        #expect(usage.total == 1_200) // Neither cache nor reasoning may be subtracted/added again.
        let aggregated = usage + usage
        #expect(aggregated.uncachedInput == 400)
        #expect(aggregated.cachedInputPortion == 1_600)
        #expect(aggregated.total == 2_400)
    }

    @Test func malformedCacheCountsDoNotProduceNegativeOrDuplicateInput() {
        let excessive = TokenUsage(input: 100, cachedInput: 200)
        #expect(excessive.uncachedInput == 0)
        #expect(excessive.cachedInputPortion == 100)
        let negative = TokenUsage(input: 100, cachedInput: -20)
        #expect(negative.uncachedInput == 100)
        #expect(negative.cachedInputPortion == 0)
    }

    @Test func alternateChartsNeverConnectAcrossUnrecordedHours() {
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        let values: [Int?] = [nil, 10, 0, nil, nil, 20, nil]
        let points = values.enumerated().map {
            TrendPoint(date: start.addingTimeInterval(Double($0.offset) * 3_600), tokens: $0.element)
        }
        let segments = TrendSeries.contiguousSegments(points)
        #expect(segments.map { $0.compactMap(\.tokens) } == [[10, 0], [20]])
        #expect(segments[0].last?.date == points[2].date)
        #expect(segments[1].first?.date == points[5].date)
        #expect(TrendSeries.contiguousSegments(points.filter { $0.tokens == nil }).isEmpty)
    }

    @Test func forecastUnitsHandleDaysAndInvalidDurations() {
        #expect(UsageFormatters.duration(hours: 30.5, unit: .hours) == "30小时30分")
        #expect(UsageFormatters.duration(hours: 96, unit: .days) == "4 天")
        #expect(UsageFormatters.duration(hours: 0.1, unit: .days) == "不足 0.01 天")
        #expect(UsageFormatters.duration(hours: .infinity, unit: .hours) == "暂无估算")
        #expect(UsageFormatters.duration(hours: -.infinity, unit: .days) == "暂无估算")
    }
}
