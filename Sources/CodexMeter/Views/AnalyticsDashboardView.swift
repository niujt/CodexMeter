import SwiftUI

@MainActor
struct AnalyticsDashboardView: View {
    let store: UsageStore
    @Environment(\.openSettings) private var openSettings
    @State private var selectedSection = "健康报告"
    @State private var projectPathStore = ProjectPathStore()
    @AppStorage("codexMeter.appearance") private var appearance = AppAppearance.system.rawValue

    private var appearanceMode: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    var body: some View {
        HStack(spacing: 0) {
            DashboardSidebar(selection: $selectedSection, openSettings: { openSettings() })
            Divider().overlay(Color.primary.opacity(0.08))
            ScrollView {
                switch selectedSection {
                case "健康报告":
                    DashboardContent(store: store)
                        .padding(28)
                        .frame(minWidth: 900, maxWidth: 1_420)
                case "项目与用量":
                    ProjectsUsageView(store: store, pathStore: projectPathStore)
                case "使用趋势":
                    UsageTrendsView(store: store)
                case "模型与效率":
                    ModelEfficiencyView(store: store)
                case "预测与风险":
                    ForecastRiskView(store: store)
                case "历史记录":
                    HistoryRecordsView(store: store)
                default:
                    FeaturePlaceholderView(section: selectedSection)
                        .frame(minWidth: 900, minHeight: 600)
                }
            }
        }
        .background(DashboardPalette.background)
        .preferredColorScheme(appearanceMode.colorScheme)
        .navigationTitle("Codex Health")
        .task { await store.refresh() }
    }
}

private struct FeaturePlaceholderView: View {
    let section: String
    var body: some View {
        ContentUnavailableView(
            "\(section)正在实现",
            systemImage: "hammer.fill",
            description: Text("此页面不再展示模拟数据。下一步将按功能计划接入本机 Codex 记录。")
        )
        .foregroundStyle(.secondary)
    }
}

private struct HistoryRecordsView: View {
    let store: UsageStore
    @State private var range = HistoryRange.thirtyDays
    @State private var model = "全部"
    @State private var project = "全部"

    private var records: [UsageRecord] {
        let cutoff = Date.now.addingTimeInterval(-Double(range.days) * 86_400)
        return store.snapshot.recentRecords
            .filter { $0.date >= cutoff }
            .filter { model == "全部" || $0.model == model }
            .filter { project == "全部" || $0.project == project }
            .sorted { $0.date > $1.date }
    }
    private var models: [String] { ["全部"] + Array(Set(store.snapshot.recentRecords.map(\.model))).sorted() }
    private var projects: [String] { ["全部"] + Array(Set(store.snapshot.recentRecords.map(\.project))).sorted() }
    private var total: Int { records.reduce(0) { $0 + $1.tokens } }
    private var grouped: [(Date, [UsageRecord])] {
        let calendar = Calendar.current
        return Dictionary(grouping: records, by: { calendar.startOfDay(for: $0.date) })
            .sorted { $0.key > $1.key }
    }
    private var rateTimeline: [RateTimelineEvent] {
        let cutoff = Date.now.addingTimeInterval(-Double(range.days) * 86_400)
        return store.snapshot.rateTimeline.filter { $0.date >= cutoff }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "历史记录", subtitle: "仅保留本地会话的时间、模型、工作目录和 Token 汇总，不读取或展示会话正文。", store: store)
            HStack(spacing: 12) {
                Picker("范围", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).frame(width: 210)
                Picker("模型", selection: $model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 220)
                Picker("项目", selection: $project) {
                    ForEach(projects, id: \.self) { Text($0.isEmpty ? "未归属路径" : URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                }.frame(maxWidth: 220)
                Spacer()
                Text("\(records.count) 条 · \(UsageFormatters.tokens(total)) Token")
                    .foregroundStyle(.secondary)
            }
            if !rateTimeline.isEmpty {
                DashboardCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("7 天额度周期时间线", systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline)
                            Spacer()
                            Text("按重置周期合并 · 仅本机记录")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(rateTimeline.prefix(8).enumerated()), id: \.offset) { index, event in
                            ResetTimelineRow(event: event, isLatest: index == 0)
                        }
                    }
                }
            }
            if records.isEmpty {
                ContentUnavailableView("没有符合条件的本地记录", systemImage: "clock.badge.questionmark", description: Text("当前可浏览最近 30 天内已写入 Token 计数的会话记录。"))
                    .frame(maxWidth: .infinity, minHeight: 380)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(grouped, id: \.0) { day, dayRecords in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(day.formatted(.dateTime.year().month().day().weekday())).font(.headline)
                                Spacer()
                                Text(UsageFormatters.tokens(dayRecords.reduce(0) { $0 + $1.tokens })).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(dayRecords.enumerated()), id: \.offset) { _, record in
                                HistoryRecordRow(record: record)
                            }
                        }
                    }
                }
            }
        }
        .padding(28).frame(minWidth: 900, maxWidth: 1_420, alignment: .leading)
    }
}

