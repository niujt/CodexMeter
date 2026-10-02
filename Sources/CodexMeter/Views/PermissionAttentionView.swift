import SwiftUI

@MainActor
struct PermissionCenterView: View {
    let store: PermissionStore
    let maximumItems: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("最近权限请求", systemImage: "exclamationmark.shield")
                    .font(.callout.weight(.semibold))
                Spacer()
                if store.newCount > 0 {
                    Text("需要关注 \(store.newCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }

            let events = Array(store.recentEvents.prefix(maximumItems))
            if events.isEmpty {
                Text("暂无权限请求记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(events) { event in
                    PermissionEventRow(event: event, store: store)
                }
                if store.events.count > maximumItems {
                    Text("另有 \(store.events.count - maximumItems) 条记录，可在清除历史前保留最多 24 小时。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if !events.isEmpty {
                HStack {
                    Button("打开 Codex") { PermissionAttentionService.shared.openCodex() }
                        .buttonStyle(.borderedProminent)
                    Button("全部已读") { store.markAllSeen() }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }
}

@MainActor
private struct PermissionEventRow: View {
    let event: CodexPermissionEvent
    let store: PermissionStore

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(event.status == .new ? Color.orange : Color.secondary.opacity(0.45))
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(String(event.project.name.prefix(30)))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(event.permission.toolName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(event.receivedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(event.actionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                store.dismiss(event.eventId)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("忽略这条提醒")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            PermissionAttentionService.shared.openCodex(eventID: event.eventId)
        }
    }
}

@MainActor
struct PermissionSettingsSection: View {
    @AppStorage(PermissionPreferences.enabledKey) private var permissionEnabled = false
    @AppStorage(PermissionPreferences.systemNotificationsKey) private var systemNotifications = true
    @AppStorage(PermissionPreferences.badgeEnabledKey) private var badgeEnabled = true
    @AppStorage(PermissionPreferences.soundEnabledKey) private var soundEnabled = true
    @AppStorage(PermissionPreferences.showPreviewKey) private var showPreview = false
    @AppStorage(PermissionPreferences.retentionHoursKey) private var retentionHours = 24
    @State private var service = PermissionAttentionService.shared
    @State private var showUninstallConfirmation = false

    var body: some View {
        Section("Codex 权限提醒") {
            Toggle("开启权限提醒", isOn: $permissionEnabled)
                .onChange(of: permissionEnabled) { _, enabled in
                    service.setEnabled(enabled)
                }

            LabeledContent("Codex Hook") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(service.hookStatus.isHealthy ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(service.hookStatus.title)
                }
            }
            LabeledContent("系统通知", value: service.notificationStatus)

            Toggle("macOS 系统通知", isOn: $systemNotifications)
            Toggle("菜单栏需要关注数量", isOn: $badgeEnabled)
            Toggle("提示音", isOn: $soundEnabled)
            Toggle("在通知中显示脱敏操作摘要", isOn: $showPreview)

            Picker("最近记录保留", selection: $retentionHours) {
                Text("1 小时").tag(1)
                Text("24 小时").tag(24)
                Text("3 天").tag(72)
                Text("不保存").tag(0)
            }

            Text("PermissionRequest 只表示 Codex 进入权限流程，可能由 Auto Review 继续处理；本应用不会自动允许或拒绝。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = service.integrationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(service.hookStatus.isHealthy ? Color.secondary : Color.orange)
            }

            HStack {
                Button("重新检测") { service.refreshStatus() }
                Button("安装或修复 Hook") { service.repairHook() }
                Button("发送测试提醒") { service.sendTestEvent() }
                Button("通知设置") { service.openNotificationSettings() }
                Spacer()
                Button("卸载 Hook", role: .destructive) { showUninstallConfirmation = true }
            }
            .controlSize(.small)

            Button("清除权限提醒历史", role: .destructive) {
                PermissionStore.shared.clearHistory()
            }
            .controlSize(.small)
        }
        .confirmationDialog(
            "卸载 Codex Health 权限 Hook？",
            isPresented: $showUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("卸载", role: .destructive) { service.uninstallHook() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会从 ~/.codex/hooks.json 删除包含 .codex-monitor/hooks/codex_permission_hook.py 的 handler，并删除该脚本；其他 Hook、历史记录与设置不会删除。")
        }
        .task { service.refreshStatus() }
    }
}
