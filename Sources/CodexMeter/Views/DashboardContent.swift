import SwiftUI

struct DashboardContent: View {
    let snapshot: UsageSnapshot
    let errorMessage: String?
    let isRefreshing: Bool
    let measuredVelocity: Double?
    let quotaMessage: String
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
                    Text("Token 按所选目录统计").font(.caption).foregroundStyle(.secondary)
                    Text(snapshot.lastUpdated.map { "更新于 \($0.formatted(.relative(presentation: .named)))" } ?? "等待本机用量")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Label(health.title, systemImage: health.icon)
                    .font(.caption).foregroundStyle(health.color)
                    .help(health.detail)
            }

            HStack(alignment: .top, spacing: 20) {
                QuotaSummary(snapshot: snapshot, rate: rate, remaining: remaining, color: health.color, quotaMessage: quotaMessage)
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

private struct QuotaSummary: View {
    let snapshot: UsageSnapshot
    let rate: RateWindow?
    let remaining: Int?
    let color: Color
    let quotaMessage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("7 天剩余额度").font(.caption).foregroundStyle(.secondary)
            Text(remaining.map { "\($0)%" } ?? "—")
                .font(.system(size: 28, weight: .medium)).monospacedDigit()
            if let remaining { ProgressView(value: Double(remaining), total: 100).tint(color).frame(maxWidth: 180) }
            Text(rate.map { "\(UsageFormatters.countdown(to: $0.resetsAt))后重置" } ?? quotaMessage)
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
