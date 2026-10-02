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
    private(set) var processedFiles = 0
    private(set) var totalFiles = 0
    private var hasCompleteSnapshot = false

    var loadingMessage: String {
        totalFiles == 0 ? "正在查找用量文件…" : "正在读取用量：\(processedFiles) / \(totalFiles) 个文件"
    }
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
        processedFiles = 0
        totalFiles = 0
        let previous = snapshot
        let showsPartialResults = !hasCompleteSnapshot
        defer { isRefreshing = false }

        do {
            var loaded = try await reader.load(codexHome: folderAccess.selectedURL, force: force) { [weak self] partial, completed, total in
                await self?.receiveProgress(partial, completed: completed, total: total, showPartial: showsPartialResults)
            }
            hasCompleteSnapshot = true
            processedFiles = loaded.fileCount
            QuotaRateCache.restoreMissing(into: &loaded)
            if snapshot != loaded { snapshot = loaded }
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
                updatedAt: .now,
                sampledAt: snapshot.lastUpdated,
                rateResetsAt: snapshot.sevenDayRate?.resetsAt,
                sourceIncomplete: snapshot.readWarning != nil
            )
            do {
                if try WidgetUsageCache.saveIfChanged(widgetUsage) {
                    WidgetCenter.shared.reloadTimelines(ofKind: "CodexMeterWidgetV4")
                }
                errorMessage = snapshot.readWarning
            } catch {
                errorMessage = [snapshot.readWarning, "小组件缓存写入失败：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
            }
        } catch {
            snapshot = previous
            errorMessage = "读取失败，已保留上次成功结果：\(error.localizedDescription)"
        }
    }

    private func receiveProgress(_ partial: UsageSnapshot, completed: Int, total: Int, showPartial: Bool) {
        processedFiles = completed
        totalFiles = total
        if showPartial, completed > 0 {
            var partial = partial
            QuotaRateCache.restoreMissing(into: &partial)
            snapshot = partial
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
    // v1 could persist a different model bucket as the main quota after a
    // reset. Start a clean cache so that bad pre-fix values cannot reappear.
    static let key = "codexMeter.quotaRateCache.v2"

    static func save(_ snapshot: UsageSnapshot, defaults: UserDefaults = .standard, now: Date = .now) {
        var payload = load(defaults: defaults)
        if let rate = snapshot.mainMenuRate, rate.resetsAt > now {
            payload.main = CachedQuotaRate(rate, sampledAt: snapshot.lastUpdated ?? now)
        }
        if let rate = snapshot.sparkRate, rate.resetsAt > now {
            payload.spark = CachedQuotaRate(rate, sampledAt: snapshot.lastUpdated ?? now)
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        if defaults.data(forKey: key) != data { defaults.set(data, forKey: key) }
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
