import Foundation

private final class DeepSeekBalanceSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor DeepSeekBalanceClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private let transport: Transport?
    init(transport: Transport? = nil) { self.transport = transport }

    static func request(key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func load(key: String, now: Date = .now) async throws -> DeepSeekBalanceSnapshot {
        guard APIKeychain.isValid(key) else { throw DeepSeekBalanceError.invalidKey }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: DeepSeekBalanceSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let status: Int
        do {
            if let transport { (data, status) = try await transport(Self.request(key: key)) }
            else {
                let (body, response) = try await session.data(for: Self.request(key: key))
                guard let response = response as? HTTPURLResponse else { throw DeepSeekBalanceError.invalidResponse }
                data = body
                status = response.statusCode
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as DeepSeekBalanceError { throw error }
        catch { throw DeepSeekBalanceError.unavailable }
        try Task.checkCancellation()
        switch status {
        case 200: return try Self.decode(data, checkedAt: now)
        case 401: throw DeepSeekBalanceError.unauthorized
        default: throw DeepSeekBalanceError.rejected(status)
        }
    }

    static func decode(_ data: Data, checkedAt: Date) throws -> DeepSeekBalanceSnapshot {
        struct Payload: Decodable {
            struct Balance: Decodable {
                let currency: String
                let total_balance: String
                let granted_balance: String
                let topped_up_balance: String
            }
            let is_available: Bool
            let balance_infos: [Balance]
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            var currencies = Set<String>()
            let balances = try payload.balance_infos.map { item in
                guard ["CNY", "USD"].contains(item.currency), currencies.insert(item.currency).inserted else {
                    throw DeepSeekBalanceError.invalidResponse
                }
                return try DeepSeekBalance(currency: item.currency, total: money(item.total_balance),
                                          granted: money(item.granted_balance), toppedUp: money(item.topped_up_balance))
            }
            return DeepSeekBalanceSnapshot(isAvailable: payload.is_available, balances: balances, checkedAt: checkedAt)
        } catch { throw DeepSeekBalanceError.invalidResponse }
    }

    private static func money(_ value: String) throws -> Decimal {
        guard value.range(of: #"\A-?[0-9]+(?:\.[0-9]+)?\z"#, options: .regularExpression) != nil,
              value.filter(\.isNumber).count <= 38,
              let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else {
            throw DeepSeekBalanceError.invalidResponse
        }
        return number
    }
}
