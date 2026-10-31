import Foundation

enum DeepSeekBalanceError: Error, LocalizedError, Equatable, Sendable {
    case invalidKey, keychain(Int32), unauthorized, rejected(Int), unavailable, invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidKey: "请输入有效的 DeepSeek API Key。"
        case .keychain(let status): "无法访问 DeepSeek 本机钥匙串（\(status)），请重试。"
        case .unauthorized: "DeepSeek 密钥无效或已过期，请在设置中重新配置。"
        case .rejected(429): "DeepSeek 查询过于频繁，请稍后重试。"
        case .rejected(let status): "DeepSeek 余额查询失败（HTTP \(status)），请稍后重试。"
        case .unavailable: "暂时无法连接 DeepSeek，请检查网络后重试。"
        case .invalidResponse: "DeepSeek 余额响应无法识别，未采用本次数据。"
        }
    }

    static func safe(_ error: Error) -> Self {
        if let error = error as? Self { return error }
        if case .keychain(let status) = error as? APIBillingError { return .keychain(status) }
        if case .invalidKey = error as? APIBillingError { return .invalidKey }
        return .unavailable
    }
}

struct DeepSeekBalance: Equatable, Sendable, Identifiable {
    let currency: String
    let total: Decimal
    let granted: Decimal
    let toppedUp: Decimal
    var id: String { currency }
    var currencyTitle: String { currency == "CNY" ? "人民币 · CNY" : "美元 · USD" }
}

struct DeepSeekBalanceSnapshot: Equatable, Sendable {
    let isAvailable: Bool
    let balances: [DeepSeekBalance]
    let checkedAt: Date
}
