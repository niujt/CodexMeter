import Foundation

struct ResetHistoryEvent: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let occurredAt: Date

    var title: String {
        switch kind {
        case "granted": "已获得重置次数"
        case "used", "redeemed": "已使用重置次数"
        default: "其他重置记录"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind
        case occurredAt = "occurred_at"
    }
}

struct ResetHistoryPage: Decodable, Sendable {
    let events: [ResetHistoryEvent]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case events
        case nextCursor = "next_cursor"
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid event timestamp")
        }
        return try decoder.decode(Self.self, from: data)
    }
}

enum ResetHistoryError: LocalizedError {
    case loginRequired, accountChanged, rejected(Int), invalidResponse, incomplete

    var errorDescription: String? {
        switch self {
        case .loginRequired: "未找到可用的 Codex 登录凭据，请先在 Codex 登录 ChatGPT 账户，并确认数据目录。"
        case .accountChanged: "读取期间账户已变化，请重新查询。"
        case .rejected(let status): "重置历史读取失败（HTTP \(status)）。请确认登录状态；此接口可能不接受当前登录凭据。"
        case .invalidResponse: "重置历史响应无法识别，请稍后重试。"
        case .incomplete: "重置历史分页未完成，请重试。"
        }
    }
}

/// Reject redirects so login credentials can only be sent to the fixed API host.
private final class ResetHistorySessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ResetHistoryClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)
    private let transport: Transport?
    init(transport: Transport? = nil) { self.transport = transport }

    // This is the first-party desktop settings endpoint, not a public API contract.
    static func request(token: String, accountID: String, cursor: String?) -> URLRequest {
        var url = URLComponents(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/history")!
        if let cursor, !cursor.isEmpty { url.queryItems = [URLQueryItem(name: "cursor", value: cursor)] }
        var request = URLRequest(url: url.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func load(context: CodexDataContext) async throws -> [ResetHistoryEvent] {
        guard let home = context.source.home, let identity = context.accountIdentity else {
            throw ResetHistoryError.loginRequired
        }
        func credentials() throws -> CodexCredentials {
            guard let auth = CodexCredentials.read(home: home) else { throw ResetHistoryError.loginRequired }
            guard auth.identity == identity else { throw ResetHistoryError.accountChanged }
            return auth
        }
        _ = try credentials()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ResetHistorySessionDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var cursor: String?
        var cursors = Set<String>()
        var events: [String: ResetHistoryEvent] = [:]
        for _ in 0..<100 {
            try Task.checkCancellation()
            let auth = try credentials()
            let request = Self.request(token: auth.token, accountID: auth.accountID, cursor: cursor)
            let data: Data
            let status: Int
            if let transport {
                (data, status) = try await transport(request)
            } else {
                let (body, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw ResetHistoryError.invalidResponse }
                data = body
                status = response.statusCode
            }
            try Task.checkCancellation()
            _ = try credentials() // Never publish a response or send another page for an obsolete account.
            guard status == 200 else { throw ResetHistoryError.rejected(status) }
            guard let page = try? ResetHistoryPage.decode(data) else { throw ResetHistoryError.invalidResponse }
            for event in page.events { events[event.id] = event }
            guard let next = page.nextCursor, !next.isEmpty else {
                return events.values.sorted {
                    $0.occurredAt == $1.occurredAt ? $0.id < $1.id : $0.occurredAt > $1.occurredAt
                }
            }
            guard cursors.insert(next).inserted else { throw ResetHistoryError.incomplete }
            cursor = next
        }
        throw ResetHistoryError.incomplete
    }
}
