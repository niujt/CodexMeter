import SwiftUI

struct UsagePopoverView: View {
    let store: UsageStore
    let permissionStore: PermissionStore
    let compact: Bool
    var isVisible = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @State private var projectRange = 1
    @AppStorage("codexMeter.lowRateThreshold") private var lowRateThreshold = 20
    @AppStorage("codexMeter.deduplicateAlerts") private var deduplicateAlerts = true
    @AppStorage(AppIconStyle.preferenceKey) private var iconStyle = AppIconStyle.flat.rawValue
    @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        TimelineView(.explicit([Date.now] + store.snapshot.quotaDisplayDeadlines)) { _ in content }
    }

    private var content: some View {
        Group {
            if compact {
                HealthMenuPopover(store: store, permissionStore: permissionStore, isVisible: isVisible)
            } else {
                detailedContent
            }
        }
        .safeAreaInset(edge: .top) {
            if !compact, store.isRefreshing {
                ProgressView(store.loadingMessage)
                    .controlSize(.small)
                    .padding(10)
            }
        }
        .foregroundStyle(DashboardPalette.ink)
        .tint(DashboardPalette.ink)
        .progressViewStyle(FlatProgressStyle())
        .background {
            if compact { DashboardPalette.popoverBackground }
        }
        .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme)
        .task(id: isVisible) {
            guard isVisible else { return }
            await store.refreshIfNeeded()
        }
    }

    private var detailedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                if compact, let rate = store.snapshot.currentSevenDayRate() {
                    let remaining = max(0, 100 - Int(rate.usedPercent.rounded()))
                    let color = DashboardPalette.ink
                    Image((AppIconStyle(rawValue: iconStyle) ?? .flat).assetName(for: colorScheme))
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .foregroundStyle(color)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Codex Health").font(.headline)
                        Text("7 天额度 · 剩余 \(remaining)%")
                            .font(.caption).foregroundStyle(color)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex Health").font(.headline)
                        Text("本机记录").font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                    }
                }
                Spacer()
                Button {
                    Task { await store.refresh(userInitiated: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).disabled(store.isRefreshing).help("刷新")
            }

            if !compact { HStack(spacing: 10) {
                UsageCard(title: "今天", value: store.snapshot.today.total)
                UsageCard(title: "近 7 天", value: store.snapshot.lastSevenDays.total)
                UsageCard(title: "本月", value: store.snapshot.thisMonth.total)
            }}

            ReplySpeedView(samples: store.snapshot.replySpeedSamples)

            if !compact, store.snapshot.contextWindow > 0 {
                FlatDivider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("当前会话上下文")
                        Spacer()
                        Text("\(UsageFormatters.tokens(store.snapshot.currentContextUsed)) / \(UsageFormatters.tokens(store.snapshot.contextWindow))")
                            .monospacedDigit()
                    }
                    .font(.callout.weight(.medium))
                    ProgressView(
                        value: Double(store.snapshot.currentContextUsed),
                        total: Double(store.snapshot.contextWindow)
                    )
                }
            }

            FlatDivider()
            if let weekRate = store.snapshot.sevenDayRate {
                RateLimitView(title: "7 天额度", window: weekRate, sampledAt: store.snapshot.mainRateSampledAt)
                if store.snapshot.currentSevenDayRate() != nil {
                    PredictionView(window: weekRate, velocity: store.measuredVelocity)
                }
            } else {
                Text(store.quotaWaitingMessage)
                    .font(.callout)
                    .foregroundStyle(DashboardPalette.secondaryInk)
            }

            FlatDivider()
            if !compact { TokenBreakdownView(usage: store.snapshot.today, sessions: store.snapshot.sessionCount) }
            if !compact, !store.snapshot.topProjects.isEmpty {
                FlatDivider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("项目用量排名").font(.callout.weight(.semibold))
                        Spacer()
                        Picker("时间范围", selection: $projectRange) {
                            Text("今日").tag(0); Text("7 天").tag(1); Text("30 天").tag(2)
                        }.pickerStyle(.segmented).frame(width: 190)
                    }
                    ForEach(projects, id: \.name) { project in
                        HStack { Text(project.name).lineLimit(1); Spacer(); Text(UsageFormatters.tokens(project.tokens)).monospacedDigit() }
                    }
                }.font(.caption)
            }
            if !compact, !store.snapshot.panelModels.isEmpty {
                FlatDivider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型用量占比（近 7 天）").font(.callout.weight(.semibold))
                    ForEach(store.snapshot.panelModels, id: \.name) { model in
                        HStack {
                            Text(model.name)
                            Spacer()
                            Text("\(model.tokens * 100 / max(1, store.snapshot.lastSevenDays.total))% · \(model.requests) 次")
                                .foregroundStyle(DashboardPalette.secondaryInk)
                            if let seconds = model.averageTurnSeconds {
                                Text("平均 \(UsageFormatters.turnDuration(seconds: seconds))")
                                    .foregroundStyle(DashboardPalette.secondaryInk)
                            }
                            Text(UsageFormatters.tokens(model.tokens)).monospacedDigit()
                        }
                    }
                }.font(.caption)
            }
            if !compact, !store.snapshot.dailyUsage.isEmpty {
                FlatDivider()
                UsageTrendView(records: store.snapshot.recentRecords)
            }
            FlatDivider()
            if compact {
                HStack {
                    Button("打开详情") { openDashboard() }
                        .buttonStyle(.borderedProminent)
                    Button("退出") { NSApplication.shared.terminate(nil) }
                        .buttonStyle(.bordered)
                }
                Picker("低额度提醒", selection: $lowRateThreshold) {
                    ForEach([5, 10, 20, 30, 50, 100], id: \.self) { Text("剩余 \($0)% 以下").tag($0) }
                }
                Toggle("同日提醒去重", isOn: $deduplicateAlerts)
                    .controlSize(.small)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("输入 \(UsageFormatters.tokens(store.snapshot.today.input)) · 输出 \(UsageFormatters.tokens(store.snapshot.today.output))")
                    Text("\(store.snapshot.sessionCount) 个会话 · \(store.snapshot.fileCount) 个记录文件")
                }
                .font(.caption)
                .foregroundStyle(DashboardPalette.secondaryInk)
                Spacer()
                if !compact { Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.bordered) }
            }

            if let feedback = store.refreshFeedback {
                UsageRefreshFeedbackView(feedback: feedback)
            }
            if let error = store.errorMessage, error != store.refreshFeedback?.detail {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(DashboardPalette.ink)
                    .lineLimit(2)
            }

            if store.isRefreshing {
                Text("正在读取本机 Codex 记录…")
                    .font(.caption)
                    .foregroundStyle(DashboardPalette.secondaryInk)
            } else if store.snapshot.fileCount == 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        store.snapshot.dataDirectoryExists
                            ? "未在 \(store.snapshot.dataPath) 找到会话记录"
                            : "无法访问 \(store.snapshot.dataPath)"
                    )
                    .font(.caption)
                    .foregroundStyle(DashboardPalette.secondaryInk)
                    .textSelection(.enabled)

                    Button("选择 Codex 数据目录…") {
                        store.chooseCodexFolder()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var projects: [ProjectUsage] {
        switch projectRange { case 0: return store.snapshot.todayProjects; case 2: return store.snapshot.monthProjects; default: return store.snapshot.topProjects }
    }

    private func openDashboard() {
        NotificationCenter.default.post(name: .codexHealthDashboardWillOpen, object: nil)
        openWindow(id: "dashboard")
    }

}

