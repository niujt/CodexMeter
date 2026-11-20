import Foundation

struct UsageComparison: Equatable, Sendable, Identifiable {
    struct Totals: Equatable, Sendable {
        var today = TokenUsage()
        var yesterday = TokenUsage()
        var change: Int { today.total - yesterday.total }

        mutating func add(_ usage: TokenUsage, today isToday: Bool) {
            if isToday {
                today = today + usage
            } else {
                yesterday = yesterday + usage
            }
        }
    }

    struct Project: Equatable, Sendable, Identifiable {
        let path: String
        var totals = Totals()
        var models: [String: Totals] = [:]
        var hours: [Int: Totals] = [:]
        var id: String { path }
        var name: String { ProjectUsage(path: path, tokens: 0).name }

        mutating func add(_ record: UsageRecord, since start: Date, today: Bool) {
            totals.add(record.usage, today: today)
            models[record.model, default: Totals()].add(record.usage, today: today)
            let hour = Int(record.date.timeIntervalSince(start) / 3_600)
            hours[hour, default: Totals()].add(record.usage, today: today)
        }
    }

    let today: DateInterval
    let yesterday: DateInterval
    let totals: Totals
    let projects: [Project]
    var id: Date { today.end }
    var leadingProject: Project? { projects.first { $0.totals.change > 0 } }

    var isSpike: Bool {
        totals.yesterday.total > 0 && totals.change >= 1_000_000
            && Double(totals.change) / Double(totals.yesterday.total) >= 0.25
    }

    var cutoffLabel: String {
        today.end.formatted(.dateTime.hour().minute())
    }

    static func make(records: [UsageRecord], now: Date, calendar: Calendar = .current) -> Self? {
        let todayStart = calendar.startOfDay(for: now)
        guard let todayEnd = calendar.dateInterval(of: .hour, for: now)?.start,
              todayEnd > todayStart,
              let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart),
              let yesterdayEnd = calendar.date(byAdding: .day, value: -1, to: todayEnd),
              yesterdayEnd.timeIntervalSince(yesterdayStart) == todayEnd.timeIntervalSince(todayStart)
        else { return nil }

        var totals = Totals()
        var projects: [String: Project] = [:]
        for record in records where record.usage.total > 0 {
            let isToday = record.date >= todayStart && record.date < todayEnd
            let isYesterday = record.date >= yesterdayStart && record.date < yesterdayEnd
            guard isToday || isYesterday else { continue }
            totals.add(record.usage, today: isToday)
            projects[record.project, default: Project(path: record.project)].add(
                record, since: isToday ? todayStart : yesterdayStart, today: isToday
            )
        }
        guard totals.yesterday.total > 0 else { return nil }
        let ranked = projects.values.sorted {
            if $0.totals.change != $1.totals.change { return $0.totals.change > $1.totals.change }
            return $0.path < $1.path
        }
        return Self(today: DateInterval(start: todayStart, end: todayEnd),
                    yesterday: DateInterval(start: yesterdayStart, end: yesterdayEnd),
                    totals: totals, projects: ranked)
    }
}

extension UsageSnapshot {
    func currentUsageComparison(at now: Date = .now, calendar: Calendar = .current) -> UsageComparison? {
        guard let usageComparison, readWarning == nil, usageComparison.today.end <= now,
              calendar.isDate(usageComparison.today.start, inSameDayAs: now) else { return nil }
        return usageComparison
    }
}
