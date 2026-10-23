import Foundation

struct TrendPoint: Identifiable, Equatable {
    let date: Date
    /// nil means there is no recorded increment for this slot, not zero usage.
    let tokens: Int?
    var id: Date { date }
}

enum TrendSeries {
    /// Twenty-four consecutive local clock hours, including the current partial hour.
    /// Calendar arithmetic preserves both repeated fall-back hours and skips spring gaps.
    static func hourly(records: [UsageRecord], now: Date = .now,
                       calendar: Calendar = .current) -> [TrendPoint] {
        guard let currentHour = calendar.dateInterval(of: .hour, for: now)?.start else { return [] }
        let hours = (0..<24).reversed().compactMap {
            calendar.date(byAdding: .hour, value: -$0, to: currentHour)
        }
        guard let firstHour = hours.first else { return [] }
        var totals: [Date: Int] = [:]
        for record in records where record.date >= firstHour && record.date <= now {
            guard let hour = calendar.dateInterval(of: .hour, for: record.date)?.start,
                  hour <= currentHour else { continue }
            totals[hour, default: 0] += record.tokens
        }
        return hours.map { TrendPoint(date: $0, tokens: totals[$0]) }
    }
}
