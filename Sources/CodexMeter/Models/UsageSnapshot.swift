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
    /// Cached input tokens divided by all input tokens when a valid sample exists.
    let cacheHitRate: Double?
}
struct DailyUsage: Sendable, Equatable { let date: Date; let tokens: Int }
struct UsageRecord: Sendable, Equatable { let date: Date; let project: String; let model: String; let tokens: Int }
/// Output throughput over a completed local turn, including thinking/tools/waiting.
struct ReplySpeedSample: Sendable, Equatable {
    let completedAt: Date
    let outputTokens: Int
    let turnSeconds: Double
}

struct RecentReplySpeed: Equatable {
    static let windowSeconds: TimeInterval = 15 * 60
    let outputTokens: Int
    let turnSeconds: Double
    let sampleCount: Int

    var tokensPerSecond: Double { Double(outputTokens) / turnSeconds }

    static func summarize(_ samples: [ReplySpeedSample], now: Date = .now) -> Self? {
        let start = now.addingTimeInterval(-windowSeconds)
        let valid = samples.filter {
            $0.completedAt > start && $0.completedAt <= now
                && $0.outputTokens > 0 && $0.turnSeconds.isFinite
                && $0.turnSeconds > 0 && $0.turnSeconds <= 3_600
        }
        guard !valid.isEmpty else { return nil }
        return Self(outputTokens: valid.reduce(0) { $0 + $1.outputTokens },
                    turnSeconds: valid.reduce(0) { $0 + $1.turnSeconds }, sampleCount: valid.count)
    }
}
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
    var replySpeedSamples: [ReplySpeedSample] = []
    var rateTimeline: [RateTimelineEvent] = []
    var today = TokenUsage()
    var lastSevenDays = TokenUsage()
    var thisMonth = TokenUsage()
    var allTime = TokenUsage()
    var primaryRate: RateWindow?
    var secondaryRate: RateWindow?
    var mainMenuRate: RateWindow?
    var sparkRate: RateWindow?
    var mainRateIsCached = false
    var sparkRateIsCached = false
    var selectedRateLimitID: String?
    var currentContextUsed = 0
    var contextWindow = 0
    var lastUpdated: Date?
    var sessionCount = 0
    var readWarning: String?
    var fileCount = 0
    var dataPath = ""
    var dataDirectoryExists = false

    static let empty = Self()
}

/// Shared interpretation for the dashboard headline and forecast cards.
enum QuotaHealth: Equatable {
    case waiting, insufficient, critical, watch, healthy

    static func evaluate(rate: RateWindow?, percentPerHour: Double?, now: Date = .now) -> Self {
        guard let rate, rate.resetsAt > now else { return .waiting }
        let remaining = max(0, 100 - rate.usedPercent)
        if remaining < 20 { return .critical }
        guard let speed = percentPerHour, speed.isFinite, speed > 0 else { return .insufficient }
        if remaining / speed < rate.resetsAt.timeIntervalSince(now) / 3_600 || remaining < 50 { return .watch }
        return .healthy
    }

    static func velocity(rate: RateWindow?, measured: Double?, now: Date = .now) -> Double? {
        if let measured, measured.isFinite, measured > 0 { return measured }
        guard let rate, rate.resetsAt > now, rate.usedPercent > 0 else { return nil }
        let elapsed = Double(rate.windowMinutes) / 60 - rate.resetsAt.timeIntervalSince(now) / 3_600
        guard elapsed > 0 else { return nil }
        return rate.usedPercent / max(0.1, elapsed)
    }

    var title: String {
        switch self {
        case .waiting: "等待新周期数据"
        case .insufficient: "样本不足"
        case .critical: "额度紧张"
        case .watch: "需要关注"
        case .healthy: "额度状态健康"
        }
    }

    var detail: String {
        switch self {
        case .waiting: "获取新周期的额度采样后再评估。"
        case .insufficient: "暂时无法判断能否支撑到重置。"
        case .critical: "剩余额度不足 20%，请留意后续消耗。"
        case .watch: "额度余量偏低或预计在重置前耗尽。"
        case .healthy: "按当前估算，额度可支撑到重置。"
        }
    }
}
