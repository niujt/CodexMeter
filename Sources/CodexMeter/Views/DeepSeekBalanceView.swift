import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct DeepSeekBalanceView: View {
    var balance = DeepSeekBalanceStore.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("DeepSeek 余额").font(.title2.weight(.semibold))
                    Text("DeepSeek 官方账户 · 当前剩余余额")
                        .font(.subheadline).foregroundStyle(DashboardPalette.secondaryInk)
                }
                Spacer()
                Button("设置密钥", systemImage: "key") { openDeepSeekSettings() }
                Button("刷新余额", systemImage: "arrow.clockwise") {
                    Task { await balance.refresh(force: true) }
                }.disabled(!balance.hasCredential || balance.isRefreshing)
            }
            if balance.isRefreshing { ProgressView("正在查询 DeepSeek 余额…").controlSize(.small) }
            if let error = balance.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle")
                    if balance.snapshot != nil { Text("以下为上次成功查询的结果，请留意查询时间。") }
                }.font(.callout)
            }

            if let snapshot = balance.snapshot {
                Label((balance.errorMessage == nil ? "" : "上次查询：")
                      + (snapshot.isAvailable ? "余额可供 API 调用" : "无可用余额供 API 调用"),
                      systemImage: snapshot.isAvailable ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.callout).foregroundStyle(DashboardPalette.secondaryInk)
                ForEach(snapshot.balances) { item in
                    DashboardPanel {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(item.currencyTitle).font(.headline)
                            HStack(alignment: .top, spacing: 24) {
                                SummaryMetric(title: "剩余可用余额", value: money(item.total, currency: item.currency), detail: "充值余额 + 未过期赠金")
                                Spacer()
                                SummaryMetric(title: "充值余额", value: money(item.toppedUp, currency: item.currency), detail: "当前账户剩余充值金额")
                                Spacer()
                                SummaryMetric(title: "未过期赠金", value: money(item.granted, currency: item.currency), detail: "当前仍可使用的赠金")
                            }
                        }
                    }
                }
                if snapshot.balances.isEmpty {
                    Text("官方接口未返回余额明细，请稍后刷新或到官方控制台核对。")
                        .foregroundStyle(DashboardPalette.secondaryInk)
                }
                Text("查询时间：\(snapshot.checkedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            } else if !balance.hasCredential {
                ContentUnavailableView {
                    Label("连接 DeepSeek", systemImage: "key")
                } description: {
                    Text("在设置的“API → DeepSeek”中配置 DeepSeek API Key，查看账户剩余余额。")
                } actions: {
                    Button("配置 DeepSeek 密钥") { openDeepSeekSettings() }
                }.frame(minHeight: 230)
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("余额说明").font(.headline)
                    Text("余额由 DeepSeek 官方实时查询接口返回，属于所配置密钥对应的账户。人民币与美元分别展示，不合并换算。")
                    Text("进入页面时查询，5 分钟内复用当前结果；手动刷新立即查询。密钥与 OpenAI 分开保存在本机钥匙串。")
                    Link("打开 DeepSeek 控制台", destination: URL(string: "https://platform.deepseek.com/")!)
                }.font(.callout).foregroundStyle(DashboardPalette.secondaryInk)
            }
        }
        .padding(28)
        .frame(maxWidth: 1_100, alignment: .leading)
        .task { await balance.refresh() }
        .onChange(of: balance.credentialRevision) { _, _ in Task { await balance.refresh() } }
    }

    private func openDeepSeekSettings() {
        UserDefaults.standard.set("deepseek", forKey: APISettingsView.providerKey)
        UserDefaults.standard.set("api", forKey: SettingsView.selectedTabKey)
        openSettings()
    }

    private func money(_ amount: Decimal, currency: String) -> String {
        amount.formatted(.currency(code: currency).precision(.fractionLength(2...8)))
    }
}

@MainActor
struct DeepSeekSettingsView: View {
    var balance = DeepSeekBalanceStore.shared
    @State private var keyText = ""
    @State private var feedback: String?

    var body: some View {
        Form {
            Section("DeepSeek 官方 API") {
                LabeledContent("接口", value: "https://api.deepseek.com")
                LabeledContent("密钥状态", value: balance.hasCredential ? "已独立存入本机钥匙串" : "尚未配置")
                SecureField("DeepSeek API Key", text: $keyText, prompt: Text("输入 DeepSeek 密钥以保存或替换"))
                    .autocorrectionDisabled()
                HStack {
                    Button("保存到钥匙串") { save(keyText) }.disabled(keyText.isEmpty)
                    Button("从文件导入…", systemImage: "doc") { importKey() }
                }
                Text("点击保存或导入，将把 DeepSeek 密钥独立保存到此 Mac 的钥匙串，仅用于向 DeepSeek 官方接口查询余额。")
                    .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                if let message = feedback ?? balance.errorMessage {
                    Text(message).font(.caption).textSelection(.enabled)
                }
            }
            Section("查询余额") {
                Text("使用普通 DeepSeek API Key 即可查询总可用余额、充值余额和未过期赠金。在详情侧栏打开“DeepSeek 余额”查看。")
                Text("只发送余额查询，不调用模型；查询结果保存在内存中。")
                Link("管理 DeepSeek API Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
            }.font(.callout)
        }
        .formStyle(.grouped)
        .task { balance.checkCredential() }
    }

    private func save(_ text: String) {
        if balance.saveCredential(text) {
            keyText = ""
            feedback = "DeepSeek 密钥已保存，可在“DeepSeek 余额”页面查询。"
        } else { feedback = balance.errorMessage }
    }

    private func importKey() {
        let panel = NSOpenPanel()
        panel.title = "导入 DeepSeek API Key 到本机钥匙串"
        panel.message = "选择只含一个 DeepSeek API Key 的 UTF-8 文本文件。"
        panel.allowedContentTypes = [.plainText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16_384 else { throw DeepSeekBalanceError.invalidKey }
            save(try String(contentsOf: url, encoding: .utf8))
        } catch { feedback = "无法从该文件导入，请选择只含一个 DeepSeek API Key 的 UTF-8 文本文件。" }
    }
}
