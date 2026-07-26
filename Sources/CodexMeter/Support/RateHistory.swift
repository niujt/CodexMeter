import Foundation

struct RateSample: Codable { let date: Date; let usedPercent: Double }

struct RateVelocity: Sendable {
    let percentPerHour: Double
    let windowsUsed: [Int]

    var description: String {
        windowsUsed.map(String.init).joined(separator: " / ")
    }
}

enum RateHistory {
    private static let key = "codexMeter.rateHistory"
    static func append(_ percent: Double) {
        var samples = (try? JSONDecoder().decode([RateSample].self, from: UserDefaults.standard.data(forKey: key) ?? Data())) ?? []
        let now = Date.now
        // 菜单、详情窗口都可能触发刷新；同一分钟内只保留最新采样，避免
        // 把同一个额度值误认为多次消耗。
        if let last = samples.last, now.timeIntervalSince(last.date) < 45 {
            samples[samples.count - 1] = .init(date: now, usedPercent: percent)
        } else {
            samples.append(.init(date: now, usedPercent: percent))
        }
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        samples = samples.filter { $0.date >= cutoff }
        UserDefaults.standard.set(try? JSONEncoder().encode(samples), forKey: key)
    }

    static func samples() -> [RateSample] {
        (try? JSONDecoder().decode([RateSample].self, from: UserDefaults.standard.data(forKey: key) ?? Data())) ?? []
    }

    /// Uses actual 7-day quota changes.  Newer windows carry more weight,
    /// but missing windows never get fabricated from token totals.
    static func weightedVelocity(now: Date = .now) -> RateVelocity? {
        let all = samples().sorted { $0.date < $1.date }
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
