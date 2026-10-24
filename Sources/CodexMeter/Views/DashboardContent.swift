import SwiftUI

struct DashboardContent: View {
    let snapshot: UsageSnapshot
    let errorMessage: String?
    let isRefreshing: Bool
    @AppStorage("codexMeter.tokenBreakdownRange") private var tokenRange = "today"
    let measuredVelocity: Double?
    let quotaMessage: String
    let chooseFolder: () -> Void

    private var rate: RateWindow? { snapshot.currentSevenDayRate() }
    private var health: QuotaHealth {
        .evaluate(rate: rate, percentPerHour: QuotaHealth.velocity(rate: rate, measured: measuredVelocity))
    }

    var body: some View {
        TimelineView(.explicit([Date.now] + snapshot.quotaDisplayDeadlines)) { _ in content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("健康报告").font(.system(size: 26, weight: .semibold))
                    Text("本机 Token 记录与账户额度")
                        .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                    Text(snapshot.lastUpdated.map { "更新于 \($0.formatted(.relative(presentation: .named)))" } ?? "等待本机用量")
                        .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                }
                Spacer()
                QuotaHealthBadge(health: health)
            }

            DashboardPanel {
                HStack(alignment: .top, spacing: 32) {
                    QuotaSummary(snapshot: snapshot, quotaMessage: quotaMessage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 28) {
                        HStack(alignment: .top, spacing: 24) {
                            SummaryMetric(
                                title: "本机今日 Token", value: UsageFormatters.tokens(snapshot.today.total),
                                detail: "输入 \(UsageFormatters.tokens(snapshot.today.input)) · 输出 \(UsageFormatters.tokens(snapshot.today.output))"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            SummaryMetric(
                                title: "本机近 7 天 Token", value: UsageFormatters.tokens(snapshot.lastSevenDays.total),
                                detail: "所选目录累计"
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ReplySpeedView(samples: snapshot.replySpeedSamples, layout: .row,
                                       secondaryInk: DashboardPalette.secondaryInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            DashboardPanel {
                TokenUsageBreakdownView(usage: breakdownUsage, title: "Token 构成", selectedRange: $tokenRange)
            }
            DashboardPanel { DeviceUsageSummary(snapshot: snapshot) }
            DashboardPanel { UsageTrendCard(snapshot: snapshot) }

            HStack(alignment: .top, spacing: 20) {
                DashboardPanel {
                    ModelCard(models: snapshot.topModels, weeklyTotal: snapshot.lastSevenDays.total)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                }
                DashboardPanel {
                    ProjectCard(projects: snapshot.topProjects, total: snapshot.lastSevenDays.total)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            MetricsCard(snapshot: snapshot)
                .padding(.horizontal, 4)

            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
            if snapshot.fileCount == 0 && !isRefreshing {
                Button("选择 Codex 数据目录…", action: chooseFolder)
                    .buttonStyle(.bordered)
            }
        }
    }

    private var breakdownUsage: TokenUsage {
        switch tokenRange {
        case "week": snapshot.lastSevenDays
        case "month": snapshot.thisMonth
        default: snapshot.today
        }
    }
}

/// Local token records and account quota have different units and coverage.
/// No per-device token total is present in the current data source.
private struct DeviceUsageSummary: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("跨设备用量").font(.callout.weight(.semibold))
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("其他设备 Token", systemImage: "desktopcomputer")
                        .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                    Text("未同步").font(.title3.weight(.medium))
                    Text("尚未接入其他电脑的用量记录")
                        .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("账户 7 天已用额度").font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                    if let rate = snapshot.currentSevenDayRate(), rate.windowMinutes == 10_080 {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(rate.usedPercent.formatted(.number.precision(.fractionLength(0...1))))%")
                                .font(.title3.weight(.medium)).monospacedDigit()
                            Text("（其他设备：暂无统计）")
                                .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                                .help("账户额度是合计，本机数据没有按设备拆分的额度；不能从本机 Token 换算出其他设备百分比。")
                        }
                        Text(snapshot.mainRateIsCached ? "含其他设备 · 有效缓存采样 · 非实时" : "含其他设备 · 本地采样 · 非实时")
                            .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                    } else {
                        Text("等待有效采样").font(.title3.weight(.medium))
                        Text("当前没有可用的账户 7 天额度")
                            .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("未同步不代表用量为 0。账户额度与本机 Token 口径不同，无法相减推算其他电脑的 Token 消耗。")
                .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct QuotaSummary: View {
    let snapshot: UsageSnapshot
    let quotaMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuotaSampleView(title: "7 天剩余额度", window: snapshot.sevenDayRate,
                            sampledAt: snapshot.mainRateSampledAt, numberSize: 56,
                            showsResetTime: true, compactMetadata: true)
            if snapshot.sevenDayRate == nil {
                Text(quotaMessage).font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
            if let spark = snapshot.sparkRate {
                QuotaSampleView(title: "Spark 剩余额度", window: spark, sampledAt: snapshot.sparkRateSampledAt, numberSize: 16)
            }
            if snapshot.mainRateIsCached || snapshot.sparkRateIsCached {
                Label("缓存额度", systemImage: "clock.arrow.circlepath")
                    .font(.caption2).foregroundStyle(DashboardPalette.secondaryInk)
                    .help("部分额度来自本地有效缓存，获取到新采样后会自动替换")
            }
        }
    }
}

private struct UsageTrendCard: View {
    let snapshot: UsageSnapshot
    @AppStorage(TrendChartStyle.preferenceKey) private var chartStyle = TrendChartStyle.bars.rawValue
    private var days: [DailyUsage] { snapshot.dailyUsage.sorted { $0.date < $1.date }.suffix(7) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("使用趋势").font(.callout.weight(.semibold))
                Spacer()
                TrendChartPicker(selection: $chartStyle)
                Text("近 7 天 · Token").font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
            if days.isEmpty {
                ContentUnavailableView("暂无趋势样本", systemImage: "chart.bar.xaxis")
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                UsageTrendChart(samples: days.map { TrendPoint(date: $0.date, tokens: $0.tokens) }, hourly: false,
                                style: TrendChartStyle(rawValue: chartStyle) ?? .bars)
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
                Text("近 7 天").font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
            if models.isEmpty { Text("暂无模型记录").font(.caption).foregroundStyle(DashboardPalette.secondaryInk) }
            ForEach(models.prefix(3), id: \.name) { model in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.name).lineLimit(1)
                        Spacer()
                        Text(UsageFormatters.tokens(model.tokens)).monospacedDigit()
                    }.font(.callout)
                    ProgressView(value: Double(model.tokens), total: Double(max(1, weeklyTotal))).tint(DashboardPalette.progress)
                    Text("\(model.requests) 个有效轮次 · \(model.averageTurnSeconds.map { "平均 \(UsageFormatters.turnDuration(seconds: $0))" } ?? "暂无耗时样本")")
                        .font(.caption2).foregroundStyle(DashboardPalette.secondaryInk)
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
            MetricRow("本机本月 Token", UsageFormatters.tokens(snapshot.thisMonth.total))
            MetricRow("当前上下文", snapshot.contextWindow > 0 ? "\(UsageFormatters.tokens(snapshot.currentContextUsed)) / \(UsageFormatters.tokens(snapshot.contextWindow))" : "暂无")
            MetricRow("会话", "\(snapshot.sessionCount) 个")
        }
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
                Text("近 7 天").font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
            if projects.isEmpty { Text("暂无项目记录").font(.caption).foregroundStyle(DashboardPalette.secondaryInk) }
            ForEach(projects.prefix(4), id: \.path) { item in
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(DashboardPalette.secondaryInk)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text("\(Int(Double(item.tokens) / Double(max(1, total)) * 100))%")
                        .monospacedDigit().foregroundStyle(DashboardPalette.secondaryInk)
                }.font(.callout)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
