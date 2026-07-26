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
}
