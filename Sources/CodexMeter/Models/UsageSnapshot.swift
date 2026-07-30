import Foundation

struct TokenUsage: Sendable, Equatable {
    var input = 0
    var cachedInput = 0
    var output = 0
    var reasoningOutput = 0
    var total = 0

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            input: lhs.input + rhs.input,
            cachedInput: lhs.cachedInput + rhs.cachedInput,
            output: lhs.output + rhs.output,
            reasoningOutput: lhs.reasoningOutput + rhs.reasoningOutput,
            total: lhs.total + rhs.total
        )
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        Self(
            input: max(0, lhs.input - rhs.input),
            cachedInput: max(0, lhs.cachedInput - rhs.cachedInput),
            output: max(0, lhs.output - rhs.output),
            reasoningOutput: max(0, lhs.reasoningOutput - rhs.reasoningOutput),
            total: max(0, lhs.total - rhs.total)
        )
    }
}

struct RateWindow: Sendable, Equatable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
}

struct ProjectUsage: Sendable, Equatable {
    let name: String
    let path: String
    let tokens: Int
    let sessions: Int
    let lastActive: Date?

    init(path: String, tokens: Int, sessions: Int = 0, lastActive: Date? = nil) {
        self.path = path
        self.name = path.isEmpty ? "未归属路径" : URL(fileURLWithPath: path).lastPathComponent
        self.tokens = tokens
        self.sessions = sessions
        self.lastActive = lastActive
    }
}
struct ModelUsage: Sendable, Equatable {
    let name: String
    let tokens: Int
    let requests: Int
    /// User prompt to final assistant reply, not network/API latency.
    let averageTurnSeconds: Double?
}
struct DailyUsage: Sendable, Equatable { let date: Date; let tokens: Int }
struct UsageRecord: Sendable, Equatable { let date: Date; let project: String; let model: String; let tokens: Int }
/// A locally observed seven-day quota window. It contains no conversation content.
struct RateTimelineEvent: Sendable, Equatable {
    let date: Date
    let usedPercent: Double
    let resetsAt: Date
    let limitID: String?
}

struct UsageSnapshot: Sendable, Equatable {
    var allProjects: [ProjectUsage] = []
    var topProjects: [ProjectUsage] = []
    var todayProjects: [ProjectUsage] = []
    var monthProjects: [ProjectUsage] = []
    var topModels: [ModelUsage] = []
    var panelModels: [ModelUsage] = []
    var dailyUsage: [DailyUsage] = []
    var recentRecords: [UsageRecord] = []
    var rateTimeline: [RateTimelineEvent] = []
    var today = TokenUsage()
    var lastSevenDays = TokenUsage()
    var thisMonth = TokenUsage()
    var allTime = TokenUsage()
    var primaryRate: RateWindow?
    var secondaryRate: RateWindow?
    var mainMenuRate: RateWindow?
    var sparkRate: RateWindow?
    var selectedRateLimitID: String?
    var currentContextUsed = 0
    var contextWindow = 0
    var lastUpdated: Date?
    var sessionCount = 0
    var fileCount = 0
    var dataPath = ""
    var dataDirectoryExists = false

    static let empty = Self()
}
