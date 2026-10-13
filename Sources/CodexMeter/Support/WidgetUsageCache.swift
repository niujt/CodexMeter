import Foundation

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
    var remaining: Int? { currentPercent.map { Int((100 - $0).rounded()) } }
    var lastRemaining: Int? { lastPercent.map { Int((100 - $0).rounded()) } }
    var description: String {
        let time = hasValidTime ? "采样于 \(sampledAt!.formatted(.dateTime.year().month().day().hour().minute().second()))" : "采样时间未知"
        return "\(isStale ? "旧采样" : "本地采样") · \(time) · 非实时"
    }
    static func deadlines(sampledAt: Date?, resetsAt: Date?, now: Date = .now) -> [Date] {
        [sampledAt?.addingTimeInterval(lifetime), resetsAt].compactMap { $0 }.filter { $0 > now }.sorted()
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

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > 30 * 60
    }

    func currentRatePercent(at now: Date) -> Double? {
        quotaSample(at: now).currentPercent
    }

    func quotaSample(at now: Date) -> QuotaSampleState {
        QuotaSampleState(percent: ratePercent, sampledAt: sampledAt, resetsAt: rateResetsAt, now: now)
    }
}

enum WidgetUsageCache {
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
    }
}
