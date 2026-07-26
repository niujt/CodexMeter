import Foundation

struct RateSample: Codable { let date: Date; let usedPercent: Double }

enum RateHistory {
    private static let key = "codexMeter.rateHistory"
    static func append(_ percent: Double) {
        var samples = (try? JSONDecoder().decode([RateSample].self, from: UserDefaults.standard.data(forKey: key) ?? Data())) ?? []
        samples.append(.init(date: .now, usedPercent: percent))
        let cutoff = Date.now.addingTimeInterval(-30 * 86_400)
        samples = samples.filter { $0.date >= cutoff }
        UserDefaults.standard.set(try? JSONEncoder().encode(samples), forKey: key)
    }
}
