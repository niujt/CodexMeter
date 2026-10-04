import SwiftUI
import WidgetKit

@main
struct CodexMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexMeterWidget()
    }
}

struct CodexMeterWidget: Widget {
    let kind = "CodexMeterWidgetV4"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            CodexMeterWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex Health")
        .description("查看 Codex Token 用量和额度。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct UsageEntry: TimelineEntry {
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
            updatedAt: .now, rateResetsAt: .now.addingTimeInterval(86_400)
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, usage: WidgetUsageCache.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = UsageEntry(date: .now, usage: WidgetUsageCache.load())
        // Include expiry entries so cached quota disappears even with the main app closed.
        let nextCheck = Date.now.addingTimeInterval(1_800)
        let deadlines = [entry.usage?.rateResetsAt, entry.usage?.updatedAt.addingTimeInterval(1_801)]
            .compactMap { $0 }.filter { $0 > entry.date }
        let dates = Array(Set(deadlines + [nextCheck])).sorted()
        let entries = [entry] + dates.map { UsageEntry(date: $0, usage: entry.usage) }
        completion(Timeline(entries: entries, policy: .after(nextCheck)))
    }
}

private struct CodexMeterWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        if let usage = entry.usage {
            content(usage)
                .tint(.primary)
                .progressViewStyle(WidgetGrayProgressStyle())
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Codex Health", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.headline)
                Spacer()
                Text("打开 Codex Health\n以读取本机用量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .containerBackground(for: .widget) {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }

    @ViewBuilder
    private func content(_ usage: WidgetUsageData) -> some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 8) {
                Label("Codex Health", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption.weight(.semibold))
                if usage.isStale(at: entry.date) {
                    Text("数据可能已过期").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Text(remainingText(usage))
                    .font(.system(size: 30, weight: .medium))
                    .minimumScaleFactor(0.65)
                Text(usage.currentRatePercent(at: entry.date) == nil ? "等待新周期数据" : "额度剩余")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let percent = usage.currentRatePercent(at: entry.date),
                   let resetsAt = usage.rateResetsAt {
                    ProgressView(value: max(0, 100 - percent), total: 100)
                    Text("本周期到期 \(resetsAt, format: .dateTime.month().day().hour().minute())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .containerBackground(for: .widget) {
                Color(nsColor: .windowBackgroundColor)
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Codex Health", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.headline)
                    Spacer()
                    Text(usage.currentRatePercent(at: entry.date) == nil ? "额度待更新" : "剩余 \(remainingText(usage))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if usage.isStale(at: entry.date) {
                    Text("数据可能已过期 · 请打开主应用更新").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    metric("今天", usage.todayTokens)
                    metric("近 7 天", usage.weekTokens)
                    metric("本月", usage.monthTokens)
                }
                if let percent = usage.currentRatePercent(at: entry.date) {
                    HStack {
                        Text(usage.rateWindowMinutes == 10_080 ? "7 天额度" : "额度")
                        Spacer()
                        Text("剩余 \(max(0, 100 - Int(percent.rounded())))%")
                    }
                    .font(.caption)
                    ProgressView(value: max(0, 100 - percent), total: 100)
                    if let resetsAt = usage.rateResetsAt {
                        Text("本周期到期 \(resetsAt, format: .dateTime.month().day().hour().minute())")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if usage.contextLimit > 0 {
                    Text("上下文 \(compact(usage.contextTokens)) / \(compact(usage.contextLimit))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("更新于 \(usage.updatedAt, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .containerBackground(for: .widget) {
                Color.clear
            }
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
        guard let percent = usage.currentRatePercent(at: entry.date) else { return "--" }
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
