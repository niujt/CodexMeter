import SwiftUI

struct UsagePopoverView: View {
    let store: UsageStore
    let permissionStore: PermissionStore
    let compact: Bool
    var isVisible = true
    @Environment(\.openWindow) private var openWindow
    @State private var projectRange = 1
    @AppStorage("codexMeter.lowRateThreshold") private var lowRateThreshold = 20
    @AppStorage("codexMeter.deduplicateAlerts") private var deduplicateAlerts = true

    var body: some View {
        Group {
            if compact {
                HealthMenuPopover(store: store, permissionStore: permissionStore, isVisible: isVisible)
            } else {
                detailedContent
            }
        }
        .safeAreaInset(edge: .top) {
            if store.isRefreshing {
                ProgressView(store.loadingMessage)
                    .controlSize(.small)
                    .padding(10)
            }
        }
        .tint(.primary)
        .progressViewStyle(FlatProgressStyle())
        .task {
            guard store.snapshot.lastUpdated == nil else { return }
            await store.refresh()
        }
    }

    private var detailedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                if compact, let rate = store.snapshot.sevenDayRate {
                    let remaining = max(0, 100 - Int(rate.usedPercent.rounded()))
                    let color = Color.primary
                    Image("CodexHealthMark")
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
                        Text("本机记录").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    Task { await store.refresh() }
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
                Divider()
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

            Divider()
            if let weekRate = store.snapshot.sevenDayRate {
                RateLimitView(title: "7 天额度", window: weekRate)
                PredictionView(
                    window: weekRate,
                    weeklyTokens: store.snapshot.lastSevenDays.total,
                    observedTurns: store.snapshot.panelModels.reduce(0) { $0 + $1.requests }
                )
            } else {
                Text("等待新周期数据")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()
            if !compact { TokenBreakdownView(usage: store.snapshot.today, sessions: store.snapshot.sessionCount) }
            if !compact, !store.snapshot.topProjects.isEmpty {
                Divider()
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
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("模型用量占比（近 7 天）").font(.callout.weight(.semibold))
                    ForEach(store.snapshot.panelModels, id: \.name) { model in
                        HStack {
                            Text(model.name)
                            Spacer()
                            Text("\(model.tokens * 100 / max(1, store.snapshot.lastSevenDays.total))% · \(model.requests) 次")
                                .foregroundStyle(.secondary)
                            if let seconds = model.averageTurnSeconds {
                                Text("平均 \(UsageFormatters.turnDuration(seconds: seconds))")
                                    .foregroundStyle(.secondary)
                            }
                            Text(UsageFormatters.tokens(model.tokens)).monospacedDigit()
                        }
                    }
                }.font(.caption)
            }
            if !compact, !store.snapshot.dailyUsage.isEmpty {
                Divider()
                UsageTrendView(records: store.snapshot.recentRecords)
            }
            Divider()
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
                .foregroundStyle(.secondary)
                Spacer()
                if !compact { Button("退出") { NSApplication.shared.terminate(nil) }.buttonStyle(.bordered) }
            }

            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            if store.isRefreshing {
                Text("正在读取本机 Codex 记录…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.snapshot.fileCount == 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        store.snapshot.dataDirectoryExists
                            ? "未在 \(store.snapshot.dataPath) 找到会话记录"
                            : "无法访问 \(store.snapshot.dataPath)"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private var rate: RateWindow? { store.snapshot.sevenDayRate }
    private var remaining: Int? { rate.map { max(0, 100 - Int($0.usedPercent.rounded())) } }
    private var color: Color { remaining == nil ? .secondary : .primary }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Codex Health").font(.callout.weight(.semibold))
                Spacer()
                controls
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("7 天剩余额度").font(.caption).foregroundStyle(.secondary)
                    Text(remaining.map { "\($0)%" } ?? "—")
                        .font(.system(size: 32, weight: .medium, design: .rounded)).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(rate.map { "\(UsageFormatters.countdown(to: $0.resetsAt))后重置" } ?? "等待新周期数据")
                        .font(.caption).foregroundStyle(.secondary)
                    if let spark = store.snapshot.sparkRate {
                        Text("Spark 剩余 \(max(0, 100 - Int(spark.usedPercent.rounded())))%")
                            .font(.caption2).foregroundStyle(.secondary)
                            .help(store.snapshot.sparkRateIsCached ? "来自本地有效缓存" : "最新 Spark 额度")
                    }
                }
            }
            if let remaining { ProgressView(value: Double(remaining), total: 100).tint(color) }
            if store.snapshot.mainRateIsCached || store.snapshot.sparkRateIsCached {
                Label("部分额度来自有效缓存", systemImage: "clock.arrow.circlepath")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Divider()
            ReplySpeedView(samples: store.snapshot.replySpeedSamples, layout: .row, isVisible: isVisible)
            HStack {
                Text("今日用量").foregroundStyle(.secondary)
                Spacer()
                Text(UsageFormatters.tokens(store.snapshot.today.total)).monospacedDigit()
            }.font(.callout)

            if permissionStore.newCount > 0 || showPermissionHistory {
                Divider()
                DisclosureGroup(isExpanded: $permissionsExpanded) {
                    ScrollView {
                        PermissionCenterView(store: permissionStore, maximumItems: 2)
                            .padding(.top, 8)
                    }
                    .frame(maxHeight: 220)
                } label: {
                    Label(permissionStore.newCount > 0 ? "\(permissionStore.newCount) 条请求需要关注" : "权限请求记录",
                          systemImage: "exclamationmark.shield")
                        .font(.caption).foregroundStyle(permissionStore.newCount > 0 ? Color.primary : Color.secondary)
                }
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(error)
            }
            Divider()
            HStack {
                Button("打开详情", systemImage: "arrow.up.forward.app") { openDashboard() }
                    .buttonStyle(.plain).foregroundStyle(.tint)
                Spacer()
                Text(store.isRefreshing ? "刷新中…" : "本机统计")
                    .font(.caption2).foregroundStyle(.secondary)
            }.font(.callout)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme)
        .onAppear { permissionsExpanded = permissionStore.newCount > 0 }
        .onChange(of: permissionStore.newCount) { _, count in
            if count > 0 { permissionsExpanded = true }
        }
    }

    private var controls: some View { controlButtons }

    private var controlButtons: some View {
        HStack(spacing: 8) {
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 20, height: 20)
            }.disabled(store.isRefreshing).help("刷新")
            Button { openSettings() } label: {
                Image(systemName: "gearshape").frame(width: 20, height: 20)
            }.help("偏好设置")
            Menu {
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Button("权限请求记录") {
                    showPermissionHistory.toggle()
                    permissionsExpanded = showPermissionHistory
                }
                Divider()
                Button("退出") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多")
        }.buttonStyle(.plain)
    }

    private func openDashboard() {
        NotificationCenter.default.post(name: .codexHealthDashboardWillOpen, object: nil)
        openWindow(id: "dashboard")
    }
}

