import Foundation
import Observation
import WidgetKit

extension Notification.Name {
    static let codexHealthUsageDidRefresh = Notification.Name("codexHealthUsageDidRefresh")
}

@MainActor
@Observable
final class UsageStore {
    static let shared = UsageStore()
    private(set) var snapshot = UsageSnapshot.empty
    private(set) var context: CodexDataContext?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private(set) var processedFiles = 0
    private(set) var totalFiles = 0
    private(set) var readFiles = 0
    private(set) var reusedFiles = 0
    private var hasCompleteSnapshot = false
    private var lastSuccessfulRefresh: Date?
    @ObservationIgnored private let reader: CodexUsageReader
    @ObservationIgnored private let folderAccess: CodexFolderAccess
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let effectsEnabled: Bool
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let monitor = CodexAccountMonitor()
    @ObservationIgnored private var loadTask: Task<UsageSnapshot, Error>?
    private var generation = UUID()

    init(reader: CodexUsageReader = CodexUsageReader(cacheDirectory: CodexUsageReader.defaultCacheDirectory()),
         folderAccess: CodexFolderAccess = CodexFolderAccess(), defaults: UserDefaults = .standard,
         effectsEnabled: Bool = true, clock: @escaping () -> Date = { .now }) {
        self.reader = reader
        self.folderAccess = folderAccess
        self.defaults = defaults
        self.effectsEnabled = effectsEnabled
        self.clock = clock
    }

    var loadingMessage: String {
        totalFiles == 0 ? "正在查找用量文件…" : "检查文件：\(processedFiles) / \(totalFiles) · 实际读取 \(readFiles) 个 · 复用缓存 \(reusedFiles) 个"
    }
    var selectedCodexPath: String {
        if folderAccess.restoreError != nil { return "" }
        return (folderAccess.selectedURL ?? CodexDataSource.defaultRoot()).path
    }
    var dataSourceDescription: String { context?.source.home == nil ? "会话目录 · 本地 Token 统计" : "Codex 主目录 · 本地 Token 统计" }
    var accountStatus: String {
        if let error = folderAccess.restoreError { return error }
        guard let context else { return "等待检查登录状态" }
        if context.source.home == nil { return "仅会话目录，账户功能不可用" }
        return context.accountIdentity == nil ? "未识别 ChatGPT 账户，额度与预测暂停" : "已识别登录；额度采用登录边界后的本地采样"
    }
    var quotaWaitingMessage: String {
        if folderAccess.restoreError != nil { return "请重新选择数据目录" }
        guard let context else { return "等待检查登录状态" }
        if context.source.home == nil { return "额度需选择 Codex 主目录" }
        return context.accountIdentity == nil ? "额度需登录 ChatGPT 账户" : "等待当前账户新采样"
    }
    var measuredVelocity: RateVelocity? {
        guard let scope = context?.quotaScope, let rate = snapshot.sevenDayRate else { return nil }
        return RateHistory.weightedVelocity(scope: scope, resetsAt: rate.resetsAt, defaults: defaults, now: clock())
    }

    /// Invalidate before throttling: a login or directory change must not keep old quotas visible.
    @discardableResult
    func synchronizeContext() -> Bool {
        guard folderAccess.restoreError == nil else {
            loadTask?.cancel()
            generation = UUID()
            snapshot = .empty
            context = nil
            isRefreshing = false
            errorMessage = folderAccess.restoreError
            if effectsEnabled { PermissionAttentionService.shared.configure(paths: nil); publishWidget() }
            return false
        }
        let source = CodexDataSource(root: folderAccess.selectedURL ?? CodexDataSource.defaultRoot())
        let next = CodexDataContext.resolve(source: source, defaults: defaults, now: clock(),
            initialObservation: context?.source.id != source.id)
        guard next != context else { return false }
        loadTask?.cancel()
        generation = UUID()
        context = next
        snapshot = .empty
        snapshot.dataPath = source.root.path
        QuotaRateCache.restore(into: &snapshot, scope: next.quotaScope, defaults: defaults, now: clock())
        hasCompleteSnapshot = false
        lastSuccessfulRefresh = nil
        isRefreshing = false
        processedFiles = 0; totalFiles = 0; readFiles = 0; reusedFiles = 0
        errorMessage = nil
        if effectsEnabled {
            PermissionAttentionService.shared.configure(paths: source.permissionPaths())
            watchAccount()
            publishWidget()
            NotificationCenter.default.post(name: .codexHealthUsageDidRefresh, object: self)
        }
        return true
    }

