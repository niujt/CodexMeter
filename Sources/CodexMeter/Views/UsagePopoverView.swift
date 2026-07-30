import SwiftUI

struct UsagePopoverView: View {
    let store: UsageStore
    let compact: Bool
    @Environment(\.openWindow) private var openWindow
    @State private var projectRange = 1
    @AppStorage("codexMeter.lowRateThreshold") private var lowRateThreshold = 20
    @AppStorage("codexMeter.deduplicateAlerts") private var deduplicateAlerts = true

    var body: some View {
        Group {
            if compact {
                HealthMenuPopover(store: store)
            } else {
                detailedContent
            }
        }
        .task {
            await store.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await store.refresh()
            }
        }
    }

    private var detailedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                if compact, let rate = store.snapshot.sevenDayRate {
                    let remaining = max(0, 100 - Int(rate.usedPercent.rounded()))
                    let color: Color = remaining < 20 ? .red : remaining < 50 ? .orange : .green
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
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !store.isRefreshing)) { context in
                        Image(systemName: "arrow.clockwise")
                            .rotationEffect(.degrees(store.isRefreshing ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) * 450 : 0))
                    }
                }
                .buttonStyle(.plain).disabled(store.isRefreshing).help("刷新")
            }

            if !compact { HStack(spacing: 10) {
                UsageCard(title: "今天", value: store.snapshot.today.total)
                UsageCard(title: "近 7 天", value: store.snapshot.lastSevenDays.total)
                UsageCard(title: "本月", value: store.snapshot.thisMonth.total)
            }}

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

            if let weekRate = store.snapshot.sevenDayRate {
                Divider()
                RateLimitView(title: "7 天额度", window: weekRate)
                PredictionView(
                    window: weekRate,
                    weeklyTokens: store.snapshot.lastSevenDays.total,
                    observedTurns: store.snapshot.panelModels.reduce(0) { $0 + $1.requests }
                )
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
                    Button("打开详情") { openWindow(id: "dashboard") }
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
                    .foregroundStyle(.red)
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
                    .foregroundStyle(.orange)
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

}

private struct HealthMenuPopover: View {
    let store: UsageStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("codexMeter.lowRateThreshold") private var lowRateThreshold = 20
    @AppStorage("codexMeter.deduplicateAlerts") private var deduplicateAlerts = true

    private var rate: RateWindow? { store.snapshot.sevenDayRate }
    private var remaining: Int { max(0, 100 - Int((rate?.usedPercent ?? 0).rounded())) }
    private var color: Color { remaining < 20 ? .red : remaining < 50 ? .orange : .green }
    private var status: String { remaining < 20 ? "Critical" : remaining < 50 ? "Watch" : "Healthy" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Codex Health").font(.headline.weight(.semibold))
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !store.isRefreshing)) { context in
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                            .rotationEffect(.degrees(store.isRefreshing ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.8) * 450 : 0))
                    }
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .help("刷新")
            }

            HStack(spacing: 18) {
                Text("\(remaining)%")
                    .font(.system(size: 48, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Divider().frame(height: 68)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status).font(.title3.weight(.bold)).foregroundStyle(color)
                    if let rate {
                        Text("剩余 \(UsageFormatters.countdown(to: rate.resetsAt))")
                            .font(.callout.weight(.medium))
                        Text(rate.resetsAt.formatted(.dateTime.month().day().hour().minute()) + " 重置")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("等待额度数据").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            ProgressView(value: Double(remaining), total: 100)
                .tint(color)
                .controlSize(.regular)

            Divider()
            MenuRow(icon: "arrow.up.forward.app", title: "打开 Codex Health", shortcut: "⌘O") {
                openWindow(id: "dashboard")
            }
            HStack(spacing: 10) {
                Image(systemName: "bell.badge").foregroundStyle(.blue).frame(width: 18)
                Text("低额度提醒")
                Spacer()
                Picker("低额度提醒", selection: $lowRateThreshold) {
                    ForEach([5, 10, 20, 30, 50], id: \.self) { Text("剩余 \($0)% 以下").tag($0) }
                }
                .labelsHidden()
                .frame(width: 138)
            }
            .font(.callout)
            Toggle("同日提醒去重", isOn: $deduplicateAlerts)
                .toggleStyle(.checkbox)
                .font(.callout)
                .padding(.leading, 30)
            MenuRow(icon: "rectangle.portrait.and.arrow.right", title: "退出", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(18)
        .frame(width: 360, alignment: .leading)
        .background(Color(red: 0.025, green: 0.065, blue: 0.105))
        .preferredColorScheme(.dark)
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
                Image(systemName: icon).frame(width: 18).foregroundStyle(.blue)
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
                            .fill(.blue)
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
                .foregroundStyle((remaining ?? .infinity) < resetHours ? .orange : .green)
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
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
