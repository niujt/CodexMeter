import Foundation

enum QuotaRemainingTint: Equatable, Sendable {
    case unknown, green, yellow, red
}

/// Local observations are never a live account query. Checking files does not renew a sample.
struct QuotaSampleState {
    static let lifetime: TimeInterval = 15 * 60
    let percent: Double?
    let sampledAt: Date?
    let resetsAt: Date?
    let now: Date

    var lastPercent: Double? {
        guard let percent, percent.isFinite, (0...100).contains(percent),
              let resetsAt, resetsAt > now else { return nil }
        return percent
    }
    var hasValidTime: Bool { sampledAt.map { $0 <= now } ?? false }
    var isStale: Bool { sampledAt.map { $0 <= now && now.timeIntervalSince($0) >= Self.lifetime } ?? false }
    var currentPercent: Double? { hasValidTime && !isStale ? lastPercent : nil }
    /// Keep a valid observation visible until its quota cycle ends, even when it is no longer fresh.
    var recordedPercent: Double? { hasValidTime ? lastPercent : nil }
    var remaining: Int? { currentPercent.map { Int((100 - $0).rounded()) } }
    var recordedRemaining: Int? { recordedPercent.map { Int((100 - $0).rounded()) } }
    var lastRemaining: Int? { lastPercent.map { Int((100 - $0).rounded()) } }
    var remainingTint: QuotaRemainingTint {
        guard let percent = recordedPercent else { return .unknown }
        let remaining = 100 - percent
        if remaining > 50 { return .green }
        return remaining >= 20 ? .yellow : .red
    }
    var description: String {
        let time = hasValidTime ? "采样于 \(sampledAt!.formatted(.dateTime.year().month().day().hour().minute().second()))" : "采样时间未知"
        return "\(isStale ? "旧采样" : "额度采样") · \(time) · 非实时"
    }
    static func deadlines(sampledAt: Date?, resetsAt: Date?, now: Date = .now) -> [Date] {
        [sampledAt?.addingTimeInterval(lifetime), resetsAt].compactMap { $0 }.filter { $0 > now }.sorted()
    }
}

enum QuotaRunway: Equatable {
    case waiting, insufficient, depleted, estimated(hours: Double, beforeReset: Bool)

    var summary: String {
        switch self {
        case .waiting: "等待新额度采样"
        case .insufficient: "样本不足，暂不预测"
        case .depleted: "本周期额度已用完"
        case .estimated(_, true): "可能在重置前用完"
        case .estimated(_, false): "预计可撑到重置"
        }
    }

    var hours: Double? {
        switch self {
        case .estimated(let hours, _): hours
        case .depleted: 0
        default: nil
        }
    }

    static func evaluate(sample: QuotaSampleState, windowMinutes: Int?, measuredVelocity: Double?) -> Self {
        guard windowMinutes == 10_080, let used = sample.currentPercent, let reset = sample.resetsAt else {
            return .waiting
        }
        if used == 100 { return .depleted }
        guard let speed = velocity(usedPercent: used, windowMinutes: 10_080,
                                   resetsAt: reset, measured: measuredVelocity, now: sample.now) else {
            return .insufficient
        }
        let hours = (100 - used) / speed
        guard hours.isFinite else { return .insufficient }
        return .estimated(hours: hours, beforeReset: hours < reset.timeIntervalSince(sample.now) / 3_600)
    }

    static func velocity(usedPercent: Double, windowMinutes: Int, resetsAt: Date,
                         measured: Double?, now: Date) -> Double? {
        if let measured, measured.isFinite, measured > 0 { return measured }
        guard resetsAt > now, usedPercent.isFinite, usedPercent > 0 else { return nil }
        let elapsed = Double(windowMinutes) / 60 - resetsAt.timeIntervalSince(now) / 3_600
        guard elapsed > 0 else { return nil }
        return usedPercent / max(0.1, elapsed)
    }
}

