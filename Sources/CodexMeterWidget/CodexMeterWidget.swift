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
                content(usage)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    widgetHeader(status: .waitingForSample, isCompact: family == .systemSmall)
                    Spacer(minLength: 0)
                    Text("等待用量数据")
                        .font(.headline)
                    Text("打开主应用同步 · 本地非实时")
                        .font(.caption2)
                        .foregroundStyle(DashboardPalette.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(DashboardPalette.ink)
        .tint(DashboardPalette.ink)
        .progressViewStyle(WidgetGrayProgressStyle())
        .containerBackground(for: .widget) {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    @ViewBuilder
    private func content(_ usage: WidgetUsageData) -> some View {
        let status = quotaStatus(usage)
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 6) {
                widgetHeader(status: status, isCompact: true)
                Spacer(minLength: 0)
                quotaSummary(usage, status: status)
                sampleTime(usage)
            }
        default:
            VStack(alignment: .leading, spacing: 8) {
                widgetHeader(status: status, isCompact: false)
                HStack(alignment: .top, spacing: 16) {
                    quotaSummary(usage, status: status)
                        .frame(width: 112, alignment: .leading)
                    Rectangle()
                        .fill(DashboardPalette.divider)
                        .frame(width: 1, height: 72)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Token 用量")
                            .font(.caption2)
                            .foregroundStyle(DashboardPalette.secondaryInk)
                        HStack(alignment: .top, spacing: 8) {
                            metric("今天", usage.todayTokens)
                            metric("近 7 天", usage.weekTokens)
                            metric("本月", usage.monthTokens)
                        }
                        if usage.contextLimit > 0 {
                            Text("上下文 \(compact(usage.contextTokens)) / \(compact(usage.contextLimit))")
                                .font(.system(size: 10))
                                .foregroundStyle(DashboardPalette.secondaryInk)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                sampleTime(usage)
            }
        }
    }

    private func widgetHeader(status: WidgetQuotaStatus, isCompact: Bool) -> some View {
        HStack(spacing: 6) {
            Label("Codex Health", systemImage: "gauge.with.dots.needle.33percent")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if isCompact {
                Image(systemName: status.symbol)
                    .font(.caption.weight(status.isEmphasized ? .semibold : .regular))
                    .foregroundStyle(status.isEmphasized ? DashboardPalette.ink : DashboardPalette.secondaryInk)
                    .accessibilityLabel(status.title)
                    .help(status.help)
            } else {
                Label(status.title, systemImage: status.symbol)
                    .font(.system(size: 10, weight: status.isEmphasized ? .semibold : .medium))
                    .foregroundStyle(status.isEmphasized ? DashboardPalette.ink : DashboardPalette.secondaryInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(DashboardPalette.divider, lineWidth: 1))
                    .help(status.help)
            }
        }
    }

    private func quotaSummary(_ usage: WidgetUsageData, status: WidgetQuotaStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(quotaTitle(usage, status: status))
                .font(.caption2)
                .foregroundStyle(DashboardPalette.secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(remainingText(usage))
                .font(.system(size: 32, weight: status == .low ? .bold : .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let percent = usage.recordedRatePercent(at: entry.date) {
                ProgressView(value: max(0, 100 - percent), total: 100)
            }
            expiryTime(usage)
                .font(.system(size: 10))
                .foregroundStyle(DashboardPalette.secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
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
        case .recorded: return "\(period)剩余额度"
        case .low: return "\(period)剩余 · 偏低"
        case .stale: return "\(period)上次剩余"
        case .waitingForCycle: return "等待新周期数据"
        case .waitingForSample: return "等待额度采样"
        }
    }

    private func sampleTime(_ usage: WidgetUsageData) -> some View {
        let sample = usage.quotaSample(at: entry.date)
        let isOld = sample.isStale || usage.isStale(at: entry.date)
        return Group {
            if let date = sample.sampledAt, sample.hasValidTime {
                Text("\(isOld ? "旧采样" : (sample.recordedPercent == nil ? "上次采样" : "本地采样")) \(date, format: .dateTime.month().day().hour().minute()) · 非实时")
            } else {
                Text("等待额度采样 · 非实时")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(DashboardPalette.secondaryInk)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .help("\(sample.description)\(isOld ? " · 打开主应用更新" : "")")
    }

    @ViewBuilder
    private func expiryTime(_ usage: WidgetUsageData) -> some View {
        if let resetsAt = usage.rateResetsAt, usage.recordedRatePercent(at: entry.date) != nil {
            Text("重置 \(resetsAt, format: .dateTime.month().day().hour().minute())")
        } else {
            Text("打开主应用同步")
        }
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(DashboardPalette.secondaryInk)
            Text(compact(value))
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: String(format: "%.1fK", Double(value) / 1_000)
        default: value.formatted()
        }
    }

    private func remainingText(_ usage: WidgetUsageData) -> String {
        guard let percent = usage.recordedRatePercent(at: entry.date) else { return "--" }
        return "\(max(0, 100 - Int(percent.rounded())))%"
    }
}

private enum WidgetQuotaStatus: Equatable {
    case recorded, low, stale, waitingForCycle, waitingForSample

    var title: String {
        switch self {
        case .recorded: "本地记录"
        case .low: "额度偏低"
        case .stale: "旧记录"
        case .waitingForCycle: "待更新"
        case .waitingForSample: "待采样"
        }
    }

    var symbol: String {
        switch self {
        case .recorded: "checkmark.circle"
        case .low: "exclamationmark.triangle.fill"
        case .stale: "clock"
        case .waitingForCycle: "arrow.clockwise"
        case .waitingForSample: "hourglass"
        }
    }

    var isEmphasized: Bool { self == .low || self == .stale }

    var help: String {
        switch self {
        case .recorded: "本地采样记录，非实时额度"
        case .low: "本地记录的剩余额度不超过 20%，非实时额度"
        case .stale: "显示上次记录，数据可能已过期；打开主应用更新"
        case .waitingForCycle: "上个额度周期已结束，等待新周期采样"
        case .waitingForSample: "尚无有效额度采样；打开主应用同步"
        }
    }
}


private struct WidgetGrayProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(DashboardPalette.divider)
                Rectangle().fill(DashboardPalette.progress)
                    .frame(width: proxy.size.width * min(1, max(0, configuration.fractionCompleted ?? 0)))
            }
        }
        .frame(height: 3)
    }
}
