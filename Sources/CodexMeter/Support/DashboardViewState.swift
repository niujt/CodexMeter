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
}

enum ProjectRange: String, CaseIterable, Identifiable {
    case today, sevenDays, thirtyDays
    var id: String { rawValue }
    var title: String { switch self { case .today: "今天"; case .sevenDays: "近 7 天"; case .thirtyDays: "近 30 天" } }

    /// Match the reader's calendar-day windows, including the current day.
    func records(_ records: [UsageRecord], projectPath: String, now: Date = .now,
                 calendar: Calendar = .current) -> [UsageRecord] {
        let startOfToday = calendar.startOfDay(for: now)
        let daysBack = switch self { case .today: 0; case .sevenDays: 6; case .thirtyDays: 29 }
        let start = calendar.date(byAdding: .day, value: -daysBack, to: startOfToday) ?? startOfToday
        return records.filter { $0.project == projectPath && $0.date >= start && $0.date <= now }
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
}