struct WidgetUsageData: Codable, Sendable, Equatable {
    let todayTokens: Int
    let weekTokens: Int
    let monthTokens: Int
    let contextTokens: Int
    let contextLimit: Int
    let ratePercent: Double?
    let rateWindowMinutes: Int?
    /// Last successful source check, distinct from the latest source event timestamp.
    let updatedAt: Date
    var sampledAt: Date? = nil
    var rateResetsAt: Date? = nil
    var sourceIncomplete: Bool? = nil
    var contextID: String? = nil
    var quotaVelocity: Double? = nil

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > 30 * 60
    }

    func currentRatePercent(at now: Date) -> Double? {
        quotaSample(at: now).currentPercent
    }

    func recordedRatePercent(at now: Date) -> Double? {
        quotaSample(at: now).recordedPercent
    }

    func quotaSample(at now: Date) -> QuotaSampleState {
        QuotaSampleState(percent: ratePercent, sampledAt: sampledAt, resetsAt: rateResetsAt, now: now)
    }

    func quotaRunway(at now: Date) -> QuotaRunway {
        QuotaRunway.evaluate(sample: quotaSample(at: now), windowMinutes: rateWindowMinutes,
                             measuredVelocity: quotaVelocity)
    }
}

enum WidgetUsageCache {
    static let kind = "CodexMeterWidgetV4"

    /// A normal publication only refreshes the timeline. Process recovery belongs
    /// to app launch, where an installation may actually have been replaced.
    static func publish(_ usage: WidgetUsageData, forceReload: Bool = false,
                        to destination: URL? = nil, reload: () -> Void) throws {
        let changed = try saveIfChanged(usage, to: destination)
        if changed || forceReload { reload() }
    }

    @discardableResult
    static func save(_ usage: WidgetUsageData, to destination: URL? = nil) throws -> Bool {
        guard let url = destination ?? cacheURL() else {
            throw CocoaError(.fileNoSuchFile)
        }
        try JSONEncoder().encode(usage).write(to: url, options: .atomic)
        return true
    }

    @discardableResult
    static func saveIfChanged(_ usage: WidgetUsageData, to destination: URL? = nil) throws -> Bool {
        if let existing = load(from: destination), sameDisplayedContent(existing, usage),
           usage.updatedAt >= existing.updatedAt,
           usage.updatedAt.timeIntervalSince(existing.updatedAt) < 15 * 60 {
            return false
        }
        return try save(usage, to: destination)
    }

    static func load(from source: URL? = nil) -> WidgetUsageData? {
        guard let url = source ?? cacheURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetUsageData.self, from: data)
    }

    private static func cacheURL() -> URL? {
        guard let groupID = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return nil
        }
        return directory.appendingPathComponent("codex-usage.json")
    }

    private static func sameDisplayedContent(_ lhs: WidgetUsageData, _ rhs: WidgetUsageData) -> Bool {
        lhs.todayTokens == rhs.todayTokens
            && lhs.weekTokens == rhs.weekTokens
            && lhs.monthTokens == rhs.monthTokens
            && lhs.contextTokens == rhs.contextTokens
            && lhs.contextLimit == rhs.contextLimit
            && lhs.ratePercent == rhs.ratePercent
            && lhs.rateWindowMinutes == rhs.rateWindowMinutes
            && lhs.sampledAt == rhs.sampledAt
            && lhs.rateResetsAt == rhs.rateResetsAt
            && lhs.sourceIncomplete == rhs.sourceIncomplete
            && lhs.contextID == rhs.contextID
            && lhs.quotaVelocity == rhs.quotaVelocity
    }
}

/// Future entries are only freshness/expiry transitions, never invented usage.
struct WidgetTimelineSchedule {
    let reloadAt: Date
    let dates: [Date]

    init(usage: WidgetUsageData?, now: Date) {
        let nextCheck = now.addingTimeInterval(usage == nil ? 300 : 1_800)
        let deadlines = [usage?.rateResetsAt, usage?.sampledAt?.addingTimeInterval(QuotaSampleState.lifetime),
                         usage?.updatedAt.addingTimeInterval(1_801)]
            .compactMap { $0 }.filter { $0 > now && $0 < nextCheck }
        reloadAt = nextCheck
        dates = [now] + Array(Set(deadlines + [nextCheck])).sorted()
    }
}