private struct ResetTimelineRow: View {
    let event: RateTimelineEvent
    let isLatest: Bool

    private var used: Int { Int(event.usedPercent.rounded()) }
    private var remaining: Int { max(0, 100 - used) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isLatest ? "clock.arrow.circlepath" : "circle.fill")
                .font(.callout)
                .foregroundStyle(isLatest ? DashboardPalette.blue : .secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(isLatest ? "当前额度周期" : "已观察到的额度周期")
                    .font(.callout.weight(.semibold))
                Text("最近采样 \(event.date.formatted(.dateTime.month().day().hour().minute())) · 已用 \(used)% · 剩余 \(remaining)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("重置时间")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(event.resetsAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if !isLatest { Divider().opacity(0.45) }
        }
    }
}

private enum HistoryRange: Int, CaseIterable, Identifiable {
    case sevenDays = 7, thirtyDays = 30
    var id: Int { rawValue }
    var days: Int { rawValue }
    var title: String { self == .sevenDays ? "近 7 天" : "近 30 天" }
}

private struct HistoryRecordRow: View {
    let record: UsageRecord
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock").foregroundStyle(DashboardPalette.blue).frame(width: 20)
            Text(record.date.formatted(.dateTime.hour().minute()))
                .font(.callout.monospacedDigit()).frame(width: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.model).font(.callout.weight(.semibold)).lineLimit(1)
                Text(record.project.isEmpty ? "未归属工作目录" : record.project)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer()
            Text(UsageFormatters.tokens(record.tokens))
                .font(.callout.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct UsageTrendsView: View {
    let store: UsageStore
    @State private var granularity = TrendGranularity.daily

    private var points: [(Date, Int)] {
        switch granularity {
        case .daily:
            return store.snapshot.dailyUsage.map { ($0.date, $0.tokens) }
        case .hourly:
            let calendar = Calendar.current
            return Dictionary(grouping: store.snapshot.recentRecords.filter {
                $0.date >= .now.addingTimeInterval(-24 * 3_600)
            }, by: { calendar.dateInterval(of: .hour, for: $0.date)?.start ?? $0.date })
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.tokens }) }
            .sorted { $0.0 < $1.0 }
        }
    }

    private var total: Int { points.reduce(0) { $0 + $1.1 } }
    private var peak: Int { points.map(\.1).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "使用趋势", subtitle: "按会话记录的最后一条 Token 计数汇总。", store: store)
            HStack {
                Picker("粒度", selection: $granularity) {
                    ForEach(TrendGranularity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 200)
                Spacer()
                Text("总计 \(UsageFormatters.tokens(total)) Token")
                    .foregroundStyle(.secondary)
            }
            DashboardCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(granularity == .daily ? "近 7 天 Token 趋势" : "近 24 小时 Token 趋势").font(.headline)
                        Spacer()
                        Text("峰值 \(UsageFormatters.tokens(peak))").font(.caption).foregroundStyle(.secondary)
                    }
                    if points.isEmpty {
                        ContentUnavailableView("暂无趋势样本", systemImage: "chart.bar.xaxis")
                            .frame(maxWidth: .infinity, minHeight: 250)
                    } else {
                        TrendBars(points: points, hourly: granularity == .hourly)
                            .frame(height: 250)
                    }
                }
            }
            HStack(spacing: 16) {
                TrendMetric(title: "今天", value: UsageFormatters.tokens(store.snapshot.today.total), color: DashboardPalette.blue)
                TrendMetric(title: "近 7 天", value: UsageFormatters.tokens(store.snapshot.lastSevenDays.total), color: .purple)
                TrendMetric(title: "本月", value: UsageFormatters.tokens(store.snapshot.thisMonth.total), color: DashboardPalette.green)
            }
        }
        .padding(28).frame(minWidth: 900, maxWidth: 1_420, alignment: .leading)
    }
}

