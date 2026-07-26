import Foundation

enum UsageFormatters {
    static let compactTokens: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    static func tokens(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return "\(compactTokens.string(from: NSNumber(value: Double(value) / 1_000_000)) ?? "0")M"
        case 1_000...:
            return "\(compactTokens.string(from: NSNumber(value: Double(value) / 1_000)) ?? "0")K"
        default:
            return value.formatted()
        }
    }

    static func countdown(to date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours >= 24 {
            return "\(hours / 24)天\(hours % 24)小时"
        }
        if hours > 0 {
            return "\(hours)小时\(minutes)分"
        }
        return "\(minutes)分钟"
    }

    static func duration(hours: Double) -> String {
        let minutes = max(0, Int(hours * 60))
        return "\(minutes / 60)小时\(minutes % 60)分"
    }
}
