import Foundation

struct WidgetUsageData: Codable, Sendable {
    let todayTokens: Int
    let weekTokens: Int
    let monthTokens: Int
    let contextTokens: Int
    let contextLimit: Int
    let ratePercent: Double?
    let rateWindowMinutes: Int?
    let updatedAt: Date

}

enum WidgetUsageCache {
    static func save(_ usage: WidgetUsageData) {
        guard let url = cacheURL(),
              let data = try? JSONEncoder().encode(usage) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> WidgetUsageData? {
        guard let url = cacheURL(),
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
}
