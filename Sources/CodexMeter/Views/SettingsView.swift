import SwiftUI

@MainActor
struct SettingsView: View {
    let store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("codexMeter.lowRateThreshold") private var lowRateThreshold = 20
    @AppStorage("codexMeter.deduplicateAlerts") private var deduplicateAlerts = true
    @AppStorage(RefreshPolicy.intervalKey) private var refreshInterval = RefreshPolicy.lowPowerDefault
    @AppStorage("codexMeter.appearance") private var appearance = AppAppearance.system.rawValue

    private var appearanceMode: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    var body: some View {
        TabView {
            Form {
                Section("本地数据") {
                    LabeledContent("Codex 数据目录") {
                        Text(store.selectedCodexPath.isEmpty ? "尚未授权" : store.selectedCodexPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    Button("重新选择 Codex 数据目录…", systemImage: "folder") {
                        store.chooseCodexFolder()
                    }
                    Text("仅读取会话记录中的 Token 与额度信息；不会上传会话正文。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("刷新") {
                    Picker("自动刷新", selection: $refreshInterval) {
                        Text("每 5 分钟").tag(300.0)
                        Text("每 15 分钟").tag(900.0)
                        Text("每 30 分钟").tag(1_800.0)
                    }
                    Text("前台按所选间隔刷新；后台以 15 分钟起的间隔由系统调度。低电量模式以 30 分钟起的间隔刷新，温度较高时继续降频；打开摘要和手动刷新仍会按需检查。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("外观") {
                    Picker("显示模式", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Label(mode.title, systemImage: mode.icon).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gearshape") }

            Form {
                Section("低额度提醒") {
                    Picker("提醒阈值", selection: $lowRateThreshold) {
                        Text("剩余 5% 以下").tag(5)
                        Text("剩余 10% 以下").tag(10)
                        Text("剩余 20% 以下").tag(20)
                        Text("剩余 30% 以下").tag(30)
                        Text("剩余 50% 以下").tag(50)
                    }
                    Toggle("同日提醒去重", isOn: $deduplicateAlerts)
                    Text("同时会在预测到额度可能于重置前耗尽时提示。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                PermissionSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("提醒", systemImage: "bell.badge") }

            VStack(spacing: 10) {
                Image(colorScheme == .dark ? "DarkAppIcon" : "LightAppIcon")
                    .resizable().scaledToFit().frame(width: 48, height: 48)
                Text("Codex Health").font(.title2.weight(.bold))
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · 本地优先的 Codex 用量健康中心")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 360)
        .scenePadding()
        .preferredColorScheme(appearanceMode.colorScheme)
    }
}
