import SwiftUI

@MainActor
struct AnalyticsDashboardView: View {
    let store: UsageStore
    @Environment(\.openSettings) private var openSettings
    @State private var selectedSection: String? = "健康报告"
    @State private var projectPathStore = ProjectPathStore()
    @AppStorage("codexMeter.appearance") private var appearance = AppAppearance.system.rawValue

    private var appearanceMode: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(selection: $selectedSection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            ScrollView {
                switch selectedSection ?? "健康报告" {
                case "健康报告":
                    DashboardContent(
                        snapshot: store.snapshot,
                        errorMessage: store.errorMessage,
                        isRefreshing: store.isRefreshing,
                        measuredVelocity: RateHistory.weightedVelocity()?.percentPerHour,
                        chooseFolder: { store.chooseCodexFolder() }
                    )
                        .padding(28)
                        .frame(maxWidth: 1_100, alignment: .leading)
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
                    FeaturePlaceholderView(section: selectedSection ?? "健康报告")
                        .frame(minHeight: 500)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.isRefreshing {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(store.loadingMessage)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.primary)
        .progressViewStyle(FlatProgressStyle())
        .preferredColorScheme(appearanceMode.colorScheme)
        .navigationTitle("Codex Health")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await store.refresh() } } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
                .help("刷新本机用量")
                Menu {
                    ForEach(AppAppearance.allCases) { mode in
                        Button { appearance = mode.rawValue } label: {
                            Label(mode.title, systemImage: appearance == mode.rawValue ? "checkmark" : mode.icon)
                        }
                    }
                } label: {
                    Label("外观", systemImage: appearanceMode.icon)
                }
                Button { openSettings() } label: { Label("设置", systemImage: "gearshape") }
            }
        }
        .task { await store.refreshIfNeeded() }
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
            PageHeader(title: "历史记录", subtitle: "按小时、模型和工作目录汇总 Token 增量，不保存或展示会话正文。", store: store)
            DashboardCard {
                ResetHistoryView(codexPath: store.selectedCodexPath)
            }
            HStack(spacing: 12) {
                Picker("范围", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
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
                LazyVStack(alignment: .leading, spacing: 18) {
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
        .padding(28).frame(maxWidth: 1_100, alignment: .leading)
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
                .foregroundStyle(isLatest ? DashboardPalette.ink : .secondary)
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
            if !isLatest { FlatDivider().opacity(0.45) }
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
            Image(systemName: "clock").foregroundStyle(DashboardPalette.ink).frame(width: 20)
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
        .overlay(alignment: .bottom) { FlatDivider() }
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
            PageHeader(title: "使用趋势", subtitle: "按 Token 计数增量归属实际发生的日期和小时。", store: store)
            HStack {
                Picker("粒度", selection: $granularity) {
                    ForEach(TrendGranularity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
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
                TrendMetric(title: "今天", value: UsageFormatters.tokens(store.snapshot.today.total))
                TrendMetric(title: "近 7 天", value: UsageFormatters.tokens(store.snapshot.lastSevenDays.total))
                TrendMetric(title: "本月", value: UsageFormatters.tokens(store.snapshot.thisMonth.total))
            }
        }
        .padding(28).frame(maxWidth: 1_100, alignment: .leading)
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
                        Text(UsageFormatters.tokens(point.1))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(DashboardPalette.ink.opacity(0.8))
                            .frame(width: min(32, proxy.size.width / CGFloat(max(1, points.count)) * 0.5),
                                   height: max(3, proxy.size.height * 0.65 * CGFloat(point.1) / CGFloat(maxValue)))
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
    let title: String; let value: String
    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.medium)).foregroundStyle(.primary).monospacedDigit()
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
            PageHeader(title: "模型与效率", subtitle: "有效轮次仅统计可配对的用户消息与最终回答；耗时为端到端时长。", store: store)
            if store.snapshot.topModels.isEmpty {
                ContentUnavailableView("暂无模型样本", systemImage: "cpu")
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                VStack(spacing: 12) {
                    ForEach(store.snapshot.topModels, id: \.name) { model in
                        DashboardCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "cpu.fill").foregroundStyle(DashboardPalette.ink)
                                    Text(model.name).font(.headline).lineLimit(1)
                                    Spacer()
                                    Text("\(Int(Double(model.tokens) / Double(max(1, total)) * 100))% 占比")
                                        .font(.callout.weight(.semibold)).foregroundStyle(DashboardPalette.ink)
                                }
                                ProgressView(value: Double(model.tokens), total: Double(max(1, total))).tint(DashboardPalette.ink)
                                HStack {
                                    ModelMetric(label: "Token", value: UsageFormatters.tokens(model.tokens))
                                    ModelMetric(label: "有效轮次", value: "\(model.requests) 次")
                                    ModelMetric(label: "平均轮次耗时", value: model.averageTurnSeconds.map { UsageFormatters.turnDuration(seconds: $0) } ?? "样本不足")
                                    ModelMetric(label: "缓存命中率", value: model.cacheHitRate.map(UsageFormatters.percentage) ?? "样本不足")
                                        .help("缓存命中率 = cached_input_tokens / input_tokens")
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(28).frame(maxWidth: 1_100, alignment: .leading)
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
        QuotaHealth.velocity(rate: rate, measured: RateHistory.weightedVelocity()?.percentPerHour)
    }
    private var remainingHours: Double? {
        guard let hourlyRate, hourlyRate > 0 else { return nil }
        return Double(remaining) / hourlyRate
    }
    private var willExhaust: Bool { (remainingHours ?? .infinity) < (resetHours ?? 0) }
    private var health: QuotaHealth { .evaluate(rate: rate, percentPerHour: hourlyRate) }
    private var color: Color { health.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "预测与风险", subtitle: "预测按 1 / 6 / 24 小时额度变化加权；没有足够样本时使用本周期平均速度。", store: store)
            if let rate {
                HStack(spacing: 16) {
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("7 天额度").font(.headline)
                            Text("剩余 \(remaining)%").font(.system(size: 36, weight: .medium)).foregroundStyle(color)
                            ProgressView(value: Double(remaining), total: 100).tint(color)
                            Text("约 \(UsageFormatters.countdown(to: rate.resetsAt)) 后重置").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity)
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("续航预测").font(.headline)
                            Text(remainingHours.map { UsageFormatters.duration(hours: $0) } ?? "样本不足")
                                .font(.system(size: 32, weight: .medium)).foregroundStyle(color)
                            Text(remainingHours == nil ? "继续使用一段时间后会形成预测" : (willExhaust ? "可能在重置前耗尽" : "预计可支撑到重置"))
                                .foregroundStyle(.primary)
                            Text("当前平均消耗 \(hourlyRate.map { String(format: "%.2f%% / 小时", $0) } ?? "—")").font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity)
                }
                DashboardCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("风险说明").font(.headline)
                        RiskLine(icon: health.icon, color: health.color, title: health.title, detail: health.detail)
                        RiskLine(icon: "clock.arrow.circlepath", color: DashboardPalette.ink, title: "下次重置", detail: rate.resetsAt.formatted(.dateTime.year().month().day().hour().minute()))
                        RiskLine(icon: "chart.line.uptrend.xyaxis", color: .secondary, title: "估算依据", detail: RateHistory.weightedVelocity().map { "已使用近 \($0.description) 小时的额度变化样本。" } ?? "暂无连续变化样本，已使用本周期平均速度。")
                    }
                }
            } else {
                ContentUnavailableView("等待新周期数据", systemImage: "scope", description: Text("完成一次含额度信息的 Codex 会话后即可开始预测。"))
                    .frame(maxWidth: .infinity, minHeight: 420)
            }
        }
        .padding(28).frame(maxWidth: 1_100, alignment: .leading)
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
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