private struct HealthMenuPopover: View {
    let store: UsageStore
    let permissionStore: PermissionStore
    var isVisible = true
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("codexMeter.appearance") private var appearance = AppAppearance.system.rawValue
    @State private var showPermissionHistory = false
    @State private var permissionsExpanded = false


    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Codex Health").font(.callout.weight(.semibold))
                Spacer()
                controls
            }

            QuotaSampleView(
                title: "7 天剩余额度", window: store.snapshot.sevenDayRate,
                sampledAt: store.snapshot.mainRateSampledAt, numberSize: 32,
                secondaryInk: DashboardPalette.popoverSecondaryInk, showsResetTime: true, compactMetadata: true
            )
            if let spark = store.snapshot.sparkRate {
                QuotaSampleView(
                    title: "Spark 剩余额度", window: spark,
                    sampledAt: store.snapshot.sparkRateSampledAt, numberSize: 16,
                    secondaryInk: DashboardPalette.popoverSecondaryInk, showsResetTime: true, compactMetadata: true
                )
            }
            FlatDivider()
            ReplySpeedView(
                samples: store.snapshot.replySpeedSamples, layout: .row, isVisible: isVisible,
                secondaryInk: DashboardPalette.popoverSecondaryInk
            )
            HStack {
                Text("今日 Token").foregroundStyle(DashboardPalette.popoverSecondaryInk)
                Spacer()
                Text(UsageFormatters.tokens(store.snapshot.today.total)).monospacedDigit()
            }
            .font(.callout)
            .help("本机今日记录 · 输入 \(UsageFormatters.tokens(store.snapshot.today.input)) · 输出 \(UsageFormatters.tokens(store.snapshot.today.output)) · 缓存输入 \(UsageFormatters.tokens(store.snapshot.today.cachedInput))。缓存输入是输入的一部分，不重复相加。")

            if permissionStore.newCount > 0 || showPermissionHistory {
                FlatDivider()
                DisclosureGroup(isExpanded: $permissionsExpanded) {
                    ScrollView {
                        PermissionCenterView(store: permissionStore, maximumItems: 2)
                            .padding(.top, 8)
                    }
                    .frame(maxHeight: 220)
                } label: {
                    Label(permissionStore.newCount > 0 ? "\(permissionStore.newCount) 条请求需要关注" : "权限请求记录",
                          systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(permissionStore.newCount > 0 ? DashboardPalette.ink : DashboardPalette.popoverSecondaryInk)
                }
            }
            FlatDivider()
            UsageRefreshStatusView(
                store: store, compact: true,
                secondaryInk: DashboardPalette.popoverSecondaryInk
            )
            HStack {
                Button { openDashboard() } label: {
                    Label("打开详情", systemImage: "arrow.up.forward.app")
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
                .help("打开用量详情")
                Spacer()
                Text("本机统计")
                    .font(.caption2).foregroundStyle(DashboardPalette.popoverSecondaryInk)
            }.font(.callout)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { permissionsExpanded = permissionStore.newCount > 0 }
        .onChange(of: permissionStore.newCount) { _, count in
            if count > 0 { permissionsExpanded = true }
        }
    }

    @ViewBuilder private var controls: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer {
                controlButtons.padding(.horizontal, 6).padding(.vertical, 4)
                    .modifier(PeripheralGlass(interactive: true))
            }
        } else {
            controlButtons.padding(.horizontal, 6).padding(.vertical, 4)
                .modifier(PeripheralGlass(interactive: true))
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 4) {
            Button { Task { await store.refresh(userInitiated: true) } } label: {
                PopoverControlIcon(systemName: "arrow.clockwise")
            }
            .disabled(store.isRefreshing)
            .keyboardShortcut("r", modifiers: .command)
            .help("刷新（⌘R）")
            .accessibilityLabel("刷新本机记录")
            Button { openSettings() } label: {
                PopoverControlIcon(systemName: "gearshape")
            }
            .help("偏好设置")
            .accessibilityLabel("打开偏好设置")
            Menu {
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Button("权限请求记录") {
                    showPermissionHistory.toggle()
                    permissionsExpanded = showPermissionHistory || permissionStore.newCount > 0
                }
                Button("重新读取全部记录") {
                    Task { await store.refresh(force: true, userInitiated: true) }
                }.disabled(store.isRefreshing)
                Divider()
                Button("退出") { NSApplication.shared.terminate(nil) }
            } label: {
                PopoverControlIcon(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多")
            .accessibilityLabel("更多操作")
        }.buttonStyle(.plain)
    }

    private func openDashboard() {
        NotificationCenter.default.post(name: .codexHealthDashboardWillOpen, object: nil)
        openWindow(id: "dashboard")
    }
}

