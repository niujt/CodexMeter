import Foundation

enum PermissionAttentionLevel: String, Codable, Sendable {
    case info
    case possibleAttention
    case humanAttention
}

enum PermissionEventStatus: String, Codable, Sendable {
    case new
    case seen
    case dismissed
    case expired
}

struct CodexPermissionEvent: Codable, Identifiable, Equatable, Sendable {
    struct Project: Codable, Equatable, Sendable {
        var name: String
        var cwd: String
    }

    struct Permission: Codable, Equatable, Sendable {
        var mode: String
        var toolName: String
        var description: String?
        var preview: String?
    }

    struct CodexInfo: Codable, Equatable, Sendable {
        var model: String
    }

    var schemaVersion: Int
    var eventType: String
    var eventId: String
    var receivedAt: Date
    var sessionId: String
    var turnId: String
    var project: Project
    var permission: Permission
    var codex: CodexInfo
    var requiresUserInput: Bool?
    var approvalsReviewer: String?
    var approvalRoute: String?
    var reviewer: String?
    var agentId: String?
    var agentType: String?
    var status: PermissionEventStatus
    var lastSeenAt: Date

    var id: String { eventId }

    var attentionLevel: PermissionAttentionLevel {
        if requiresUserInput == true || approvalsReviewer == "user" || reviewer == "user" {
            return .humanAttention
        }
        if permission.mode == "bypassPermissions" || approvalsReviewer == "auto_review" {
            return .info
        }
        return .possibleAttention
    }

    var actionSummary: String {
        switch permission.toolName.lowercased() {
        case "bash": "请求执行命令"
        case "apply_patch": "请求修改文件"
        case "edit": "请求编辑文件"
        case "write": "请求写入文件"
        case "network": "请求网络访问"
        default:
            permission.toolName.hasPrefix("mcp__") ? "MCP 工具请求" : "请求额外权限"
        }
    }

    init(
        schemaVersion: Int = 1,
        eventType: String = "codex.permission.request",
        eventId: String,
        receivedAt: Date,
        sessionId: String,
        turnId: String,
        project: Project,
        permission: Permission,
        codex: CodexInfo,
        requiresUserInput: Bool? = nil,
        approvalsReviewer: String? = nil,
        approvalRoute: String? = nil,
        reviewer: String? = nil,
        agentId: String? = nil,
        agentType: String? = nil,
        status: PermissionEventStatus = .new,
        lastSeenAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.eventType = eventType
        self.eventId = eventId
        self.receivedAt = receivedAt
        self.sessionId = sessionId
        self.turnId = turnId
        self.project = project
        self.permission = permission
        self.codex = codex
        self.requiresUserInput = requiresUserInput
        self.approvalsReviewer = approvalsReviewer
        self.approvalRoute = approvalRoute
        self.reviewer = reviewer
        self.agentId = agentId
        self.agentType = agentType
        self.status = status
        self.lastSeenAt = lastSeenAt ?? receivedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, eventType, eventId, receivedAt, sessionId, turnId
        case project, permission, codex, requiresUserInput, approvalsReviewer
        case approvalRoute, reviewer, agentId, agentType, status, lastSeenAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        eventType = try container.decodeIfPresent(String.self, forKey: .eventType) ?? "codex.permission.request"
        eventId = try container.decode(String.self, forKey: .eventId)
        receivedAt = try Self.decodeDate(container: container, key: .receivedAt)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? "unknown-session"
        turnId = try container.decodeIfPresent(String.self, forKey: .turnId) ?? "unknown-turn"
        project = try container.decodeIfPresent(Project.self, forKey: .project) ?? .init(name: "未知项目", cwd: "")
        permission = try container.decodeIfPresent(Permission.self, forKey: .permission)
            ?? .init(mode: "default", toolName: "unknown", description: nil, preview: nil)
        codex = try container.decodeIfPresent(CodexInfo.self, forKey: .codex) ?? .init(model: "unknown")
        requiresUserInput = try container.decodeIfPresent(Bool.self, forKey: .requiresUserInput)
        approvalsReviewer = try container.decodeIfPresent(String.self, forKey: .approvalsReviewer)
        approvalRoute = try container.decodeIfPresent(String.self, forKey: .approvalRoute)
        reviewer = try container.decodeIfPresent(String.self, forKey: .reviewer)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        agentType = try container.decodeIfPresent(String.self, forKey: .agentType)
        status = try container.decodeIfPresent(PermissionEventStatus.self, forKey: .status) ?? .new
        lastSeenAt = (try? Self.decodeDate(container: container, key: .lastSeenAt)) ?? receivedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(eventId, forKey: .eventId)
        try container.encode(receivedAt.timeIntervalSince1970, forKey: .receivedAt)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(turnId, forKey: .turnId)
        try container.encode(project, forKey: .project)
        try container.encode(permission, forKey: .permission)
        try container.encode(codex, forKey: .codex)
        try container.encodeIfPresent(requiresUserInput, forKey: .requiresUserInput)
        try container.encodeIfPresent(approvalsReviewer, forKey: .approvalsReviewer)
        try container.encodeIfPresent(approvalRoute, forKey: .approvalRoute)
        try container.encodeIfPresent(reviewer, forKey: .reviewer)
        try container.encodeIfPresent(agentId, forKey: .agentId)
        try container.encodeIfPresent(agentType, forKey: .agentType)
        try container.encode(status, forKey: .status)
        try container.encode(lastSeenAt.timeIntervalSince1970, forKey: .lastSeenAt)
    }

