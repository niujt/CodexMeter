import AppKit
import Darwin
import Dispatch
import Foundation
import Observation
import UserNotifications

enum PermissionPreferences {
    static let enabledKey = "codexMeter.permissionAttention.enabled"
    static let systemNotificationsKey = "codexMeter.permissionAttention.systemNotifications"
    static let badgeEnabledKey = "codexMeter.permissionAttention.badge"
    static let soundEnabledKey = "codexMeter.permissionAttention.sound"
    static let showPreviewKey = "codexMeter.permissionAttention.showPreview"
    static let retentionHoursKey = "codexMeter.permissionAttention.retentionHours"

    static func configure(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            enabledKey: false,
            systemNotificationsKey: true,
            badgeEnabledKey: true,
            soundEnabledKey: true,
            showPreviewKey: false,
            retentionHoursKey: 24
        ])
    }
}

@MainActor
@Observable
final class PermissionAttentionService {
    static let shared = PermissionAttentionService()

    private(set) var hookStatus: PermissionHookStatus = .notInstalled
    private(set) var integrationMessage: String?
    private(set) var notificationStatus = "尚未请求"

    @ObservationIgnored private let paths: PermissionPaths
    @ObservationIgnored private let installer: PermissionHookInstaller
    @ObservationIgnored private let store: PermissionStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private var directorySource: DispatchSourceFileSystemObject?
    @ObservationIgnored private var directoryDescriptor: Int32 = -1
    @ObservationIgnored private var expiryTimer: Timer?
    @ObservationIgnored private var notificationDates: [Date] = []
    @ObservationIgnored private var sessionNotificationDates: [String: [Date]] = [:]
    @ObservationIgnored private var sessionSoundDates: [String: Date] = [:]
    @ObservationIgnored private var sessionSummaryDates: [String: Date] = [:]

    init(
        paths: PermissionPaths = .default,
        store: PermissionStore = .shared,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.store = store
        self.defaults = defaults
        self.fileManager = fileManager
        self.installer = PermissionHookInstaller(paths: paths, fileManager: fileManager)
        hookStatus = installer.status()
    }

