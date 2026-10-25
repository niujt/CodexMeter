import Foundation
import Testing
@testable import CodexMeter

@MainActor
struct UsageNotifierTests {
    private enum Failure: Error { case unavailable }
    @MainActor private final class State {
        var granted = false
        var fails = true
        var submissions = 0
        var resume: CheckedContinuation<Void, Never>?
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "CodexMeterTests.Notifications.\(UUID().uuidString)")!
    }

    private var reminder: QuotaNotification {
        QuotaNotification(identifier: "synthetic-reminder", title: "Synthetic", body: "No real notification")
    }

    @Test func denialDoesNotConsumeReminderAndLaterAuthorizationCanRetry() async {
        let defaults = defaults()
        let state = State()
        let delivery = QuotaNotificationDelivery(defaults: defaults, authorize: { state.granted }, submit: { _ in
            state.submissions += 1
        })
        await delivery.send(reminder, deduplicate: true)
        #expect(!defaults.bool(forKey: reminder.identifier))
        #expect(state.submissions == 0)
        state.granted = true
        await delivery.send(reminder, deduplicate: true)
        #expect(state.submissions == 1)
        #expect(defaults.bool(forKey: reminder.identifier))
        await delivery.send(reminder, deduplicate: true)
        #expect(state.submissions == 1)
    }

    @Test func failedSubmissionRemainsRetryableForEveryReminderKind() async {
        let defaults = defaults()
        let now = Date(timeIntervalSince1970: 1_792_900_000)
        let rate = RateWindow(usedPercent: 95, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(600))
        let reminders = UsageNotifier.reminders(rate, scope: .init(id: "synthetic", since: now.addingTimeInterval(-3_600)),
            velocity: .init(percentPerHour: 100, windowsUsed: [1]), defaults: defaults, now: now)
        #expect(reminders.count == 3)
        let state = State()
        let delivery = QuotaNotificationDelivery(defaults: defaults, authorize: { true }, submit: { _ in
            state.submissions += 1
            if state.fails { throw Failure.unavailable }
        })
        for reminder in reminders { await delivery.send(reminder, deduplicate: true) }
        #expect(reminders.allSatisfy { !defaults.bool(forKey: $0.identifier) })
        state.fails = false
        for reminder in reminders { await delivery.send(reminder, deduplicate: true) }
        #expect(reminders.allSatisfy { defaults.bool(forKey: $0.identifier) })
        for reminder in reminders { await delivery.send(reminder, deduplicate: true) }
        #expect(state.submissions == 6)
    }

    @Test func authorizationFailureRemainsRetryable() async {
        let defaults = defaults()
        let state = State()
        let delivery = QuotaNotificationDelivery(defaults: defaults, authorize: {
            if state.fails { throw Failure.unavailable }
            return true
        }, submit: { _ in state.submissions += 1 })
        await delivery.send(reminder, deduplicate: true)
        #expect(!defaults.bool(forKey: reminder.identifier))
        state.fails = false
        await delivery.send(reminder, deduplicate: true)
        #expect(state.submissions == 1)
    }

    @Test func disabledDeduplicationAllowsLaterSuccessfulReminders() async {
        let defaults = defaults()
        let state = State()
        let delivery = QuotaNotificationDelivery(defaults: defaults, authorize: { true }, submit: { _ in state.submissions += 1 })
        defaults.set(true, forKey: reminder.identifier)
        await delivery.send(reminder, deduplicate: false)
        await delivery.send(reminder, deduplicate: false)
        #expect(state.submissions == 2)
    }

    @Test func overlappingRefreshesShareOneInFlightSubmission() async {
        let defaults = defaults()
        let state = State()
        let delivery = QuotaNotificationDelivery(defaults: defaults, authorize: { true }, submit: { _ in
            state.submissions += 1
            await withCheckedContinuation { state.resume = $0 }
        })
        let first = Task { await delivery.send(reminder, deduplicate: true) }
        while state.resume == nil { await Task.yield() }
        #expect(!defaults.bool(forKey: reminder.identifier))
        await delivery.send(reminder, deduplicate: true)
        #expect(state.submissions == 1)
        state.resume?.resume()
        await first.value
        #expect(defaults.bool(forKey: reminder.identifier))
    }

    @Test func reminderKeysKeepAccountDayAndResetCycleBoundaries() {
        let defaults = defaults()
        let now = Date(timeIntervalSince1970: 1_792_900_000)
        let scope = QuotaScope(id: "synthetic-account-A", since: now.addingTimeInterval(-3_600))
        let rate = RateWindow(usedPercent: 95, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(600))
        let notices = UsageNotifier.reminders(rate, scope: scope, velocity: nil, defaults: defaults, now: now)
        let other = UsageNotifier.reminders(rate, scope: .init(id: "synthetic-account-B", since: scope.since),
            velocity: nil, defaults: defaults, now: now)
        #expect(notices.count == 2)
        #expect(Set(notices.map(\.identifier)).isDisjoint(with: other.map(\.identifier)))
        let sameDayNewCycle = RateWindow(usedPercent: 95, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(900))
        let nextCycle = UsageNotifier.reminders(sameDayNewCycle, scope: scope, velocity: nil, defaults: defaults, now: now)
        #expect(notices.first?.identifier != nextCycle.first?.identifier) // Reset reminder follows the cycle.
        #expect(notices.last?.identifier == nextCycle.last?.identifier) // Low quota is still deduplicated for the day.
        let longCycle = RateWindow(usedPercent: 95, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3 * 86_400))
        let today = UsageNotifier.reminders(longCycle, scope: scope, velocity: nil, defaults: defaults, now: now)
        let tomorrow = UsageNotifier.reminders(longCycle, scope: scope, velocity: nil, defaults: defaults,
                                               now: now.addingTimeInterval(86_400))
        #expect(today.count == 1 && tomorrow.count == 1)
        #expect(today.first?.identifier != tomorrow.first?.identifier)
        let expired = RateWindow(usedPercent: 95, windowMinutes: 10_080, resetsAt: now)
        #expect(UsageNotifier.reminders(expired, scope: scope, velocity: nil, defaults: defaults, now: now).isEmpty)
    }
}