    private func watchAccount() {
        monitor.watch(home: context?.source.home) { [weak self] in
            guard let self else { return }
            let changed = self.synchronizeContext()
            if !changed { self.watchAccount() } // Reopen after atomic replacement or creation.
            if changed { Task { await self.refresh() } }
        }
    }

    func refreshIfNeeded() async {
        synchronizeContext()
        if let lastSuccessfulRefresh, clock().timeIntervalSince(lastSuccessfulRefresh) >= 0,
           clock().timeIntervalSince(lastSuccessfulRefresh) < RefreshPolicy.interval(defaults: defaults) { return }
        await refresh()
    }

    func refresh(force: Bool = false) async {
        synchronizeContext()
        guard let context, !isRefreshing else { return }
        let request = generation
        let now = clock()
        isRefreshing = true
        processedFiles = 0; totalFiles = 0; readFiles = 0; reusedFiles = 0
        let previous = snapshot
        let showsPartialResults = !hasCompleteSnapshot
        let reader = reader
        let partialProgress: (@Sendable (UsageSnapshot, Int, Int) async -> Void)?
        if showsPartialResults {
            partialProgress = { [weak self] partial, completed, _ in
                await self?.receivePartialSnapshot(partial, completed: completed, request: request)
            }
        } else {
            partialProgress = nil
        }
        let task = Task { [weak self] in
            try await reader.loadWithActivity(now: now, codexHome: context.source.root, force: force,
                quotaSince: context.quotaScope?.since ?? .distantFuture,
                onFileProgress: { [weak self] completed, total in
                    await self?.receiveFileProgress(completed: completed, total: total, request: request)
                }, onActivity: { [weak self] read, reused in
                    await self?.receiveActivity(read: read, reused: reused, request: request)
                }, onProgress: partialProgress)
        }
        loadTask = task
        defer { if generation == request { isRefreshing = false; loadTask = nil } }
        do {
            var loaded = try await task.value
            guard request == generation else { return }
            if synchronizeContext() { await refresh(force: force); return }
            guard request == generation else { return }
            hasCompleteSnapshot = true
            lastSuccessfulRefresh = clock()
            processedFiles = loaded.fileCount
            QuotaRateCache.restoreMissing(into: &loaded, scope: context.quotaScope, defaults: defaults, now: now)
            snapshot = loaded
            QuotaRateCache.save(loaded, scope: context.quotaScope, defaults: defaults, now: now)
            if let scope = context.quotaScope, let rate = snapshot.sevenDayRate {
                if !snapshot.mainRateIsCached, let sampledAt = snapshot.mainRateSampledAt {
                    RateHistory.append(rate, sampledAt: sampledAt, scope: scope, defaults: defaults, now: now)
                }
                if effectsEnabled { UsageNotifier.evaluate(rate, scope: scope, velocity: measuredVelocity) }
            }
            let cacheWarning = await reader.cacheWarning
            guard request == generation else { return }
            errorMessage = [snapshot.readWarning, cacheWarning].compactMap { $0 }.joined(separator: "\n")
            if errorMessage?.isEmpty == true { errorMessage = nil }
            if effectsEnabled {
                publishWidget()
                if snapshot != previous { NotificationCenter.default.post(name: .codexHealthUsageDidRefresh, object: self) }
            }
        } catch {
            guard request == generation else { return }
            if synchronizeContext() { await refresh(force: force); return }
            guard request == generation, !(error is CancellationError) else { return }
            snapshot = previous
            errorMessage = "读取失败，已保留当前目录的上次结果：\(error.localizedDescription)"
        }
    }

