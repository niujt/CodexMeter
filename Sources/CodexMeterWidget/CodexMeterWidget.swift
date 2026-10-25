import SwiftUI
import WidgetKit

#if !CODEX_HEALTH_WIDGET_PREVIEW
@main
struct CodexMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexMeterWidget()
    }
}
#endif

struct CodexMeterWidget: Widget {
    let kind = WidgetUsageCache.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            CodexMeterWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex Health")
        .description("查看 Codex Token 用量和额度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UsageEntry: TimelineEntry {
    let date: Date
    let usage: WidgetUsageData?
}

private struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, usage: .init(
            todayTokens: 59_400,
            weekTokens: 235_000,
            monthTokens: 861_000,
            contextTokens: 59_400,
            contextLimit: 258_400,
            ratePercent: 16,
            rateWindowMinutes: 10_080,
            updatedAt: .now, sampledAt: .now, rateResetsAt: .now.addingTimeInterval(86_400)
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : UsageEntry(date: .now, usage: WidgetUsageCache.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = UsageEntry(date: .now, usage: WidgetUsageCache.load())
        let schedule = WidgetTimelineSchedule(usage: entry.usage, now: entry.date)
        let entries = schedule.dates.map { UsageEntry(date: $0, usage: entry.usage) }
        completion(Timeline(entries: entries, policy: .after(schedule.reloadAt)))
    }
}

struct CodexMeterWidgetView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: UsageEntry
    private let familyOverride: WidgetFamily?
    private var family: WidgetFamily { familyOverride ?? widgetFamily }

    init(entry: UsageEntry, family: WidgetFamily? = nil) {
        self.entry = entry
        familyOverride = family
    }

