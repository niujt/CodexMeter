import Foundation
import Observation

extension Notification.Name {
    static let codexPermissionStoreDidChange = Notification.Name("CodexHealth.permissionStoreDidChange")
}

enum PermissionIngestResult: Equatable {
    case inserted
    case repeated
    case duplicate
}

@MainActor
@Observable
final class PermissionStore {
    static let shared = PermissionStore()

    private(set) var events: [CodexPermissionEvent] = []
    private(set) var errorMessage: String?
    @ObservationIgnored private let persistenceURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileManager: FileManager

    init(
        persistenceURL: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL ?? PermissionPaths.default.eventsFile
        load()
        expireAndPrune()
    }

    var newCount: Int {
        events.lazy.filter { $0.status == .new && $0.receivedAt > Date.now.addingTimeInterval(-300) }.count
    }

    var recentEvents: [CodexPermissionEvent] {
        events.sorted { $0.receivedAt > $1.receivedAt }
    }

    @discardableResult
    func ingest(_ rawEvent: CodexPermissionEvent, now: Date = .now) -> PermissionIngestResult {
        let event = PermissionEventSanitizer.sanitize(rawEvent)
        guard event.schemaVersion == 1, event.eventType == "codex.permission.request" else {
            return .duplicate
        }

        expireAndPrune(now: now, persist: false)
        if let index = events.firstIndex(where: { $0.eventId == event.eventId }) {
            let previous = events[index]
            events[index].lastSeenAt = now
            if now.timeIntervalSince(previous.lastSeenAt) <= 30 {
                persistAndNotify()
                return .duplicate
            }
            events[index].receivedAt = event.receivedAt
            events[index].project = event.project
            events[index].permission = event.permission
            events[index].codex = event.codex
            events[index].requiresUserInput = event.requiresUserInput
            events[index].approvalsReviewer = event.approvalsReviewer
            events[index].approvalRoute = event.approvalRoute
            events[index].reviewer = event.reviewer
            events[index].agentId = event.agentId
            events[index].agentType = event.agentType
            events[index].status = .new
            persistAndNotify()
            return .repeated
        }

        var stored = event
        stored.status = .new
        stored.lastSeenAt = now
        events.insert(stored, at: 0)
        persistAndNotify()
        return .inserted
    }

    func markSeen(_ eventID: String) {
        guard let index = events.firstIndex(where: { $0.eventId == eventID }) else { return }
        events[index].status = .seen
        persistAndNotify()
    }

    func dismiss(_ eventID: String) {
        guard let index = events.firstIndex(where: { $0.eventId == eventID }) else { return }
        events[index].status = .dismissed
        persistAndNotify()
    }

    func markAllSeen() {
        for index in events.indices where events[index].status == .new {
            events[index].status = .seen
        }
        persistAndNotify()
    }

    func clearHistory() {
        events.removeAll()
        persistAndNotify()
    }

    func expireAndPrune(now: Date = .now, persist: Bool = true) {
        let expiry = now.addingTimeInterval(-300)
        for index in events.indices where events[index].status == .new && events[index].receivedAt <= expiry {
            events[index].status = .expired
        }

        let retentionHours = defaults.object(forKey: PermissionPreferences.retentionHoursKey) as? Int ?? 24
        if retentionHours <= 0 {
            events.removeAll()
        } else {
            let cutoff = now.addingTimeInterval(-Double(retentionHours) * 3_600)
            events.removeAll { $0.receivedAt < cutoff }
        }
        if persist { persistAndNotify() }
    }

    private func load() {
        guard let data = try? Data(contentsOf: persistenceURL) else { return }
        do {
            events = try JSONDecoder().decode([CodexPermissionEvent].self, from: data)
                .map(PermissionEventSanitizer.sanitize)
                .sorted { $0.receivedAt > $1.receivedAt }
        } catch {
            errorMessage = "权限提醒历史无法读取：\(error.localizedDescription)"
        }
    }

    private func persistAndNotify() {
        do {
            try fileManager.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let data = try JSONEncoder().encode(events)
            try data.write(to: persistenceURL, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: persistenceURL.path)
            errorMessage = nil
        } catch {
            errorMessage = "权限提醒历史无法保存：\(error.localizedDescription)"
        }
        NotificationCenter.default.post(name: .codexPermissionStoreDidChange, object: self)
    }
}
