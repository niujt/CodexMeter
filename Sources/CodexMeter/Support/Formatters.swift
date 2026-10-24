import Foundation

enum ForecastDurationUnit: String, CaseIterable, Identifiable {
    case hours, days
    static let preferenceKey = "codexMeter.forecastDurationUnit"
    var id: String { rawValue }
    var title: String { self == .hours ? "小时" : "天" }
}

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

    static func percentage(_ ratio: Double) -> String {
        let percent = min(1, max(0, ratio)) * 100
        return "\(compactTokens.string(from: NSNumber(value: percent)) ?? "0")%"
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

    static func duration(hours: Double, unit: ForecastDurationUnit = .hours) -> String {
        guard hours.isFinite, hours >= 0 else { return "暂无估算" }
        if unit == .days {
            let days = hours / 24
            if days > 0 && days < 0.01 { return "不足 0.01 天" }
            return "\(days.formatted(.number.precision(.fractionLength(0...2)))) 天"
        }
        guard hours < Double(Int.max / 60) else { return "超出可显示范围" }
        let minutes = max(0, Int(hours * 60))
        return "\(minutes / 60)小时\(minutes % 60)分"
    }

    static func turnDuration(seconds: Double) -> String {
        if seconds >= 60 {
            return "\(Int((seconds / 60).rounded()))分"
        }
        return "\(max(1, Int(seconds.rounded())))秒"
    }

    static func replySpeed(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) tokens/s"
    }
}