private struct PopoverControlIcon: View {
    let systemName: String
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        Image(systemName: systemName)
            .frame(width: 20, height: 20)
            .frame(width: 28, height: 28)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(DashboardPalette.ink.opacity(isHovered && isEnabled ? 0.08 : 0))
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

private struct UsageRefreshFeedbackView: View {
    let feedback: UsageRefreshFeedback
    var secondaryInk: Color = DashboardPalette.secondaryInk

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(feedback.message, systemImage: symbol)
            Text("手动检查于 \(feedback.checkedAt.formatted(date: .abbreviated, time: .standard))")
            if let detail = feedback.detail {
                Text(detail).lineLimit(2).help(detail)
            }
        }
        .font(.caption2).foregroundStyle(secondaryInk)
        .fixedSize(horizontal: false, vertical: true)
        .help("\(feedback.message)。检查时间仅表示本机读取完成时间，额度采样时间以原始记录为准。")
    }

    private var symbol: String {
        switch feedback.outcome {
        case .newSample: "checkmark.circle"
        case .noNewSample: "clock"
        case .incomplete, .failed: "exclamationmark.triangle"
        }
    }
}

struct ReplySpeedView: View {
    enum Layout { case detail, row, metric }
    let samples: [ReplySpeedSample]
    var layout: Layout = .detail
    var isVisible = true
    var secondaryInk: Color = DashboardPalette.secondaryInk

