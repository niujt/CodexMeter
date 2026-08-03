import Foundation
import Observation
import WidgetKit

extension Notification.Name {
    static let codexHealthUsageDidRefresh = Notification.Name("codexHealthUsageDidRefresh")
}

@MainActor
@Observable
final class UsageStore {
    private(set) var snapshot = UsageSnapshot.empty
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private let reader = CodexUsageReader()
    @ObservationIgnored private let folderAccess = CodexFolderAccess()

    init() {
        QuotaRateCache.restore(into: &snapshot)
    }

    var selectedCodexPath: String {
        folderAccess.selectedURL?.path ?? snapshot.dataPath
    }

    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            var loaded = try await reader.load(codexHome: folderAccess.selectedURL, force: force)
            QuotaRateCache.restoreMissing(into: &loaded)
            snapshot = loaded
            QuotaRateCache.save(snapshot)
            NotificationCenter.default.post(name: .codexHealthUsageDidRefresh, object: self)
            if let rate = snapshot.sevenDayRate { RateHistory.append(rate.usedPercent); UsageNotifier.evaluate(rate) }
            let widgetUsage = WidgetUsageData(
                todayTokens: snapshot.today.total,
                weekTokens: snapshot.lastSevenDays.total,
                monthTokens: snapshot.thisMonth.total,
                contextTokens: snapshot.currentContextUsed,
                contextLimit: snapshot.contextWindow,
                ratePercent: snapshot.sevenDayRate?.usedPercent,
                rateWindowMinutes: snapshot.sevenDayRate?.windowMinutes,
                updatedAt: .now
            )
            if WidgetUsageCache.saveIfChanged(widgetUsage) {
                WidgetCenter.shared.reloadAllTimelines()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseCodexFolder() {
        do {
            guard try folderAccess.chooseFolder() != nil else { return }
            Task { await refresh(force: true) }
        } catch {
            errorMessage = "无法保存目录授权：\(error.localizedDescription)"
        }
    }

    func requestCodexFolderIfNeeded() {
        guard folderAccess.selectedURL == nil else { return }
        chooseCodexFolder()
    }
}

struct CachedQuotaRate: Codable, Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
    let sampledAt: Date

    init(_ rate: RateWindow, sampledAt: Date) {
        usedPercent = rate.usedPercent
        windowMinutes = rate.windowMinutes
        resetsAt = rate.resetsAt
        self.sampledAt = sampledAt
    }

    var rateWindow: RateWindow {
        RateWindow(usedPercent: usedPercent, windowMinutes: windowMinutes, resetsAt: resetsAt)
    }
}

struct QuotaRateCachePayload: Codable, Equatable {
    var main: CachedQuotaRate?
    var spark: CachedQuotaRate?
}

enum QuotaRateCache {
    static let key = "codexMeter.quotaRateCache.v1"

    static func save(_ snapshot: UsageSnapshot, defaults: UserDefaults = .standard, now: Date = .now) {
        var payload = load(defaults: defaults)
        if let rate = snapshot.mainMenuRate, rate.resetsAt > now {
            payload.main = CachedQuotaRate(rate, sampledAt: snapshot.lastUpdated ?? now)
        }
        if let rate = snapshot.sparkRate, rate.resetsAt > now {
            payload.spark = CachedQuotaRate(rate, sampledAt: snapshot.lastUpdated ?? now)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: key)
    }

    static func restore(into snapshot: inout UsageSnapshot, defaults: UserDefaults = .standard, now: Date = .now) {
        let payload = load(defaults: defaults)
        if let main = valid(payload.main, now: now) {
            snapshot.mainMenuRate = main.rateWindow
            snapshot.mainRateIsCached = true
            snapshot.lastUpdated = main.sampledAt
        }
        if let spark = valid(payload.spark, now: now) {
            snapshot.sparkRate = spark.rateWindow
            snapshot.sparkRateIsCached = true
        }
    }

    static func restoreMissing(into snapshot: inout UsageSnapshot, defaults: UserDefaults = .standard, now: Date = .now) {
        let payload = load(defaults: defaults)
        if snapshot.mainMenuRate == nil, let main = valid(payload.main, now: now) {
            snapshot.mainMenuRate = main.rateWindow
            snapshot.mainRateIsCached = true
        }
        if snapshot.sparkRate == nil, let spark = valid(payload.spark, now: now) {
            snapshot.sparkRate = spark.rateWindow
            snapshot.sparkRateIsCached = true
        }
    }

    private static func load(defaults: UserDefaults) -> QuotaRateCachePayload {
        guard let data = defaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(QuotaRateCachePayload.self, from: data) else {
            return QuotaRateCachePayload()
        }
        return payload
    }

    private static func valid(_ cached: CachedQuotaRate?, now: Date) -> CachedQuotaRate? {
        guard let cached, cached.resetsAt > now else { return nil }
        return cached
    }
}
