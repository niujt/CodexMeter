import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct APIBillingView: View {
    var billing = APIBillingStore.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API 用量与费用").font(.title2.weight(.semibold))
                    Text("OpenAI 官方组织数据 · 本月按 UTC 统计")
                        .font(.subheadline).foregroundStyle(DashboardPalette.secondaryInk)
                }
                Spacer()
                Button("设置密钥", systemImage: "key") { openAPISettings() }
                Button("刷新 API", systemImage: "arrow.clockwise") {
                    Task { await billing.refresh(force: true) }
                }.disabled(!billing.hasCredential || billing.isRefreshing)
            }

            if billing.isRefreshing { ProgressView("正在查询官方 API…").controlSize(.small) }
            if let error = billing.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.callout)
            }

            if let snapshot = billing.snapshot {
                summary(snapshot)
                if !snapshot.warnings.isEmpty {
                    DashboardPanel {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(snapshot.hasData ? "部分查询未完成" : "查询未完成", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            ForEach(snapshot.warnings, id: \.self) { warning in
                                Text(warning).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                }
                Text("统计区间：\(utcDate(snapshot.periodStart)) 至 \(utcDate(snapshot.checkedAt)) UTC。费用与用量可能存在统计延迟。")
                    .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            } else if !billing.hasCredential {
                ContentUnavailableView {
                    Label("连接 OpenAI API", systemImage: "key")
                } description: {
                    Text("在设置的“API”页导入 Admin API Key，查看组织本月费用和用量。")
                } actions: {
                    Button("打开设置") { openAPISettings() }
                }.frame(minHeight: 230)
            }

            DashboardCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("统计范围").font(.headline)
                    Text("费用涵盖该密钥所属组织的全部项目与 API 消费。Token 与请求数来自官方文本用量接口，包含其支持的模型请求，不涵盖所有音频、图像或存储用量。")
                    Text("这里展示消费记录与组织月度预算；充值余额请在官方账单页查看。")
                    HStack {
                        Link("官方账单", destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
                        Link("官方用量", destination: URL(string: "https://platform.openai.com/usage")!)
                    }
                }.font(.callout).foregroundStyle(DashboardPalette.secondaryInk)
            }
        }
        .padding(28)
        .frame(maxWidth: 1_100, alignment: .leading)
        .task { await billing.refresh() }
        .onChange(of: billing.credentialRevision) { _, _ in Task { await billing.refresh() } }
    }

    @ViewBuilder private func summary(_ snapshot: APIBillingSnapshot) -> some View {
        DashboardPanel {
            HStack(alignment: .top, spacing: 24) {
                SummaryMetric(title: "本月消费", value: costText(snapshot.costs.value), detail: "组织全部 API 费用")
                Spacer()
                SummaryMetric(title: "月度消费上限", value: limitText(snapshot.spendLimit.value), detail: enforcementText(snapshot.spendLimit.value))
                Spacer()
                SummaryMetric(title: "预算剩余估算", value: snapshot.estimatedBudgetRemaining.map(money) ?? "—", detail: "上限减去已记录消费")
            }
        }
        DashboardPanel {
            VStack(alignment: .leading, spacing: 18) {
                Text("本月文本 API 用量").font(.headline)
                HStack(spacing: 24) {
                    MetricRow("输入 Token", snapshot.usage.value.map { $0.input.formatted() } ?? "—")
                    MetricRow("其中缓存输入", snapshot.usage.value.map { $0.cachedInput.formatted() } ?? "—")
                    MetricRow("输出 Token", snapshot.usage.value.map { $0.output.formatted() } ?? "—")
                    MetricRow("请求数", snapshot.usage.value.map { $0.requests.formatted() } ?? "—")
                }
                Text("缓存输入已包含在输入 Token 中。")
                    .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
        }
    }

    private func openAPISettings() {
        UserDefaults.standard.set("api", forKey: SettingsView.selectedTabKey)
        openSettings()
    }

    private func costText(_ costs: APICosts?) -> String {
        guard let costs else { return "—" }
        if costs.amounts.isEmpty { return money(0) }
        return costs.amounts.keys.sorted().map { currency in
            costs.amounts[currency]!.formatted(.currency(code: currency.uppercased()))
        }.joined(separator: " / ")
    }

    private func money(_ amount: Decimal) -> String { amount.formatted(.currency(code: "USD")) }
    private func limitText(_ limit: APISpendLimitState?) -> String {
        switch limit {
        case .notConfigured: "未配置"
        case .configured(let amount, _): money(amount)
        case nil: "—"
        }
    }
    private func enforcementText(_ limit: APISpendLimitState?) -> String {
        switch limit {
        case .configured(_, true): "已启用硬限制"
        case .configured(_, false): "硬限制未生效"
        case .notConfigured: "组织未设置消费上限"
        case nil: "等待有效查询结果"
        }
    }
    private func utcDate(_ date: Date) -> String {
        var style = Date.FormatStyle.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
}

@MainActor
struct APIBillingSettingsView: View {
    var billing = APIBillingStore.shared
    @State private var keyText = ""
    @State private var feedback: String?

    var body: some View {
        Form {
            Section("OpenAI 官方 API") {
                LabeledContent("接口", value: "https://api.openai.com/v1")
                LabeledContent("密钥状态", value: billing.hasCredential ? "已存入本机钥匙串" : "尚未配置")
                SecureField("Admin API Key", text: $keyText, prompt: Text("输入新密钥以保存或替换"))
                    .autocorrectionDisabled()
                HStack {
                    Button("保存到钥匙串") { save(keyText) }.disabled(keyText.isEmpty)
                    Button("从文件导入…", systemImage: "doc") { importKey() }
                }
                Text("点击保存或导入，将把该密钥保存到此 Mac 的钥匙串。仅向 OpenAI 官方接口发送只读查询；不会上传会话正文。")
                    .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                if let message = feedback ?? billing.errorMessage {
                    Text(message).font(.caption).textSelection(.enabled)
                }
            }
            Section("查询权限与范围") {
                Text("费用与用量需要 api.usage.read；组织消费上限需要 api.management.read。请使用对应组织的 Admin API Key。")
                Text("在详情侧栏打开“API 用量与费用”时查询；5 分钟内复用当前结果，手动刷新立即查询。数据仅保存在内存中。")
                Link("创建 Admin API Key", destination: URL(string: "https://platform.openai.com/settings/organization/admin-keys")!)
                Link("查看充值余额", destination: URL(string: "https://platform.openai.com/settings/organization/billing/overview")!)
            }.font(.callout)
        }
        .formStyle(.grouped)
        .task { billing.checkCredential() }
    }

    private func save(_ text: String) {
        if billing.saveCredential(text) {
            keyText = ""
            feedback = "密钥已保存，可在“API 用量与费用”页面查询。"
        } else { feedback = billing.errorMessage }
    }

    private func importKey() {
        let panel = NSOpenPanel()
        panel.title = "导入 Admin API Key 到本机钥匙串"
        panel.message = "选择只含一个 API Key 的文本文件。密钥不会显示或写入应用安装包。"
        panel.allowedContentTypes = [.plainText]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16_384 else { throw APIBillingError.invalidKey }
            save(try String(contentsOf: url, encoding: .utf8))
        } catch { feedback = "无法从该文件导入密钥，请选择只含一个 API Key 的 UTF-8 文本文件。" }
    }
}
