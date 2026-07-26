import Foundation
import UserNotifications

enum UsageNotifier {
    static func evaluate(_ rate: RateWindow) {
        let remaining = Int((100 - rate.usedPercent).rounded())
        let threshold = UserDefaults.standard.object(forKey: "codexMeter.lowRateThreshold") as? Int ?? 20
        let day = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        let level = remaining <= 10 ? "critical" : "low"
        let key = "codexMeter.notified." + String(day) + "." + level
        let deduplicate = UserDefaults.standard.object(forKey: "codexMeter.deduplicateAlerts") as? Bool ?? true
        notifyUpcomingReset(rate, deduplicate: deduplicate)
        notifyPredictedExhaustion(rate, deduplicate: deduplicate)
        guard remaining <= threshold, !(deduplicate && UserDefaults.standard.bool(forKey: key)) else { return }
        if deduplicate { UserDefaults.standard.set(true, forKey: key) }
        let remainingText = String(remaining)
        let resetText = UsageFormatters.countdown(to: rate.resetsAt)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Codex 7 天额度偏低"
            content.body = "当前剩余 " + remainingText + "% ，约 " + resetText + " 后重置。"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    private static func notifyUpcomingReset(_ rate: RateWindow, deduplicate: Bool) {
        guard rate.resetsAt.timeIntervalSinceNow > 0, rate.resetsAt.timeIntervalSinceNow <= 1_800 else { return }
        let key = "codexMeter.notified.reset." + String(Int(rate.resetsAt.timeIntervalSince1970))
        guard !(deduplicate && UserDefaults.standard.bool(forKey: key)) else { return }
        if deduplicate { UserDefaults.standard.set(true, forKey: key) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Codex 额度即将重置"
            content.body = "7 天额度将在 30 分钟内重置。"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }

    private static func notifyPredictedExhaustion(_ rate: RateWindow, deduplicate: Bool) {
        guard let velocity = RateHistory.weightedVelocity(), velocity.percentPerHour > 0 else { return }
        let remainingHours = (100 - rate.usedPercent) / velocity.percentPerHour
        guard remainingHours < rate.resetsAt.timeIntervalSinceNow / 3_600 else { return }
        let key = "codexMeter.notified.exhaustion." + String(Calendar.current.startOfDay(for: .now).timeIntervalSince1970)
        guard !(deduplicate && UserDefaults.standard.bool(forKey: key)) else { return }
        if deduplicate { UserDefaults.standard.set(true, forKey: key) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Codex 额度可能提前耗尽"
            content.body = "按近 " + velocity.description + " 小时额度变化速度，预计将在重置前耗尽。"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
        }
    }
}
