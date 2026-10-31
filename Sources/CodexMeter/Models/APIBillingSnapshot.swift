import Foundation

enum APIBillingError: Error, LocalizedError, Equatable, Sendable {
    case invalidKey, keychain(Int32), unauthorized, permission(String), rejected(Int)
    case unavailable, invalidResponse, incompletePages

    var errorDescription: String? {
        switch self {
        case .invalidKey: "请输入有效的 OpenAI Admin API Key。"
        case .keychain(let status): "无法访问本机钥匙串（\(status)），请重试。"
        case .unauthorized: "密钥无效或已过期，请在设置中重新导入。"
        case .permission(let scope): "密钥缺少读取权限：\(scope)。请检查组织角色及 Admin API Key。"
        case .rejected(let status): "官方接口返回 HTTP \(status)，请稍后重试。"
        case .unavailable: "暂时无法连接 OpenAI API，请检查网络后重试。"
        case .invalidResponse: "官方接口响应无法识别，未采用本次数据。"
        case .incompletePages: "分页数据未读取完整，未采用本次汇总。"
        }
    }
}

enum APIBillingResult<Value: Sendable>: Sendable {
    case available(Value)
    case unavailable(APIBillingError)

    var value: Value? { if case .available(let value) = self { value } else { nil } }
    var error: APIBillingError? { if case .unavailable(let error) = self { error } else { nil } }
}

struct APICosts: Equatable, Sendable {
    var amounts: [String: Decimal] = [:]
    // Empty results mean no recorded costs; unknown currencies must not become USD zero.
    var usd: Decimal? { amounts.isEmpty ? 0 : (amounts.keys.allSatisfy { $0 == "usd" } ? amounts["usd"] : nil) }
}

struct APIUsageTotals: Equatable, Sendable {
    var input: Int64 = 0
    var output: Int64 = 0
    var cachedInput: Int64 = 0
    var requests: Int64 = 0
}

enum APISpendLimitState: Equatable, Sendable {
    case notConfigured
    case configured(amount: Decimal, enforcing: Bool)
}

struct APIBillingSnapshot: Sendable {
    let periodStart: Date
    let checkedAt: Date
    let costs: APIBillingResult<APICosts>
    let usage: APIBillingResult<APIUsageTotals>
    let spendLimit: APIBillingResult<APISpendLimitState>

    var warnings: [String] {
        [("费用", costs.error), ("Token 用量", usage.error), ("消费上限", spendLimit.error)]
            .compactMap { label, error in error.map { "\(label)：\($0.localizedDescription)" } }
    }

    var hasData: Bool { costs.value != nil || usage.value != nil || spendLimit.value != nil }

    /// An estimate against a configured budget, never a prepaid credit balance.
    var estimatedBudgetRemaining: Decimal? {
        guard case .configured(let amount, _) = spendLimit.value, let spent = costs.value?.usd else { return nil }
        return max(0, amount - spent)
    }

    static func monthStart(at date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateInterval(of: .month, for: date)!.start
    }

    // Daily Costs buckets may omit today's bucket when end_time falls inside it.
    // Request through the next UTC midnight so today's recorded spend is included.
    static func queryEnd(at date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.dateInterval(of: .day, for: date)!.end
    }
}