struct ReplySpeedView: View {
    enum Layout { case detail, row, metric }
    let samples: [ReplySpeedSample]
    var layout: Layout = .detail
    var isVisible = true

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
                    Text("平均回复速度").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(speed.map { $0.tokensPerSecond.formatted(.number.precision(.fractionLength(1))) } ?? "—")
                            .font(.system(size: 28, weight: .medium)).monospacedDigit()
                        Text("tokens/s").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(speed.map { "近 15 分钟 · \($0.sampleCount) 个有效轮次" } ?? "近 15 分钟暂无样本")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .row:
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("平均回复速度").foregroundStyle(.secondary)
                        Spacer()
                        Text(speed.map { UsageFormatters.replySpeed($0.tokensPerSecond) } ?? "暂无样本")
                            .monospacedDigit()
                    }.font(.callout)
                    Text(speed.map { "近 15 分钟 · \($0.sampleCount) 个有效轮次" } ?? "近 15 分钟无有效完成轮次")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            case .detail:
                VStack(alignment: .leading, spacing: 4) {
                    Text("近 15 分钟平均回复速度").font(.caption).foregroundStyle(.secondary)
                    Text(speed.map { UsageFormatters.replySpeed($0.tokensPerSecond) } ?? "暂无样本")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                    Text("含思考、工具执行与等待").font(.caption2).foregroundStyle(.secondary)
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
                Image(systemName: icon).frame(width: 18).foregroundStyle(.primary)
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(shortcut).font(.caption).foregroundStyle(.secondary)
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
                            .fill(.primary.opacity(0.8))
                            .frame(height: max(4, 40 * CGFloat(day.tokens) / CGFloat(maximum)))
                        Text(granularity == "按小时" ? day.date.formatted(.dateTime.hour()) : day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2).foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
        }.font(.caption)
    }
}

private struct PredictionView: View {
    let window: RateWindow
    let weeklyTokens: Int
    let observedTurns: Int
    var body: some View {
        let resetHours = max(0, window.resetsAt.timeIntervalSinceNow / 3_600)
        let velocity = RateHistory.weightedVelocity()
        let elapsedHours = max(0.1, Double(window.windowMinutes) / 60 - resetHours)
        let fallbackRate = window.usedPercent / elapsedHours
        let rate = velocity?.percentPerHour ?? fallbackRate
        let remaining = rate > 0 ? (100 - window.usedPercent) / rate : nil
        let remainingTokens = window.usedPercent > 0
            ? Double(weeklyTokens) * (100 - window.usedPercent) / window.usedPercent
            : nil
        let estimatedTurns = remainingTokens.flatMap { tokens in
            observedTurns > 0 ? Int((tokens / Double(observedTurns)).rounded(.down)) : nil
        }
        VStack(alignment: .leading, spacing: 4) {
            Text("用量预测").font(.callout.weight(.semibold))
            Text(remaining.map { "预计还能使用 \(UsageFormatters.duration(hours: $0))" } ?? "样本不足，暂不预测")
            if let estimatedTurns {
                Text("按近 7 天平均 Token / 轮估算，约还能完成 \(estimatedTurns) 轮")
                    .foregroundStyle(.secondary)
            }
            Text((remaining ?? .infinity) < resetHours ? "可能在重置前耗尽" : "预计可支撑到重置")
                .foregroundStyle(.primary)
            Text(velocity.map { "按近 \($0.description) 小时额度变化加权估算" } ?? "样本不足，使用额度周期平均速度估算")
                .font(.caption2).foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            Text(UsageFormatters.tokens(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}
