import SwiftUI

@MainActor
struct SettingsView: View {
    let store: UsageStore
    @AppStorage("codexMeter.lowRateThreshold") private var lowRateThreshold = 20
    @AppStorage("codexMeter.deduplicateAlerts") private var deduplicateAlerts = true
    @AppStorage("codexMeter.refreshInterval") private var refreshInterval = 60.0

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
                        Text("每 30 秒").tag(30.0)
                        Text("每 1 分钟").tag(60.0)
                        Text("每 5 分钟").tag(300.0)
                    }
                    Text("修改后会立即应用到菜单栏与小组件的数据刷新。")
                        .font(.caption).foregroundStyle(.secondary)
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
            }
            .formStyle(.grouped)
            .tabItem { Label("提醒", systemImage: "bell.badge") }

            VStack(spacing: 10) {
                Image("CodexHealthMark").resizable().scaledToFit().frame(width: 64, height: 64)
                Text("Codex Health").font(.title2.weight(.bold))
                Text("v1.0.0 · 本地优先的 Codex 用量健康中心")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 360)
        .scenePadding()
    }
}