    var body: some View {
        Group {
            if let usage = entry.usage {
                if family == .systemSmall {
                    smallContent(usage)
                } else {
                    mediumContent(usage)
                }
            } else {
                emptyContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.primary)
        .containerBackground(.background, for: .widget)
    }

    private func smallContent(_ usage: WidgetUsageData) -> some View {
        let status = quotaStatus(usage)
        let incomplete = usage.sourceIncomplete == true
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(quotaTitle(usage, status: status))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                statusIcon(status, color: quotaColor(usage))
            }
            Spacer(minLength: 4)
            quotaRing(usage, size: incomplete ? 64 : 72)
            Spacer(minLength: 4)
            VStack(spacing: 2) {
                resetTime(usage)
                sampleTime(usage)
                if incomplete { sourceIncompleteNotice }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    private func mediumContent(_ usage: WidgetUsageData) -> some View {
        let status = quotaStatus(usage)
        let incomplete = usage.sourceIncomplete == true
        return HStack(spacing: 18) {
            VStack(spacing: 5) {
                Text(quotaTitle(usage, status: status))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.85)
                quotaRing(usage, size: 78)
                resetTime(usage)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 100)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 4) {
                    if incomplete {
                        sourceIncompleteNotice
                    } else {
                        Text("本机 Token").font(.system(size: 11, weight: .medium))
                    }
                    Spacer(minLength: 0)
                    statusIcon(status, color: quotaColor(usage))
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    metric("今天", incomplete ? nil : usage.todayTokens)
                    metric("近 7 天", incomplete ? nil : usage.weekTokens)
                    metric("本月", incomplete ? nil : usage.monthTokens)
                }
                contextSummary(usage, incomplete: incomplete)
                sampleTime(usage)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Codex Health", systemImage: "circle.dotted")
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
            Text("等待用量数据").font(.headline)
            Text("打开主应用同步")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text("本地采样 · 非实时")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func quotaRing(_ usage: WidgetUsageData, size: CGFloat) -> some View {
        let sample = usage.quotaSample(at: entry.date)
        let remaining = sample.recordedPercent.map { min(1, max(0, (100 - $0) / 100)) }
        let color = quotaColor(usage)
        return ZStack {
            Circle().stroke(.secondary.opacity(0.13), lineWidth: 6)
            if let remaining, remaining > 0 {
                Circle().trim(from: 0, to: remaining)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(remainingText(usage))
                .font(.system(size: size < 70 ? 23 : 27, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.55)
                .padding(5)
        }
        .padding(3)
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(quotaTitle(usage, status: quotaStatus(usage)))，\(remainingText(usage))。\(quotaStatus(usage).help)")
    }

    private func quotaColor(_ usage: WidgetUsageData) -> Color {
        switch usage.quotaSample(at: entry.date).remainingTint {
        case .green: .green
        case .yellow: .yellow
        case .red: .red
        case .unknown: .secondary
        }
    }

    private func statusIcon(_ status: WidgetQuotaStatus, color: Color) -> some View {
        Image(systemName: status.symbol)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(status == .low ? color : .secondary)
            .accessibilityLabel(status.help)
            .help(status.help)
    }

    private var sourceIncompleteNotice: some View {
        Label("统计不完整", systemImage: "exclamationmark.circle")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help("本地用量尚未完整读取；打开主应用检查读取状态。额度采样时间单独显示。")
    }

    private func quotaStatus(_ usage: WidgetUsageData) -> WidgetQuotaStatus {
        guard let percent = usage.recordedRatePercent(at: entry.date) else {
            if let resetsAt = usage.rateResetsAt, resetsAt <= entry.date { return .waitingForCycle }
            return .waitingForSample
        }
        if usage.quotaSample(at: entry.date).isStale || usage.isStale(at: entry.date) { return .stale }
        return 100 - percent < 20 ? .low : .recorded
    }

    private func quotaTitle(_ usage: WidgetUsageData, status: WidgetQuotaStatus) -> String {
        let period = switch usage.rateWindowMinutes {
        case 10_080: "7 天"
        case 300: "5 小时"
        default: ""
        }
        switch status {
        case .recorded, .low: return "\(period)剩余额度"
        case .stale: return "\(period)上次剩余"
        case .waitingForCycle: return "额度待更新"
        case .waitingForSample: return "等待额度采样"
        }
    }

    private func sampleTime(_ usage: WidgetUsageData) -> some View {
        let sample = usage.quotaSample(at: entry.date)
        let isOld = sample.isStale || usage.isStale(at: entry.date)
        return Group {
            if let date = sample.sampledAt, sample.hasValidTime {
                Text("\(isOld ? "旧采样" : "采样") \(date, format: .dateTime.hour().minute()) · 非实时")
            } else {
                Text("采样时间未知 · 非实时")
            }
        }
        .lineLimit(1).minimumScaleFactor(0.85)
        .help("\(sample.description)\(isOld ? " · 打开主应用更新" : "")")
    }

    @ViewBuilder
    private func resetTime(_ usage: WidgetUsageData) -> some View {
        if let resetsAt = usage.rateResetsAt, usage.recordedRatePercent(at: entry.date) != nil {
            Text("\(resetsAt, format: .dateTime.month().day().hour().minute()) 重置")
                .lineLimit(1).minimumScaleFactor(0.8)
        } else {
            Text("打开主应用同步").lineLimit(1)
        }
    }

    @ViewBuilder
    private func contextSummary(_ usage: WidgetUsageData, incomplete: Bool) -> some View {
        if incomplete {
            Text("上下文待完整读取")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        } else if usage.contextLimit > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("上下文 \(compact(usage.contextTokens)) / \(compact(usage.contextLimit))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .help("上下文 \(usage.contextTokens.formatted()) / \(usage.contextLimit.formatted()) Token")
                GeometryReader { proxy in
                    Capsule().fill(.secondary.opacity(0.13))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.secondary.opacity(0.55))
                                .frame(width: proxy.size.width * min(1, max(0, Double(usage.contextTokens) / Double(usage.contextLimit))))
                        }
                }
                .frame(height: 3)
            }
        } else {
            Text("暂无上下文记录")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func metric(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value.map { compact($0) } ?? "—")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                .accessibilityLabel(value.map { $0.formatted() } ?? "统计未完整读取")
                .help(value.map { "\($0.formatted()) Token" } ?? "统计未完整读取")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000_000...: String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
        default: value.formatted()
        }
    }

    private func remainingText(_ usage: WidgetUsageData) -> String {
        usage.quotaSample(at: entry.date).recordedRemaining.map { "\($0)%" } ?? "—"
    }
}

private enum WidgetQuotaStatus: Equatable {
    case recorded, low, stale, waitingForCycle, waitingForSample

    var symbol: String {
        switch self {
        case .recorded: "checkmark.circle"
        case .low: "exclamationmark.triangle.fill"
        case .stale: "clock"
        case .waitingForCycle: "arrow.clockwise"
        case .waitingForSample: "hourglass"
        }
    }

    var help: String {
        switch self {
        case .recorded: "本地采样记录，非实时额度"
        case .low: "本地记录的剩余额度低于 20%，非实时额度"
        case .stale: "显示上次记录，数据可能已过期；打开主应用更新"
        case .waitingForCycle: "上个额度周期已结束，等待新周期采样"
        case .waitingForSample: "尚无有效额度采样；打开主应用同步"
        }
    }
}