private enum TrendGranularity: String, CaseIterable, Identifiable {
    case daily, hourly
    var id: String { rawValue }
    var title: String { self == .daily ? "按天" : "近 24 小时" }
}

private struct TrendBars: View {
    let points: [(Date, Int)]
    let hourly: Bool
    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(1, points.map(\.1).max() ?? 1)
            HStack(alignment: .bottom, spacing: max(5, proxy.size.width / CGFloat(max(1, points.count)) * 0.16)) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    VStack(spacing: 7) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(LinearGradient(colors: [DashboardPalette.blue, .cyan], startPoint: .top, endPoint: .bottom))
                            .frame(height: max(5, proxy.size.height * 0.78 * CGFloat(point.1) / CGFloat(maxValue)))
                        Text(point.0.formatted(hourly ? .dateTime.hour() : .dateTime.month().day()))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .help("\(point.0.formatted(date: .abbreviated, time: .shortened))：\(UsageFormatters.tokens(point.1)) Token")
                }
            }
        }
    }
}

private struct TrendMetric: View {
    let title: String; let value: String; let color: Color
    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.bold)).foregroundStyle(color).monospacedDigit()
                Text("Token 消耗").font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity)
    }
}

private struct ModelEfficiencyView: View {
    let store: UsageStore
    private var total: Int { store.snapshot.topModels.reduce(0) { $0 + $1.tokens } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "模型与效率", subtitle: "请求次数和平均响应时长来自本地会话，不等同于服务端网络延迟。", store: store)
            if store.snapshot.topModels.isEmpty {
                ContentUnavailableView("暂无模型样本", systemImage: "cpu")
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                VStack(spacing: 12) {
                    ForEach(store.snapshot.topModels, id: \.name) { model in
                        DashboardCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "cpu.fill").foregroundStyle(DashboardPalette.blue)
                                    Text(model.name).font(.headline).lineLimit(1)
                                    Spacer()
                                    Text("\(Int(Double(model.tokens) / Double(max(1, total)) * 100))% 占比")
                                        .font(.callout.weight(.semibold)).foregroundStyle(DashboardPalette.green)
                                }
                                ProgressView(value: Double(model.tokens), total: Double(max(1, total))).tint(DashboardPalette.blue)
                                HStack {
                                    ModelMetric(label: "Token", value: UsageFormatters.tokens(model.tokens))
                                    ModelMetric(label: "请求次数", value: "\(model.requests) 次")
                                    ModelMetric(label: "平均响应", value: model.averageTurnSeconds.map { UsageFormatters.turnDuration(seconds: $0) } ?? "样本不足")
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(28).frame(minWidth: 900, maxWidth: 1_420, alignment: .leading)
    }
}

private struct ModelMetric: View {
    let label: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ForecastRiskView: View {
    let store: UsageStore
    private var rate: RateWindow? { store.snapshot.sevenDayRate }
    private var remaining: Int { max(0, 100 - Int((rate?.usedPercent ?? 0).rounded())) }
    private var resetHours: Double? { rate.map { max(0, $0.resetsAt.timeIntervalSinceNow / 3_600) } }
    private var hourlyRate: Double? {
        guard let rate, let resetHours else { return nil }
        return RateHistory.weightedVelocity()?.percentPerHour
            ?? rate.usedPercent / max(0.1, Double(rate.windowMinutes) / 60 - resetHours)
    }
    private var remainingHours: Double? {
        guard let hourlyRate, hourlyRate > 0 else { return nil }
        return Double(remaining) / hourlyRate
    }
    private var willExhaust: Bool { (remainingHours ?? .infinity) < (resetHours ?? 0) }
    private var color: Color { remaining < 20 ? .red : remaining < 50 ? DashboardPalette.orange : DashboardPalette.green }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "预测与风险", subtitle: "预测按 1 / 6 / 24 小时额度变化加权；没有足够样本时使用本周期平均速度。", store: store)
            if let rate {
                HStack(spacing: 16) {
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("7 天额度").font(.headline)
                            Text("剩余 \(remaining)%").font(.system(size: 48, weight: .bold, design: .rounded)).foregroundStyle(color)
                            ProgressView(value: Double(remaining), total: 100).tint(color)
                            Text("约 \(UsageFormatters.countdown(to: rate.resetsAt)) 后重置").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity)
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("续航预测").font(.headline)
                            Text(remainingHours.map { UsageFormatters.duration(hours: $0) } ?? "样本不足")
                                .font(.system(size: 38, weight: .bold, design: .rounded)).foregroundStyle(color)
                            Text(remainingHours == nil ? "继续使用一段时间后会形成预测" : (willExhaust ? "可能在重置前耗尽" : "预计可支撑到重置"))
                                .foregroundStyle(willExhaust ? .orange : DashboardPalette.green)
                            Text("当前平均消耗 \(hourlyRate.map { String(format: "%.2f%% / 小时", $0) } ?? "—")").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity)
                }
                DashboardCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("风险说明").font(.headline)
                        RiskLine(icon: willExhaust ? "exclamationmark.triangle.fill" : "checkmark.shield.fill", color: willExhaust ? .orange : DashboardPalette.green, title: willExhaust ? "提前耗尽风险" : "额度状态健康", detail: willExhaust ? "按当前消耗速度，建议降低并发或等待额度重置。" : "按当前速度不会在下一次重置前耗尽。")
                        RiskLine(icon: "clock.arrow.circlepath", color: DashboardPalette.blue, title: "下次重置", detail: rate.resetsAt.formatted(.dateTime.year().month().day().hour().minute()))
                        RiskLine(icon: "chart.line.uptrend.xyaxis", color: .purple, title: "估算依据", detail: RateHistory.weightedVelocity().map { "已使用近 \($0.description) 小时的额度变化样本。" } ?? "暂无连续变化样本，已使用本周期平均速度。")
                    }
                }
            } else {
                ContentUnavailableView("等待新周期数据", systemImage: "scope", description: Text("完成一次含额度信息的 Codex 会话后即可开始预测。"))
                    .frame(maxWidth: .infinity, minHeight: 420)
            }
        }
        .padding(28).frame(minWidth: 900, maxWidth: 1_420, alignment: .leading)
    }
}