    var body: some View {
        Group {
            if isVisible {
                TimelineView(.explicit(RecentReplySpeed.refreshDates(samples))) { context in
                    content(at: context.date)
                }
            } else {
                content(at: .now)
            }
        }
    }

    private func content(at date: Date) -> some View {
        let speed = RecentReplySpeed.summarize(samples, now: date)
        return Group {
            switch layout {
            case .metric:
                VStack(alignment: .leading, spacing: 8) {
                    Text("平均回复速度").font(.caption).foregroundStyle(secondaryInk)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(speed.map { $0.tokensPerSecond.formatted(.number.precision(.fractionLength(1))) } ?? "—")
                            .font(.system(size: 28, weight: .medium)).monospacedDigit()
                        Text("tokens/s").font(.caption).foregroundStyle(secondaryInk)
                    }
                    Text(speed.map { "近 15 分钟 · \($0.sampleCount) 个有效轮次" } ?? "近 15 分钟暂无样本")
                        .font(.caption).foregroundStyle(secondaryInk)
                }
            case .row:
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("平均回复速度").foregroundStyle(secondaryInk)
                        Spacer()
                        Text(speed.map { UsageFormatters.replySpeed($0.tokensPerSecond) } ?? "暂无样本")
                            .monospacedDigit()
                    }.font(.callout)
                    Text(speed.map { "近 15 分钟 · \($0.sampleCount) 个有效轮次" + ($0.sampleCount == 1 ? " · 样本较少" : "") } ?? "近 15 分钟无有效完成轮次")
                        .font(.caption2).foregroundStyle(secondaryInk)
                }
            case .detail:
                VStack(alignment: .leading, spacing: 4) {
                    Text("近 15 分钟平均回复速度").font(.caption).foregroundStyle(secondaryInk)
                    Text(speed.map { UsageFormatters.replySpeed($0.tokensPerSecond) } ?? "暂无样本")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                    Text("含思考、工具执行与等待").font(.caption2).foregroundStyle(secondaryInk)
                }
            }
        }
        .help("近 15 分钟完成轮次的输出 token 总数 ÷ 轮次总耗时。含思考、工具执行与等待，空闲间隔不计入；缺少可靠用量或完成标记的轮次不计入。")
    }
}

