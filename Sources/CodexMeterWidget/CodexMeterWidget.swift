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
                    Label("Codex Health", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 0)
                    Text("等待用量数据")
                        .font(.headline)
                    Text("打开主应用后自动同步")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.primary)
        .tint(.primary)
        .progressViewStyle(WidgetGrayProgressStyle())
        .containerBackground(for: .widget) {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    @ViewBuilder
    private func content(_ usage: WidgetUsageData) -> some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 5) {
                Label("Codex Health", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption.weight(.semibold))
                if usage.isStale(at: entry.date) {
                    Text("数据可能已过期").font(.caption2).foregroundStyle(.secondary)
                }
                sampleTime(usage)
                Spacer(minLength: 0)
                Text(remainingText(usage))
                    .font(.system(size: 28, weight: .medium))
                    .minimumScaleFactor(0.65)
                Text(usage.recordedRatePercent(at: entry.date) == nil ? "等待新周期数据" : (usage.quotaSample(at: entry.date).isStale ? "上次记录的剩余额度" : "额度剩余"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let percent = usage.recordedRatePercent(at: entry.date),
                   let resetsAt = usage.rateResetsAt {
                    ProgressView(value: max(0, 100 - percent), total: 100)
                    Text("本周期到期 \(resetsAt, format: .dateTime.month().day().hour().minute())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Codex Health", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(usage.recordedRatePercent(at: entry.date) == nil ? "额度待更新" : "\(usage.quotaSample(at: entry.date).isStale ? "上次剩余" : "剩余") \(remainingText(usage))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if usage.isStale(at: entry.date) {
                    Text("数据可能已过期 · 打开主应用更新").font(.caption2).foregroundStyle(.secondary)
                }
                sampleTime(usage)
                HStack(spacing: 10) {
                    metric("今天", usage.todayTokens)
                    metric("近 7 天", usage.weekTokens)
                    metric("本月", usage.monthTokens)
                }
                if let percent = usage.recordedRatePercent(at: entry.date) {
                    HStack {
                        Text((usage.rateWindowMinutes == 10_080 ? "7 天额度" : "额度") + (usage.quotaSample(at: entry.date).isStale ? " · 上次记录" : ""))
                        Spacer()
                        Text("剩余 \(max(0, 100 - Int(percent.rounded())))%")
                    }
                    .font(.caption)
                    ProgressView(value: max(0, 100 - percent), total: 100)
                }
                Spacer(minLength: 0)
                ViewThatFits(in: .horizontal) {
                    HStack {
                        expiryTime(usage)
                        Spacer(minLength: 4)
                        if usage.contextLimit > 0 {
                            Text("上下文 \(compact(usage.contextTokens)) / \(compact(usage.contextLimit))")
                        }
                    }
                    expiryTime(usage)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func sampleTime(_ usage: WidgetUsageData) -> some View {
        let sample = usage.quotaSample(at: entry.date)
        return Group {
            if let date = sample.sampledAt, sample.hasValidTime {
                Text("\(sample.isStale ? "旧采样" : "本地采样") \(date, format: .dateTime.month().day().hour().minute()) · 非实时")
            } else {
                Text("等待额度采样 · 非实时")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private func expiryTime(_ usage: WidgetUsageData) -> some View {
        if let resetsAt = usage.rateResetsAt, usage.recordedRatePercent(at: entry.date) != nil {
            Text("到期 \(resetsAt, format: .dateTime.month().day().hour().minute())")
        } else {
            Text("更新于 \(usage.updatedAt, style: .time)")
        }
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(compact(value)).font(.headline).minimumScaleFactor(0.7)
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


private struct WidgetGrayProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(.primary.opacity(0.1))
                Rectangle().fill(.primary.opacity(0.75))
                    .frame(width: proxy.size.width * min(1, max(0, configuration.fractionCompleted ?? 0)))
            }
        }
        .frame(height: 3)
    }
}
