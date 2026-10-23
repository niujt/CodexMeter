import Foundation
import Testing
@testable import CodexMeter

struct DashboardInteractionTests {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    @Test func projectDetailsRespectSelectedCalendarDaysAndProject() {
        let calendar = calendar("America/Los_Angeles")
        let now = date("2026-03-09T12:00:00-07:00")
        let dates = [
            "2026-03-09T00:00:00-07:00", // Today.
            "2026-03-03T00:00:00-08:00", // First of seven local days, before DST.
            "2026-03-02T23:00:00-08:00", // Outside seven days.
            "2026-02-08T00:00:00-08:00", // First of thirty local days.
            "2026-02-07T23:00:00-08:00", // Outside thirty days.
            "2026-03-09T13:00:00-07:00"  // Future data must not enter the detail.
        ].map(date)
        var records = dates.enumerated().map {
            UsageRecord(date: $0.element, project: "/work/app", model: "main", tokens: $0.offset + 1)
        }
        records.append(UsageRecord(date: dates[0], project: "/other/app", model: "main", tokens: 100))

        let today = ProjectRange.today.records(records, projectPath: "/work/app", now: now, calendar: calendar)
        let week = ProjectRange.sevenDays.records(records, projectPath: "/work/app", now: now, calendar: calendar)
        let month = ProjectRange.thirtyDays.records(records, projectPath: "/work/app", now: now, calendar: calendar)
        #expect(today.map(\.tokens) == [1])
        #expect(week.map(\.tokens) == [1, 2])
        #expect(month.map(\.tokens) == [1, 2, 3, 4])
        #expect(ProjectRange.thirtyDays.records(records, projectPath: "/missing", now: now, calendar: calendar).isEmpty)
    }

    @Test func hourlySeriesKeepsGapsDistinctFromExplicitZeroAndAggregatesModels() {
        let calendar = calendar("Asia/Shanghai")
        let now = date("2026-10-24T10:35:00+08:00")
        let records = [
            UsageRecord(date: date("2026-10-23T10:59:00+08:00"), project: "/a", model: "main", tokens: 900),
            UsageRecord(date: date("2026-10-23T11:15:00+08:00"), project: "/a", model: "main", tokens: 20),
            UsageRecord(date: date("2026-10-23T11:45:00+08:00"), project: "/b", model: "spark", tokens: 30),
            UsageRecord(date: date("2026-10-23T12:01:00+08:00"), project: "/a", model: "main", tokens: 0),
            UsageRecord(date: date("2026-10-24T10:10:00+08:00"), project: "/a", model: "main", tokens: 8),
            UsageRecord(date: date("2026-10-24T10:50:00+08:00"), project: "/a", model: "main", tokens: 900)
        ]
        let points = TrendSeries.hourly(records: records, now: now, calendar: calendar)
        #expect(points.count == 24)
        #expect(points.first?.date == date("2026-10-23T11:00:00+08:00"))
        #expect(points.last?.date == date("2026-10-24T10:00:00+08:00"))
        #expect(points[0].tokens == 50)
        #expect(points[1].tokens == 0)
        #expect(points[2].tokens == nil)
        #expect(points[23].tokens == 8)
        #expect(TrendSeries.hourly(records: [], now: now, calendar: calendar).allSatisfy { $0.tokens == nil })
    }

    @Test func hourlySeriesSkipsMissingSpringHourAndPreservesBothFallHours() {
        let calendar = calendar("America/Los_Angeles")
        let spring = TrendSeries.hourly(records: [], now: date("2026-03-08T04:30:00-07:00"), calendar: calendar)
        #expect(spring.count == 24)
        #expect(Set(spring.map(\.date)).count == 24)
        let springDayHours = spring.filter { calendar.component(.day, from: $0.date) == 8 }
            .map { calendar.component(.hour, from: $0.date) }
        #expect(springDayHours == [0, 1, 3, 4])

        let firstOne = date("2026-11-01T01:00:00-07:00")
        let secondOne = date("2026-11-01T01:00:00-08:00")
        let records = [
            UsageRecord(date: firstOne.addingTimeInterval(900), project: "/a", model: "main", tokens: 10),
            UsageRecord(date: secondOne.addingTimeInterval(900), project: "/a", model: "main", tokens: 20)
        ]
        let fall = TrendSeries.hourly(records: records, now: date("2026-11-01T04:30:00-08:00"), calendar: calendar)
        #expect(fall.count == 24)
        #expect(Set(fall.map(\.date)).count == 24)
        let repeated = fall.filter {
            calendar.component(.day, from: $0.date) == 1 && calendar.component(.hour, from: $0.date) == 1
        }
        #expect(repeated.map(\.date) == [firstOne, secondOne])
        #expect(repeated.map(\.tokens) == [10, 20])
    }
}