    private static func decodeDate(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Date {
        if let seconds = try? container.decode(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: seconds)
        }
        let text = try container.decode(String.self, forKey: key)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let standard = ISO8601DateFormatter()
        guard let date = standard.date(from: text) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "Invalid ISO 8601 date")
        }
        return date
    }
}

enum PermissionEventSanitizer {
    static func sanitize(_ event: CodexPermissionEvent) -> CodexPermissionEvent {
        var event = event
        event.eventType = "codex.permission.request"
        event.sessionId = limited(event.sessionId, max: 160, fallback: "unknown-session")
        event.turnId = limited(event.turnId, max: 160, fallback: "unknown-turn")
        event.project.cwd = limited(event.project.cwd, max: 1_024, fallback: "")
        let fallbackName = URL(fileURLWithPath: event.project.cwd).lastPathComponent
        event.project.name = limited(event.project.name, max: 80, fallback: fallbackName.isEmpty ? "未知项目" : fallbackName)
        event.permission.mode = limited(event.permission.mode, max: 80, fallback: "default")
        event.permission.toolName = limited(event.permission.toolName, max: 120, fallback: "unknown")
        event.permission.description = sanitizePreview(event.permission.description).map { String($0.prefix(160)) }
        event.permission.preview = sanitizePreview(event.permission.preview)
        event.codex.model = limited(event.codex.model, max: 120, fallback: "unknown")
        return event
    }

    static func sanitizePreview(_ preview: String?) -> String? {
        guard var value = preview?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "[\\r\\n\\t]+", with: " ", options: .regularExpression)
        let patterns = [
            #"(?i)(authorization\s*:\s*(?:bearer\s+)?)[^\s\"']+"#,
            #"(?i)((?:password|passwd|token|secret|api[_-]?key|apikey|access[_-]?key|cookie|session)\s*[=:]\s*)[^\s&\"']+"#,
            #"(?i)([?&](?:password|passwd|token|secret|api[_-]?key|apikey|access[_-]?key|cookie|session)=)[^&\s]+"#,
            #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: "$1***", options: .regularExpression)
        }
        guard !value.isEmpty else { return nil }
        return String(value.prefix(240))
    }

    private static func limited(_ value: String, max: Int, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(max))
    }
}