private struct MenuRow: View {
    let icon: String
    let title: String
    let shortcut: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(DashboardPalette.ink)
                Text(title).foregroundStyle(DashboardPalette.ink)
                Spacer()
                Text(shortcut).font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct UsageTrendView: View {
    let records: [UsageRecord]
    @State private var dimension = "全部"
    @State private var selection = "全部"
    @State private var granularity = "按天"
    var body: some View {
        let options = dimension == "模型" ? Array(Set(records.map(\.model))).sorted() : Array(Set(records.map(\.project))).sorted()
        let selected = selection == "全部" || dimension == "全部" ? records : records.filter { dimension == "模型" ? $0.model == selection : $0.project == selection }
        let filtered = granularity == "按小时"
            ? selected.filter { $0.date >= .now.addingTimeInterval(-24 * 3_600) }
            : selected
        let buckets = Dictionary(grouping: filtered, by: bucketStart).map { DailyUsage(date: $0.key, tokens: $0.value.reduce(0) { $0 + $1.tokens }) }.sorted { $0.date < $1.date }
        let maximum = max(1, buckets.map(\.tokens).max() ?? 1)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(granularity == "按小时" ? "近 24 小时趋势" : "近 7 天趋势").font(.callout.weight(.semibold))
                Spacer()
                Picker("粒度", selection: $granularity) { Text("按天").tag("按天"); Text("按小时").tag("按小时") }
                    .pickerStyle(.segmented).frame(width: 110)
                Picker("维度", selection: $dimension) { Text("全部").tag("全部"); Text("模型").tag("模型"); Text("项目").tag("项目") }
                    .pickerStyle(.segmented).frame(width: 150)
                if dimension != "全部" { Picker("筛选", selection: $selection) { Text("全部").tag("全部"); ForEach(options, id: \.self) { Text($0).tag($0) } }.frame(width: 120) }
            }
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(buckets, id: \.date) { day in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(DashboardPalette.chart)
                            .frame(height: max(4, 40 * CGFloat(day.tokens) / CGFloat(maximum)))
                        Text(granularity == "按小时" ? day.date.formatted(.dateTime.hour()) : day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2).foregroundStyle(DashboardPalette.secondaryInk)
                    }.frame(maxWidth: .infinity)
                }
            }.frame(height: 60)
        }
        .onChange(of: dimension) { _, _ in selection = "全部" }
    }

    private func bucketStart(_ record: UsageRecord) -> Date {
        if granularity == "按小时" {
            return Calendar.current.dateInterval(of: .hour, for: record.date)?.start ?? record.date
        }
        return Calendar.current.startOfDay(for: record.date)
    }
}

private struct TokenBreakdownView: View {
    let usage: TokenUsage
    let sessions: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("今日 Token").font(.callout.weight(.semibold))
            Text("输入 \(UsageFormatters.tokens(usage.input)) · 输出 \(UsageFormatters.tokens(usage.output)) · 推理 \(UsageFormatters.tokens(usage.reasoningOutput))")
            Text("缓存 \(UsageFormatters.tokens(usage.cachedInput)) · 合计 \(UsageFormatters.tokens(usage.total)) · \(sessions) 个会话")
                .foregroundStyle(DashboardPalette.secondaryInk)
        }.font(.caption)
    }
}

private struct PredictionView: View {
    let window: RateWindow
    let velocity: RateVelocity?
    var body: some View {
        let resetHours = max(0, window.resetsAt.timeIntervalSinceNow / 3_600)
        let elapsedHours = max(0.1, Double(window.windowMinutes) / 60 - resetHours)
        let fallbackRate = window.usedPercent / elapsedHours
        let rate = velocity?.percentPerHour ?? fallbackRate
        let remaining = rate > 0 ? (100 - window.usedPercent) / rate : nil
        VStack(alignment: .leading, spacing: 4) {
            Text("用量预测").font(.callout.weight(.semibold))
            Text(remaining.map { "预计还能使用 \(UsageFormatters.duration(hours: $0))" } ?? "样本不足，暂不预测")
            Text((remaining ?? .infinity) < resetHours ? "可能在重置前耗尽" : "预计可支撑到重置")
                .foregroundStyle(DashboardPalette.ink)
            Text(velocity.map { "按近 \($0.description) 小时额度变化加权估算" } ?? "样本不足，使用额度周期平均速度估算")
                .font(.caption2).foregroundStyle(DashboardPalette.secondaryInk)
        }.font(.caption)
    }
}

struct UsageCard: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(DashboardPalette.secondaryInk)
            Text(UsageFormatters.tokens(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}
