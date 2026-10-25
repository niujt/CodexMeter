import Foundation
import Observation

/// Kept by the dashboard window so navigating away does not discard page filters.
@MainActor
@Observable
final class DashboardViewState {
    var projectRange = ProjectRange.sevenDays
    var showsFullProjectPaths = false
    var trendGranularity = TrendGranularity.daily
    var historyRange = HistoryRange.thirtyDays
    var historyModel = "全部"
    var historyProject = "全部"
    var showsAllHistoryCycles = false

    @ObservationIgnored private var historyContextID: String?
    @ObservationIgnored private var hasHistoryContext = false

    /// Observe from the dashboard root, including while another page is visible.
    func synchronizeHistoryContext(_ contextID: String?) {
        guard !hasHistoryContext || historyContextID != contextID else { return }
        hasHistoryContext = true
        historyContextID = contextID
        historyModel = "全部"
        historyProject = "全部"
        showsAllHistoryCycles = false
    }

    /// A model or project can also disappear as the local 30-day window advances.
    func reconcileHistoryFilters(with records: [UsageRecord]) {
        if historyModel != "全部", !records.contains(where: { $0.model == historyModel }) {
            historyModel = "全部"
        }
        if historyProject != "全部", !records.contains(where: { $0.project == historyProject }) {
            historyProject = "全部"
        }
    }
}

enum CalendarDayWindow {
    /// Include today and the preceding local calendar days, never future records.
    static func range(days: Int, now: Date = .now, calendar: Calendar = .current) -> ClosedRange<Date> {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -max(0, days - 1), to: today) ?? today
        return start...now
    }
}

enum ProjectRange: String, CaseIterable, Identifiable {
    case today, sevenDays, thirtyDays
    var id: String { rawValue }
    var title: String { switch self { case .today: "今天"; case .sevenDays: "近 7 天"; case .thirtyDays: "近 30 天" } }

    /// Match the reader's calendar-day windows, including the current day.
    func records(_ records: [UsageRecord], projectPath: String, now: Date = .now,
                 calendar: Calendar = .current) -> [UsageRecord] {
        let days = switch self { case .today: 1; case .sevenDays: 7; case .thirtyDays: 30 }
        let range = CalendarDayWindow.range(days: days, now: now, calendar: calendar)
        return records.filter { $0.project == projectPath && range.contains($0.date) }
            .sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                return $0.model < $1.model
            }
    }
}

enum TrendGranularity: String, CaseIterable, Identifiable {
    case daily, hourly
    var id: String { rawValue }
    var title: String { self == .daily ? "按天" : "近 24 小时" }
}

enum HistoryRange: Int, CaseIterable, Identifiable {
    case sevenDays = 7, thirtyDays = 30
    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String { self == .sevenDays ? "近 7 天" : "近 30 天" }

    func dateRange(now: Date = .now, calendar: Calendar = .current) -> ClosedRange<Date> {
        CalendarDayWindow.range(days: days, now: now, calendar: calendar)
    }
}
