import Foundation
import UserNotifications

struct QuotaNotification: Sendable {
    let identifier: String
    let title: String
    let body: String
}

/// Keep requests in flight separate from successfully submitted reminders.
/// A denied permission or failed submission must remain retryable.
@MainActor
final class QuotaNotificationDelivery {
    typealias Authorize = @MainActor () async throws -> Bool
    typealias Submit = @MainActor (QuotaNotification) async throws -> Void

    private let defaults: UserDefaults
    private let authorize: Authorize
    private let submit: Submit
    private var inFlight: Set<String> = []

    init(defaults: UserDefaults = .standard,
         authorize: @escaping Authorize = {
             try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
         },
         submit: @escaping Submit = { reminder in
             let content = UNMutableNotificationContent()
             content.title = reminder.title
             content.body = reminder.body
             try await UNUserNotificationCenter.current().add(
                 UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: nil))
         }) {
        self.defaults = defaults
        self.authorize = authorize
        self.submit = submit
    }

    func send(_ reminder: QuotaNotification, deduplicate: Bool) async {
        let key = reminder.identifier
        guard !inFlight.contains(key), !(deduplicate && defaults.bool(forKey: key)) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        do {
            guard try await authorize() else { return }
            try await submit(reminder)
            // Acceptance by the system does not guarantee the user has seen the alert.
            if deduplicate { defaults.set(true, forKey: key) }
        } catch {
            // Do not mark this reminder delivered; the next refresh can retry.
        }
    }
}

@MainActor
enum UsageNotifier {
    private static let delivery = QuotaNotificationDelivery()

    static func evaluate(_ rate: RateWindow, scope: QuotaScope, velocity: RateVelocity?) {
        let defaults = UserDefaults.standard
        let deduplicate = defaults.object(forKey: "codexMeter.deduplicateAlerts") as? Bool ?? true
        let reminders = reminders(rate, scope: scope, velocity: velocity, defaults: defaults)
        Task {
            for reminder in reminders { await delivery.send(reminder, deduplicate: deduplicate) }
        }
    }

    static func reminders(_ rate: RateWindow, scope: QuotaScope, velocity: RateVelocity?,
                          defaults: UserDefaults, now: Date = .now,
                          calendar: Calendar = .current) -> [QuotaNotification] {
        guard rate.usedPercent.isFinite, (0...100).contains(rate.usedPercent), rate.resetsAt > now else { return [] }
        let remaining = Int((100 - rate.usedPercent).rounded())
        let day = String(calendar.startOfDay(for: now).timeIntervalSince1970)
        var reminders: [QuotaNotification] = []
        if rate.resetsAt.timeIntervalSince(now) <= 1_800 {
            reminders.append(QuotaNotification(
                identifier: "codexMeter.notified.reset." + scope.id + "." + String(Int(rate.resetsAt.timeIntervalSince1970)),
                title: "Codex 额度即将重置", body: "7 天额度将在 30 分钟内重置。"))
        }
        if let velocity, velocity.percentPerHour.isFinite, velocity.percentPerHour > 0,
           (100 - rate.usedPercent) / velocity.percentPerHour < rate.resetsAt.timeIntervalSince(now) / 3_600 {
            reminders.append(QuotaNotification(
                identifier: "codexMeter.notified.exhaustion." + scope.id + "." + day,
                title: "Codex 额度可能提前耗尽",
                body: "按近 " + velocity.description + " 小时额度变化速度，预计将在重置前耗尽。"))
        }
        let threshold = defaults.object(forKey: "codexMeter.lowRateThreshold") as? Int ?? 20
        if remaining <= threshold {
            let level = remaining <= 10 ? "critical" : "low"
            reminders.append(QuotaNotification(
                identifier: "codexMeter.notified." + scope.id + "." + day + "." + level,
                title: "Codex 7 天额度偏低",
                body: "当前剩余 \(remaining)% ，约 \(UsageFormatters.countdown(to: rate.resetsAt, now: now)) 后重置。"))
        }
        return reminders
    }
}
