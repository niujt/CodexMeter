import Foundation

struct RateSample: Codable, Equatable { let date: Date; let usedPercent: Double; let resetsAt: Date }

struct RateVelocity: Sendable {
    let percentPerHour: Double
    let windowsUsed: [Int]

    var description: String {
        windowsUsed.map(String.init).joined(separator: " / ")
    }
}

enum RateHistory {
    private static func key(_ scope: QuotaScope) -> String { "codexMeter.rateHistory.v2." + scope.id }
    static func append(_ rate: RateWindow, sampledAt: Date, scope: QuotaScope,
                       defaults: UserDefaults = .standard, now: Date = .now) {
        guard sampledAt >= scope.since, sampledAt <= now, rate.resetsAt > now,
              rate.usedPercent.isFinite, (0...100).contains(rate.usedPercent) else { return }
        let existing = samples(scope: scope, defaults: defaults)
        var retained = existing.filter { $0.date >= max(scope.since, now.addingTimeInterval(-30 * 86_400)) }
        // Never turn a repeated cached observation into a new velocity sample.
        if let last = retained.last, sampledAt <= last.date { return }
        retained.append(.init(date: sampledAt, usedPercent: rate.usedPercent, resetsAt: rate.resetsAt))
        guard retained != existing, let data = try? JSONEncoder().encode(retained) else { return }
        defaults.set(data, forKey: key(scope))
    }

    static func samples(scope: QuotaScope, defaults: UserDefaults = .standard) -> [RateSample] {
        (try? JSONDecoder().decode([RateSample].self, from: defaults.data(forKey: key(scope)) ?? Data())) ?? []
    }

    /// Uses actual 7-day quota changes.  Newer windows carry more weight,
    /// but missing windows never get fabricated from token totals.
    static func weightedVelocity(scope: QuotaScope, resetsAt: Date, defaults: UserDefaults = .standard, now: Date = .now) -> RateVelocity? {
        let all = samples(scope: scope, defaults: defaults).filter { $0.resetsAt == resetsAt && $0.date >= scope.since }.sorted { $0.date < $1.date }
        let windows: [(hours: Int, weight: Double)] = [(1, 0.5), (6, 0.3), (24, 0.2)]
        var weighted = 0.0
        var weights = 0.0
        var used: [Int] = []

        for window in windows {
            let cutoff = now.addingTimeInterval(-Double(window.hours) * 3_600)
            let withinWindow = all.filter { $0.date >= cutoff && $0.date <= now }
            guard let first = withinWindow.first, let last = withinWindow.last else { continue }
            let elapsed = last.date.timeIntervalSince(first.date) / 3_600
            let delta = last.usedPercent - first.usedPercent
            guard elapsed >= 1.0 / 12.0, delta > 0 else { continue }
            weighted += (delta / elapsed) * window.weight
            weights += window.weight
            used.append(window.hours)
        }
        guard weights > 0 else { return nil }
        return RateVelocity(percentPerHour: weighted / weights, windowsUsed: used)
    }
}