private struct RiskLine: View {
    let icon: String; let color: Color; let title: String; let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PageHeader: View {
    let title: String; let subtitle: String; let store: UsageStore
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 30, weight: .bold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await store.refresh(force: true) } } label: { Label("立即刷新", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered).disabled(store.isRefreshing)
        }
    }
}

private enum DashboardPalette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .underPageBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let blue = Color(red: 0.17, green: 0.48, blue: 1.0)
    static let green = Color(red: 0.24, green: 0.84, blue: 0.46)
    static let orange = Color(red: 1.0, green: 0.58, blue: 0.16)
}

private struct DashboardSidebar: View {
    @Binding var selection: String
    let openSettings: () -> Void
    @AppStorage("codexMeter.appearance") private var appearance = AppAppearance.system.rawValue
    private let items: [(String, String)] = [
        ("健康报告", "house.fill"),
        ("使用趋势", "chart.xyaxis.line"),
        ("模型与效率", "cpu"),
        ("项目与用量", "folder"),
        ("预测与风险", "scope"),
        ("历史记录", "clock")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 12) {
                Image("CodexHealthMark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 78, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                Text("Codex Health").font(.title3.weight(.bold))
                Text("Battery for Codex")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)

            ForEach(items, id: \.0) { item in
                Button { selection = item.0 } label: {
                    Label(item.0, systemImage: item.1)
                        .font(.callout.weight(selection == item.0 ? .semibold : .regular))
                        .foregroundStyle(selection == item.0 ? .white : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(selection == item.0 ? DashboardPalette.blue.opacity(0.22) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 6) {
                Label("本地优先", systemImage: "lock.shield")
                    .font(.callout.weight(.semibold))
                Text("不上传会话或用量数据")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            HStack {
                Text("v1.0.5")
                Spacer()
                Menu {
                    ForEach(AppAppearance.allCases) { mode in
                        Button {
                            appearance = mode.rawValue
                        } label: {
                            Label(mode.title, systemImage: appearance == mode.rawValue ? "checkmark" : mode.icon)
                        }
                    }
                } label: {
                    Image(systemName: (AppAppearance(rawValue: appearance) ?? .system).icon)
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("切换显示模式")
                Button(action: openSettings) {
                    Image(systemName: "gearshape").font(.title3)
                }
                .buttonStyle(.plain)
                .help("偏好设置")
            }
            .font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
        .padding(16)
        .padding(.top, 18)
        .frame(width: 220)
        .background(DashboardPalette.surface)
    }
}

private struct DashboardContent: View {
    let store: UsageStore

    private var rate: RateWindow? { store.snapshot.sevenDayRate }
    private var remaining: Int? { rate.map { max(0, 100 - Int($0.usedPercent.rounded())) } }
    private var sparkRemaining: Int? {
        store.snapshot.sparkRate.map { max(0, 100 - Int($0.usedPercent.rounded())) }
    }
    private var quotaColor: Color {
        guard let remaining else { return DashboardPalette.blue }
        return remaining < 20 ? .red : remaining < 50 ? DashboardPalette.orange : DashboardPalette.green
    }
    private var status: String {
        guard let remaining else { return store.isRefreshing ? "读取中" : "等待新周期数据" }
        return remaining < 20 ? "Critical" : remaining < 50 ? "Watch" : "Healthy"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("健康报告").font(.system(size: 30, weight: .bold))
                    Text(store.snapshot.lastUpdated.map { "最后更新：\($0.formatted(.relative(presentation: .named)))" } ?? "正在读取本机 Codex 记录")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if store.snapshot.mainRateIsCached || store.snapshot.sparkRateIsCached {
                        Label("部分额度来自本地有效缓存，获取到新采样后会自动替换", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { Task { await store.refresh(force: true) } } label: {
                    Label("立即刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(store.isRefreshing)
            }

            HStack(spacing: 16) {
                HealthHero(
                    remaining: remaining,
                    sparkRemaining: sparkRemaining,
                    sparkIsCached: store.snapshot.sparkRateIsCached,
                    status: status,
                    color: quotaColor,
                    rate: rate
                )
                TodayOverview(snapshot: store.snapshot)
            }

            HStack(alignment: .top, spacing: 16) {
                UsageTrendCard(snapshot: store.snapshot, remaining: remaining)
                RiskCard(rate: rate, remaining: remaining, color: quotaColor)
            }

            HStack(alignment: .top, spacing: 16) {
                ModelCard(models: store.snapshot.topModels, weeklyTotal: store.snapshot.lastSevenDays.total)
                MetricsCard(snapshot: store.snapshot, color: quotaColor)
                ProjectCard(projects: store.snapshot.topProjects, total: store.snapshot.lastSevenDays.total)
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if store.snapshot.fileCount == 0 && !store.isRefreshing {
                Button("选择 Codex 数据目录…") { store.chooseCodexFolder() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct DashboardCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content.padding(22)
            .background(DashboardPalette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.07)))
    }
}

private struct HealthHero: View {
    let remaining: Int?
    let sparkRemaining: Int?
    let sparkIsCached: Bool
    let status: String
    let color: Color
    let rate: RateWindow?
    var body: some View {
        DashboardCard {
            HStack(spacing: 26) {
                ZStack(alignment: .bottomTrailing) {
                    Text(remaining.map { "\($0)%" } ?? "等待新周期数据")
                        .font(.system(size: remaining == nil ? 25 : 78, weight: .bold, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [.blue, color], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .monospacedDigit()
                        .lineLimit(remaining == nil ? 2 : 1)
                        .minimumScaleFactor(remaining == nil ? 0.6 : 0.7)
                        .frame(width: 210, alignment: .leading)
                    if let sparkRemaining {
                        Text("Spark \(sparkRemaining)%")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(DashboardPalette.orange, in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.16)))
                            .offset(x: -4, y: 7)
                            .help(sparkIsCached ? "Spark 额度来自本地有效缓存" : "Spark 最新额度")
                    }
                }
                Divider().overlay(.primary.opacity(0.14)).frame(height: 110)
                VStack(alignment: .leading, spacing: 10) {
                    Label(status, systemImage: "circle.fill")
                        .font(.title2.weight(.bold)).foregroundStyle(color)
                    Text(rate == nil ? "等待新周期数据" : "状态良好，当前使用速度可持续")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let rate {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Remaining")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("约 \(UsageFormatters.countdown(to: rate.resetsAt))")
                                .font(.callout.weight(.semibold))
                            ProgressView(value: Double(remaining ?? 0), total: 100)
                                .tint(color)
                                .frame(width: 150)
                        }
                    } else {
                        Text("等待新周期数据")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 550)
        .frame(maxWidth: .infinity)
    }
}

private struct TodayOverview: View {
    let snapshot: UsageSnapshot
    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 13) {
                Text("今日使用概览").font(.headline)
                OverviewRow("今日消耗", snapshot.today.total, "waveform.path.ecg", .blue)
                Divider().overlay(.primary.opacity(0.08))
                OverviewRow("近 7 天消耗", snapshot.lastSevenDays.total, "chart.bar.fill", .purple)
                Divider().overlay(.primary.opacity(0.08))
                OverviewRow("本月消耗", snapshot.thisMonth.total, "calendar", DashboardPalette.green)
            }
        }
        .frame(width: 310)
    }
}

private struct OverviewRow: View {
    let title: String; let value: Int; let icon: String; let color: Color
    init(_ title: String, _ value: Int, _ icon: String, _ color: Color) { self.title = title; self.value = value; self.icon = icon; self.color = color }
    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 22)
            Text(title).foregroundStyle(.secondary)
            Spacer(); Text(UsageFormatters.tokens(value)).font(.headline).monospacedDigit()
        }
    }
}

private struct UsageTrendCard: View {
    let snapshot: UsageSnapshot; let remaining: Int?
    private var points: [Double] {
        let sorted = snapshot.dailyUsage.sorted { $0.date < $1.date }.suffix(7)
        let maxValue = max(1, sorted.map(\.tokens).max() ?? 1)
        return sorted.map { Double($0.tokens) / Double(maxValue) }
    }
    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("使用趋势").font(.headline); Spacer(); Text("近 7 天").font(.caption).foregroundStyle(.secondary) }
                GeometryReader { proxy in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    Path { path in
                        guard points.count > 1 else { return }
                        for (index, point) in points.enumerated() {
                            let x = width * CGFloat(index) / CGFloat(points.count - 1)
                            let y = height * (1 - CGFloat(point) * 0.78 - 0.08)
                            index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    .stroke(DashboardPalette.blue, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .overlay(alignment: .bottomLeading) {
                        LinearGradient(colors: [DashboardPalette.blue.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom)
                            .mask(Path { path in
                                guard points.count > 1 else { return }
                                path.move(to: CGPoint(x: 0, y: height))
                                for (index, point) in points.enumerated() {
                                    let x = width * CGFloat(index) / CGFloat(points.count - 1)
                                    let y = height * (1 - CGFloat(point) * 0.78 - 0.08)
                                    path.addLine(to: CGPoint(x: x, y: y))
                                }
                                path.addLine(to: CGPoint(x: width, y: height)); path.closeSubpath()
                            })
                    }
                }
                .frame(height: 100)
                HStack {
                    Text("Token 用量按日汇总")
                    Spacer()
                    Text(remaining.map { "剩余 \($0)%" } ?? "等待新周期数据")
                }
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RiskCard: View {
    let rate: RateWindow?; let remaining: Int?; let color: Color

    private var resetHours: Double? {
        rate.map { max(0, $0.resetsAt.timeIntervalSinceNow / 3_600) }
    }

    private var estimatedRemainingHours: Double? {
        guard let rate, let resetHours, let remaining else { return nil }
        let elapsedHours = max(0.1, Double(rate.windowMinutes) / 60 - resetHours)
        let percentPerHour = RateHistory.weightedVelocity()?.percentPerHour
            ?? rate.usedPercent / elapsedHours
        guard percentPerHour > 0 else { return nil }
        return Double(remaining) / percentPerHour
    }

    private var remainingTimeText: String? {
        estimatedRemainingHours.map { "按当前速度，约还能用 \(UsageFormatters.duration(hours: $0))" }
    }

    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 15) {
                Text("预测与风险").font(.headline)
                HStack {
                    Spacer()
                    Image(systemName: remaining.map { $0 < 20 ? "exclamationmark.shield.fill" : "checkmark.shield.fill" } ?? "hourglass")
                        .font(.system(size: 42)).foregroundStyle(color)
                    Spacer()
                }
                Text(remaining.map { $0 < 20 ? "RISK" : "SAFE" } ?? "WAITING")
                    .font(.system(size: 28, weight: .bold)).foregroundStyle(color).frame(maxWidth: .infinity)
                if let estimatedRemainingHours, let resetHours, let remainingTimeText {
                    VStack(spacing: 4) {
                        Text(remainingTimeText)
                            .font(.callout.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(estimatedRemainingHours < resetHours ? "可能在额度重置前耗尽" : "预计可支撑到额度重置")
                            .font(.caption)
                            .foregroundStyle(estimatedRemainingHours < resetHours ? .orange : DashboardPalette.green)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Text("等待新周期数据")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                Text(rate.map { "预计额度将于 \($0.resetsAt.formatted(.dateTime.month().day().hour().minute())) 重置" } ?? "等待新周期数据")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
        }
        .frame(width: 260)
    }
}

private struct ModelCard: View {
    let models: [ModelUsage]; let weeklyTotal: Int
    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("模型与效率").font(.headline)
                if models.isEmpty { Text("等待模型统计数据").foregroundStyle(.secondary) }
                ForEach(models.prefix(3), id: \.name) { model in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(model.name).lineLimit(1); Spacer(); Text("\(model.requests) 次").foregroundStyle(.secondary) }
                        ProgressView(value: Double(model.tokens), total: Double(max(1, weeklyTotal))).tint(DashboardPalette.green)
                        Text("\(UsageFormatters.tokens(model.tokens)) · \(model.averageTurnSeconds.map { "平均 \(UsageFormatters.turnDuration(seconds: $0))" } ?? "等待耗时")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.frame(maxWidth: .infinity)
    }
}

private struct MetricsCard: View {
    let snapshot: UsageSnapshot; let color: Color
    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 13) {
                Text("关键指标").font(.headline)
                MetricRow("当前会话上下文", snapshot.contextWindow > 0 ? "\(UsageFormatters.tokens(snapshot.currentContextUsed)) / \(UsageFormatters.tokens(snapshot.contextWindow))" : "暂无", color)
                MetricRow("会话记录", "\(snapshot.sessionCount) 个", DashboardPalette.blue)
                MetricRow("输入 / 输出", "\(UsageFormatters.tokens(snapshot.today.input)) / \(UsageFormatters.tokens(snapshot.today.output))", .purple)
            }
        }.frame(maxWidth: .infinity)
    }
}

private struct MetricRow: View {
    let title: String; let value: String; let color: Color
    init(_ title: String, _ value: String, _ color: Color) { self.title = title; self.value = value; self.color = color }
    var body: some View { VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.callout.weight(.semibold)).foregroundStyle(color).lineLimit(1) } }
}

private struct ProjectCard: View {
    let projects: [ProjectUsage]; let total: Int
    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("活跃项目").font(.headline)
                if projects.isEmpty { Text("等待项目统计数据").foregroundStyle(.secondary) }
                ForEach(projects.prefix(4), id: \.name) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(DashboardPalette.green)
                        Text(item.name).lineLimit(1)
                        Spacer()
                        Text("\(Int(Double(item.tokens) / Double(max(1, total)) * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }
        }.frame(maxWidth: .infinity)
    }
}