private enum DashboardPalette {
    static let ink = Color.primary
}

private struct DashboardSidebar: View {
    @Binding var selection: String?
    private let items: [(String, String)] = [
        ("健康报告", "house"),
        ("使用趋势", "chart.xyaxis.line"),
        ("模型与效率", "cpu"),
        ("项目与用量", "folder"),
        ("预测与风险", "scope"),
        ("历史记录", "clock")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("用量")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 4)
                ForEach(Array(items.enumerated()), id: \.element.0) { index, item in
                    Button { selection = item.0 } label: {
                        Label(item.0, systemImage: item.1)
                            .font(.callout.weight(selection == item.0 ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .background(.primary.opacity(selection == item.0 ? 0.08 : 0),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .help("\(item.0) · ⌘\(index + 1)")
                    .accessibilityAddTraits(selection == item.0 ? .isSelected : [])
                }
            }
            Spacer(minLength: 0)
            Label("本机统计", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DashboardContent: View {
    let snapshot: UsageSnapshot
    let errorMessage: String?
    let isRefreshing: Bool
    let measuredVelocity: Double?
    let chooseFolder: () -> Void

    private var rate: RateWindow? { snapshot.sevenDayRate }
    private var remaining: Int? { rate.map { max(0, 100 - Int($0.usedPercent.rounded())) } }
    private var health: QuotaHealth {
        .evaluate(rate: rate, percentPerHour: QuotaHealth.velocity(rate: rate, measured: measuredVelocity))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("健康报告").font(.system(size: 24, weight: .semibold))
                    Text(snapshot.lastUpdated.map { "更新于 \($0.formatted(.relative(presentation: .named)))" } ?? "等待本机用量")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(health.title, systemImage: health.icon)
                    .font(.caption).foregroundStyle(health.color)
                    .help(health.detail)
            }

            HStack(alignment: .top, spacing: 20) {
                QuotaSummary(snapshot: snapshot, rate: rate, remaining: remaining, color: health.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SummaryMetric(
                    title: "今日用量", value: UsageFormatters.tokens(snapshot.today.total),
                    detail: "输入 \(UsageFormatters.tokens(snapshot.today.input)) · 输出 \(UsageFormatters.tokens(snapshot.today.output))"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                SummaryMetric(
                    title: "近 7 天用量", value: UsageFormatters.tokens(snapshot.lastSevenDays.total),
                    detail: "Token 累计消耗"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                ReplySpeedView(samples: snapshot.replySpeedSamples, layout: .metric)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)

            Divider()
            UsageTrendCard(snapshot: snapshot)
            Divider()

            HStack(alignment: .top, spacing: 32) {
                ModelCard(models: snapshot.topModels, weeklyTotal: snapshot.lastSevenDays.total)
                ProjectCard(projects: snapshot.topProjects, total: snapshot.lastSevenDays.total)
            }
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            MetricsCard(snapshot: snapshot)

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.fileCount == 0 && !isRefreshing {
                Button("选择 Codex 数据目录…", action: chooseFolder)
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// A flat section shared by the analysis pages; spacing and a rule provide hierarchy.
private struct DashboardCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
            .overlay(alignment: .bottom) { FlatDivider() }
    }
}

private struct QuotaSummary: View {
    let snapshot: UsageSnapshot
    let rate: RateWindow?
    let remaining: Int?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("7 天剩余额度").font(.caption).foregroundStyle(.secondary)
            Text(remaining.map { "\($0)%" } ?? "—")
                .font(.system(size: 28, weight: .medium)).monospacedDigit()
            if let remaining { ProgressView(value: Double(remaining), total: 100).tint(color).frame(maxWidth: 180) }
            Text(rate.map { "\(UsageFormatters.countdown(to: $0.resetsAt))后重置" } ?? "等待新周期数据")
                .font(.caption).foregroundStyle(.secondary)
            if let spark = snapshot.sparkRate {
                Text("Spark 剩余 \(max(0, 100 - Int(spark.usedPercent.rounded())))%")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help(snapshot.sparkRateIsCached ? "Spark 额度来自本地有效缓存" : "Spark 最新额度")
            }
            if snapshot.mainRateIsCached || snapshot.sparkRateIsCached {
                Label("缓存额度", systemImage: "clock.arrow.circlepath")
                    .font(.caption2).foregroundStyle(.secondary)
                    .help("部分额度来自本地有效缓存，获取到新采样后会自动替换")
            }
        }
    }
}

private struct SummaryMetric: View {
    let title: String
    let value: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .medium)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct UsageTrendCard: View {
    let snapshot: UsageSnapshot
    private var days: [DailyUsage] { snapshot.dailyUsage.sorted { $0.date < $1.date }.suffix(7) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("使用趋势").font(.callout.weight(.semibold))
                Spacer()
                Text("近 7 天 · Token").font(.caption).foregroundStyle(.secondary)
            }
            if days.isEmpty {
                ContentUnavailableView("暂无趋势样本", systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                TrendBars(points: days.map { ($0.date, $0.tokens) }, hourly: false)
                    .frame(height: 140)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ModelCard: View {
    let models: [ModelUsage]
    let weeklyTotal: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("模型与效率").font(.callout.weight(.semibold))
                Spacer()
                Text("近 7 天").font(.caption).foregroundStyle(.secondary)
            }
            if models.isEmpty { Text("暂无模型记录").font(.caption).foregroundStyle(.secondary) }
            ForEach(models.prefix(3), id: \.name) { model in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.name).lineLimit(1)
                        Spacer()
                        Text(UsageFormatters.tokens(model.tokens)).monospacedDigit()
                    }.font(.callout)
                    ProgressView(value: Double(model.tokens), total: Double(max(1, weeklyTotal))).tint(DashboardPalette.ink)
                    Text("\(model.requests) 个有效轮次 · \(model.averageTurnSeconds.map { "平均 \(UsageFormatters.turnDuration(seconds: $0))" } ?? "暂无耗时样本")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct MetricsCard: View {
    let snapshot: UsageSnapshot
    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            MetricRow("本机记录", "\(snapshot.fileCount) 个文件")
            MetricRow("本月用量", UsageFormatters.tokens(snapshot.thisMonth.total))
            MetricRow("当前上下文", snapshot.contextWindow > 0 ? "\(UsageFormatters.tokens(snapshot.currentContextUsed)) / \(UsageFormatters.tokens(snapshot.contextWindow))" : "暂无")
            MetricRow("会话", "\(snapshot.sessionCount) 个")
        }
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProjectCard: View {
    let projects: [ProjectUsage]
    let total: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("活跃项目").font(.callout.weight(.semibold))
                Spacer()
                Text("近 7 天").font(.caption).foregroundStyle(.secondary)
            }
            if projects.isEmpty { Text("暂无项目记录").font(.caption).foregroundStyle(.secondary) }
            ForEach(projects.prefix(4), id: \.path) { item in
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text("\(Int(Double(item.tokens) / Double(max(1, total)) * 100))%")
                        .monospacedDigit().foregroundStyle(.secondary)
                }.font(.callout)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private extension QuotaHealth {
    var color: Color {
        switch self {
        case .waiting, .insufficient: .secondary
        case .critical: .primary
        case .watch: .secondary
        case .healthy: DashboardPalette.ink
        }
    }
    var icon: String {
        switch self {
        case .waiting, .insufficient: "hourglass"
        case .critical, .watch: "exclamationmark.shield.fill"
        case .healthy: "checkmark.shield.fill"
        }
    }
}

/// Draws determinate progress in gray with the native value semantics intact.
struct FlatProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        if let fraction = configuration.fractionCompleted {
            VStack(alignment: .leading, spacing: 6) {
                configuration.label
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.primary.opacity(0.1))
                        Rectangle().fill(.primary.opacity(0.75))
                            .frame(width: proxy.size.width * min(1, max(0, fraction)))
                    }
                }
                .frame(height: 3)
                configuration.currentValueLabel
            }
        } else {
            VStack(spacing: 6) {
                configuration.label
                ProgressView().progressViewStyle(.circular)
                configuration.currentValueLabel
            }
        }
    }
}


struct FlatDivider: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
    }
}
