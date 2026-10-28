import Foundation

struct LiveQuotaObservation: Sendable {
    let primary: RateWindow?
    let secondary: RateWindow?
    let sampledAt: Date

    func apply(to snapshot: inout UsageSnapshot, now: Date) {
        guard sampledAt <= now else { return }
        let weekly = [primary, secondary].compactMap { $0 }.first { $0.windowMinutes == 10_080 && $0.resetsAt > now }
        if let weekly, sampledAt >= (snapshot.mainRateSampledAt ?? .distantPast) {
            snapshot.mainMenuRate = weekly
            snapshot.mainRateSampledAt = sampledAt
            snapshot.mainRateIsCached = false
            snapshot.selectedRateLimitID = "codex"
        }
        if sampledAt >= (snapshot.primaryRateSampledAt ?? .distantPast) {
            snapshot.primaryRate = primary.flatMap { $0.resetsAt > now ? $0 : nil }
            snapshot.primaryRateSampledAt = snapshot.primaryRate == nil ? nil : sampledAt
            snapshot.secondaryRate = secondary.flatMap { $0.resetsAt > now ? $0 : nil }
        }
    }
}

enum LiveQuotaError: LocalizedError {
    case loginRequired, accountChanged, rejected(Int), invalidResponse, unavailable

    var errorDescription: String? {
        switch self {
        case .loginRequired: "额度查询需要有效的 Codex ChatGPT 登录。"
        case .accountChanged: "查询期间登录账户已变化，请重新刷新。"
        case .rejected(let status): "账户额度查询失败（HTTP \(status)），已保留上次采样。"
        case .invalidResponse: "账户额度响应无法识别，已保留上次采样。"
        case .unavailable: "暂时无法连接账户额度服务，已保留上次采样。"
        }
    }
}

private final class LiveQuotaSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Same read-only endpoint as openai/codex's backend-client; not a public API contract.
actor LiveQuotaClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private let transport: Transport?
    private let clock: @Sendable () -> Date

    init(transport: Transport? = nil, clock: @escaping @Sendable () -> Date = { .now }) {
        self.transport = transport
        self.clock = clock
    }

    static func request(token: String, accountID: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func load(context: CodexDataContext) async throws -> LiveQuotaObservation {
        guard let identity = context.accountIdentity,
              let auth = CodexCredentials.read(home: context.source.home) else { throw LiveQuotaError.loginRequired }
        guard auth.identity == identity else { throw LiveQuotaError.accountChanged }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: LiveQuotaSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let request = Self.request(token: auth.token, accountID: auth.accountID)
        let data: Data
        let status: Int
        do {
            if let transport {
                (data, status) = try await transport(request)
            } else {
                let (body, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw LiveQuotaError.invalidResponse }
                data = body
                status = response.statusCode
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as LiveQuotaError { throw error }
        catch { throw LiveQuotaError.unavailable }
        try Task.checkCancellation()
        guard CodexCredentials.read(home: context.source.home)?.identity == identity else { throw LiveQuotaError.accountChanged }
        guard status == 200 else { throw LiveQuotaError.rejected(status) }
        return try Self.decode(data, sampledAt: clock())
    }

    static func decode(_ data: Data, sampledAt: Date) throws -> LiveQuotaObservation {
        struct Window: Decodable {
            let used_percent: Double
            let limit_window_seconds: Int
            let reset_at: Double
            func rate(at sampledAt: Date) throws -> RateWindow? {
                guard used_percent.isFinite, (0...100).contains(used_percent),
                      limit_window_seconds > 0, limit_window_seconds % 60 == 0,
                      reset_at.isFinite else { throw LiveQuotaError.invalidResponse }
                guard reset_at > sampledAt.timeIntervalSince1970 else { return nil }
                return RateWindow(usedPercent: used_percent, windowMinutes: limit_window_seconds / 60,
                                  resetsAt: Date(timeIntervalSince1970: reset_at))
            }
        }
        struct Limits: Decodable { let primary_window: Window?; let secondary_window: Window? }
        struct Payload: Decodable { let rate_limit: Limits? }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            let primary = try payload.rate_limit?.primary_window?.rate(at: sampledAt)
            let secondary = try payload.rate_limit?.secondary_window?.rate(at: sampledAt)
            guard [primary, secondary].compactMap({ $0 }).contains(where: { $0.windowMinutes == 10_080 }) else {
                throw LiveQuotaError.invalidResponse
            }
            return LiveQuotaObservation(primary: primary, secondary: secondary, sampledAt: sampledAt)
        } catch { throw LiveQuotaError.invalidResponse }
    }
}
