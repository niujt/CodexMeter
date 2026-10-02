import Foundation

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

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(updatedAt) > 30 * 60
    }

    func currentRatePercent(at now: Date) -> Double? {
        guard let rateResetsAt, rateResetsAt > now else { return nil }
        return ratePercent
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
    }
}