    func start() {
        PermissionPreferences.configure(defaults: defaults)
        hookStatus = installer.status()
        if defaults.bool(forKey: PermissionPreferences.enabledKey) {
            repairHook()
        }
        do {
            try fileManager.createDirectory(
                at: paths.spoolDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.spoolDirectory.path)
            startDirectoryMonitor()
            processSpool()
        } catch {
            integrationMessage = "权限提醒队列无法启动：\(error.localizedDescription)"
        }
        expiryTimer?.invalidate()
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.store.expireAndPrune() }
        }
        refreshNotificationStatus()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: PermissionPreferences.enabledKey)
        guard enabled else {
            integrationMessage = "权限提醒已暂停；已安装 Hook 可在下方单独卸载。"
            return
        }
        repairHook()
        requestNotificationAuthorization()
    }

    func repairHook() {
        do {
            try installer.install()
            hookStatus = installer.status()
            integrationMessage = "Hook 已安装。请在 Codex 中使用 /hooks 检查并信任该 Hook。"
        } catch {
            hookStatus = installer.status()
            integrationMessage = error.localizedDescription
        }
    }

    func uninstallHook() {
        do {
            try installer.uninstall()
            defaults.set(false, forKey: PermissionPreferences.enabledKey)
            hookStatus = installer.status()
            integrationMessage = "仅 Codex Health 的 PermissionRequest Hook 已卸载，其他 Hook 保持不变。"
        } catch {
            hookStatus = installer.status()
            integrationMessage = error.localizedDescription
        }
    }

    func refreshStatus() {
        hookStatus = installer.status()
        refreshNotificationStatus()
    }

    func sendTestEvent() {
        let event = CodexPermissionEvent(
            eventId: UUID().uuidString,
            receivedAt: .now,
            sessionId: "test-session",
            turnId: "test-turn",
            project: .init(name: "演示项目", cwd: "/tmp/demo-project"),
            permission: .init(mode: "default", toolName: "Bash", description: "测试权限提醒", preview: "echo test"),
            codex: .init(model: "test")
        )
        accept(event)
    }

    func openCodex(eventID: String? = nil) {
        if let eventID { store.markSeen(eventID) }
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveCompare("Codex") == .orderedSame
        }) {
            running.activate(options: [.activateAllWindows])
            return
        }
        let bundleIdentifiers = ["com.openai.codex", "com.openai.Codex"]
        for identifier in bundleIdentifiers {
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first {
                running.activate(options: [.activateAllWindows])
                return
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                openApplication(at: url)
                return
            }
        }
        let standardURL = URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
        if fileManager.fileExists(atPath: standardURL.path) {
            openApplication(at: standardURL)
            return
        }
        let userURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Codex.app", isDirectory: true)
        if fileManager.fileExists(atPath: userURL.path) {
            openApplication(at: userURL)
            return
        }
        integrationMessage = "未找到 Codex.app，请先手动打开 Codex。"
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    func requestNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshNotificationStatus() }
        }
    }

    private func startDirectoryMonitor() {
        if let directorySource {
            directorySource.cancel()
            self.directorySource = nil
        } else if directoryDescriptor >= 0 {
            close(directoryDescriptor)
        }
        directoryDescriptor = open(paths.spoolDirectory.path, O_EVTONLY)
        guard directoryDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryDescriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.processSpool() }
        }
        source.setCancelHandler { [descriptor = directoryDescriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        directorySource = source
        source.resume()
    }

    private func processSpool() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: paths.spoolDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.pathExtension == "json" {
            defer { try? fileManager.removeItem(at: file) }
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  (values.fileSize ?? 0) <= 65_536,
                  let data = try? Data(contentsOf: file),
                  let event = try? JSONDecoder().decode(CodexPermissionEvent.self, from: data) else {
                continue
            }
            guard defaults.bool(forKey: PermissionPreferences.enabledKey) else { continue }
            accept(event)
        }
    }

    private func accept(_ event: CodexPermissionEvent) {
        let result = store.ingest(event)
        guard result != .duplicate else { return }
        postNotification(for: PermissionEventSanitizer.sanitize(event))
    }

    private func postNotification(for event: CodexPermissionEvent, now: Date = .now) {
        guard defaults.bool(forKey: PermissionPreferences.systemNotificationsKey) else { return }
        notificationDates.removeAll { now.timeIntervalSince($0) > 60 }
        guard notificationDates.count < 10 else { return }

        var sessionDates = sessionNotificationDates[event.sessionId, default: []]
        sessionDates.removeAll { now.timeIntervalSince($0) > 10 }
        let shouldSummarize = sessionDates.count >= 3
        if shouldSummarize,
           let lastSummary = sessionSummaryDates[event.sessionId],
           now.timeIntervalSince(lastSummary) < 10 {
            sessionNotificationDates[event.sessionId] = sessionDates
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Codex 权限请求"
        if shouldSummarize {
            content.body = "\(event.project.name) 有多个新的权限请求"
            sessionSummaryDates[event.sessionId] = now
        } else if defaults.bool(forKey: PermissionPreferences.showPreviewKey),
                  let preview = event.permission.preview {
            content.body = "\(event.project.name) · \(event.permission.toolName)\n\(String(preview.prefix(80)))"
        } else {
            content.body = "\(event.project.name) · \(event.permission.toolName)\n可能需要你的确认"
        }
        content.userInfo = ["kind": "codex.permission.request", "eventId": event.eventId]

        let soundEnabled = defaults.bool(forKey: PermissionPreferences.soundEnabledKey)
        let lastSound = sessionSoundDates[event.sessionId]
        if soundEnabled, lastSound == nil || now.timeIntervalSince(lastSound!) >= 5 {
            content.sound = .default
            sessionSoundDates[event.sessionId] = now
        }

        notificationDates.append(now)
        sessionDates.append(now)
        sessionNotificationDates[event.sessionId] = sessionDates
        let request = UNNotificationRequest(identifier: "codex-permission-\(event.eventId)-\(Int(now.timeIntervalSince1970))", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: text = "已授权"
            case .denied: text = "未授权"
            case .notDetermined: text = "尚未请求"
            @unknown default: text = "未知"
            }
            Task { @MainActor [weak self] in self?.notificationStatus = text }
        }
    }

    private func openApplication(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