    private func publishWidget() {
        let usage = WidgetUsageData(todayTokens: snapshot.today.total, weekTokens: snapshot.lastSevenDays.total,
            monthTokens: snapshot.thisMonth.total, contextTokens: snapshot.currentContextUsed,
            contextLimit: snapshot.contextWindow, ratePercent: snapshot.sevenDayRate?.usedPercent,
            rateWindowMinutes: snapshot.sevenDayRate?.windowMinutes, updatedAt: clock(),
            sampledAt: snapshot.lastUpdated, rateResetsAt: snapshot.sevenDayRate?.resetsAt,
            sourceIncomplete: !hasCompleteSnapshot || snapshot.readWarning != nil, contextID: context?.id)
        do {
            if try WidgetUsageCache.saveIfChanged(usage) { WidgetCenter.shared.reloadTimelines(ofKind: "CodexMeterWidgetV4") }
        } catch { errorMessage = [errorMessage, "小组件缓存写入失败：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "\n") }
    }

    private func receiveActivity(read: Int, reused: Int, request: UUID) {
        guard request == generation else { return }
        readFiles = read; reusedFiles = reused
    }
    private func receiveFileProgress(completed: Int, total: Int, request: UUID) {
        guard request == generation else { return }
        processedFiles = completed; totalFiles = total
    }
    private func receivePartialSnapshot(_ partial: UsageSnapshot, completed: Int, request: UUID) {
        guard request == generation else { return }
        if completed > 0 {
            var partial = partial
            QuotaRateCache.restoreMissing(into: &partial, scope: context?.quotaScope, defaults: defaults, now: clock())
            snapshot = partial
        }
    }

    func chooseCodexFolder() {
        do {
            guard try folderAccess.chooseFolder() != nil else { return }
            synchronizeContext()
            Task { await refresh(force: true) }
        } catch { errorMessage = "无法保存目录授权：\(error.localizedDescription)" }
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
    // Legacy global quota values have no directory/account provenance and are ignored.
    static func key(for scope: QuotaScope) -> String { "codexMeter.quotaRateCache.v3." + scope.id }

    static func save(_ snapshot: UsageSnapshot, scope: QuotaScope? = nil, defaults: UserDefaults = .standard, now: Date = .now) {
        guard let scope else { return }
        let key = key(for: scope)
        let existing = load(scope: scope, defaults: defaults)
        var payload = existing
        if let rate = snapshot.mainMenuRate, !snapshot.mainRateIsCached, rate.resetsAt > now,
           let sampledAt = snapshot.mainRateSampledAt, sampledAt >= scope.since, sampledAt <= now {
            payload.main = CachedQuotaRate(rate, sampledAt: sampledAt)
        }
        if let rate = snapshot.sparkRate, !snapshot.sparkRateIsCached, rate.resetsAt > now,
           let sampledAt = snapshot.sparkRateSampledAt, sampledAt >= scope.since, sampledAt <= now {
            payload.spark = CachedQuotaRate(rate, sampledAt: sampledAt)
        }
        guard payload != existing, let data = try? JSONEncoder().encode(payload) else { return }
        if defaults.data(forKey: key) != data { defaults.set(data, forKey: key) }
    }

    static func restore(into snapshot: inout UsageSnapshot, scope: QuotaScope? = nil, defaults: UserDefaults = .standard, now: Date = .now) {
        guard let scope else { return }
        let payload = load(scope: scope, defaults: defaults)
        if let main = valid(payload.main, scope: scope, now: now) {
            snapshot.mainMenuRate = main.rateWindow
            snapshot.mainRateIsCached = true
            snapshot.mainRateSampledAt = main.sampledAt
            snapshot.lastUpdated = main.sampledAt
        }
        if let spark = valid(payload.spark, scope: scope, now: now) {
            snapshot.sparkRate = spark.rateWindow
            snapshot.sparkRateIsCached = true
            snapshot.sparkRateSampledAt = spark.sampledAt
        }
    }

    static func restoreMissing(into snapshot: inout UsageSnapshot, scope: QuotaScope? = nil, defaults: UserDefaults = .standard, now: Date = .now) {
        guard let scope else { return }
        let payload = load(scope: scope, defaults: defaults)
        if snapshot.mainMenuRate == nil, let main = valid(payload.main, scope: scope, now: now) {
            snapshot.mainMenuRate = main.rateWindow
            snapshot.mainRateIsCached = true
            snapshot.mainRateSampledAt = main.sampledAt
        }
        if snapshot.sparkRate == nil, let spark = valid(payload.spark, scope: scope, now: now) {
            snapshot.sparkRate = spark.rateWindow
            snapshot.sparkRateIsCached = true
            snapshot.sparkRateSampledAt = spark.sampledAt
        }
    }

    private static func load(scope: QuotaScope, defaults: UserDefaults) -> QuotaRateCachePayload {
        guard let data = defaults.data(forKey: key(for: scope)),
              let payload = try? JSONDecoder().decode(QuotaRateCachePayload.self, from: data) else {
            return QuotaRateCachePayload()
        }
        return payload
    }

    private static func valid(_ cached: CachedQuotaRate?, scope: QuotaScope, now: Date) -> CachedQuotaRate? {
        guard let cached, cached.resetsAt > now, cached.sampledAt >= scope.since, cached.sampledAt <= now,
              cached.usedPercent.isFinite, (0...100).contains(cached.usedPercent) else { return nil }
        return cached
    }
}
