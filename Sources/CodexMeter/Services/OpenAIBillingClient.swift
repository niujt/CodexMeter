import Foundation

private final class APIBillingSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Only the three documented, read-only organization endpoints are allowed.
actor OpenAIBillingClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private let transport: Transport?
    init(transport: Transport? = nil) { self.transport = transport }

    enum Endpoint: String, Sendable {
        case costs = "costs", usage = "usage/completions", limit = "spend_limit"
        var scope: String { self == .limit ? "api.management.read" : "api.usage.read" }
    }

    static func request(_ endpoint: Endpoint, key: String, start: Date, end: Date,
                        page: String? = nil) -> URLRequest {
        var url = URLComponents(string: "https://api.openai.com/v1/organization/\(endpoint.rawValue)")!
        if endpoint != .limit {
            let startSeconds = Int(start.timeIntervalSince1970)
            url.queryItems = [
                .init(name: "start_time", value: String(startSeconds)),
                .init(name: "end_time", value: String(max(startSeconds + 1, Int(end.timeIntervalSince1970)))),
                .init(name: "bucket_width", value: "1d"), .init(name: "limit", value: "31")
            ]
            if let page { url.queryItems?.append(.init(name: "page", value: page)) }
        }
        var request = URLRequest(url: url.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func load(key: String, now: Date = .now) async throws -> APIBillingSnapshot {
        guard APIKeychain.isValid(key) else { throw APIBillingError.invalidKey }
        let start = APIBillingSnapshot.monthStart(at: now)
        let end = APIBillingSnapshot.queryEnd(at: now)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration, delegate: APIBillingSessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let costs: APIBillingResult<APICosts> = await result {
            let rows: [CostRow] = try await self.rows(.costs, key: key, start: start, end: end, session: session)
            var costs = APICosts()
            for row in rows {
                let currency = row.amount.currency.lowercased()
                guard currency.count == 3, currency.utf8.allSatisfy({ (97...122).contains($0) }),
                      !row.amount.value.isNaN else { throw APIBillingError.invalidResponse }
                costs.amounts[currency, default: 0] += row.amount.value
                guard costs.amounts[currency]?.isNaN == false else { throw APIBillingError.invalidResponse }
            }
            return costs
        }
        try Task.checkCancellation()
        let usage: APIBillingResult<APIUsageTotals> = await result {
            let rows: [UsageRow] = try await self.rows(.usage, key: key, start: start, end: end, session: session)
            var totals = APIUsageTotals()
            for row in rows {
                guard row.input_tokens >= 0, row.output_tokens >= 0, row.num_model_requests >= 0,
                      (0...row.input_tokens).contains(row.input_cached_tokens ?? 0) else { throw APIBillingError.invalidResponse }
                totals.input = try Self.add(totals.input, row.input_tokens)
                totals.output = try Self.add(totals.output, row.output_tokens)
                totals.cachedInput = try Self.add(totals.cachedInput, row.input_cached_tokens ?? 0)
                totals.requests = try Self.add(totals.requests, row.num_model_requests)
            }
            return totals
        }
        try Task.checkCancellation()
        let limit: APIBillingResult<APISpendLimitState> = await result {
            let (data, status) = try await self.send(.limit, key: key, start: start, end: now, session: session)
            if status == 404, Self.isUnconfiguredLimit(data) { return .notConfigured }
            try Self.check(status, endpoint: .limit, data: data)
            let dto = try Self.decode(LimitPayload.self, data)
            guard dto.currency.uppercased() == "USD", dto.interval == "month", dto.threshold_amount >= 0,
                  ["inactive", "enforcing"].contains(dto.enforcement.status) else { throw APIBillingError.invalidResponse }
            return .configured(amount: Decimal(dto.threshold_amount) / 100, enforcing: dto.enforcement.status == "enforcing")
        }
        try Task.checkCancellation()
        return APIBillingSnapshot(periodStart: start, checkedAt: now, costs: costs, usage: usage, spendLimit: limit)
    }

    private func result<T: Sendable>(_ work: () async throws -> T) async -> APIBillingResult<T> {
        do { return .available(try await work()) }
        catch let error as APIBillingError { return .unavailable(error) }
        catch { return .unavailable(.unavailable) }
    }

    private func rows<Row: Decodable & Sendable>(_ endpoint: Endpoint, key: String, start: Date, end: Date,
                                                session: URLSession) async throws -> [Row] {
        var rows: [Row] = []
        var cursor: String?
        var seen = Set<String>()
        for _ in 0..<100 {
            try Task.checkCancellation()
            let (data, status) = try await send(endpoint, key: key, start: start, end: end, page: cursor, session: session)
            try Self.check(status, endpoint: endpoint, data: data)
            let page = try Self.decode(Page<Row>.self, data)
            rows.append(contentsOf: page.data.flatMap(\.results))
            if !page.has_more { return rows }
            guard let next = page.next_page, !next.isEmpty, seen.insert(next).inserted else { throw APIBillingError.incompletePages }
            cursor = next
        }
        throw APIBillingError.incompletePages
    }

    private func send(_ endpoint: Endpoint, key: String, start: Date, end: Date, page: String? = nil,
                      session: URLSession) async throws -> (Data, Int) {
        try Task.checkCancellation()
        let request = Self.request(endpoint, key: key, start: start, end: end, page: page)
        do {
            if let transport { return try await transport(request) }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw APIBillingError.invalidResponse }
            return (data, response.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let error as APIBillingError { throw error }
        catch { throw APIBillingError.unavailable }
    }

    private static func check(_ status: Int, endpoint: Endpoint, data: Data) throws {
        switch status {
        case 200: return
        case 401: throw APIBillingError.unauthorized
        case 403:
            // A country restriction or proxy block is also a 403; don't call it a missing scope.
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = object?["error"] as? String
                ?? (object?["error"] as? [String: Any])?["message"] as? String ?? ""
            if message.lowercased().contains("missing scopes:"), message.contains(endpoint.scope) {
                throw APIBillingError.permission(endpoint.scope)
            }
            throw APIBillingError.rejected(status)
        default: throw APIBillingError.rejected(status)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIBillingError.invalidResponse }
    }

    private static func isUnconfiguredLimit(_ data: Data) -> Bool {
        struct Payload: Decodable {
            struct Detail: Decodable { let code: String?; let message: String? }
            let error: Detail
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return false }
        return payload.error.code == "not_found"
            && payload.error.message == "No organization spend limit is configured."
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw APIBillingError.invalidResponse }
        return value
    }

    private struct Page<Row: Decodable & Sendable>: Decodable, Sendable {
        struct Bucket: Decodable, Sendable { let results: [Row] }
        let data: [Bucket]
        let has_more: Bool
        let next_page: String?
    }
    private struct CostRow: Decodable, Sendable {
        struct Amount: Decodable, Sendable { let value: Decimal; let currency: String }
        let amount: Amount
    }
    private struct UsageRow: Decodable, Sendable {
        let input_tokens: Int64
        let output_tokens: Int64
        let input_cached_tokens: Int64?
        let num_model_requests: Int64
    }
    private struct LimitPayload: Decodable {
        struct Enforcement: Decodable { let status: String }
        let threshold_amount: Int64
        let currency: String
        let interval: String
        let enforcement: Enforcement
    }
}
