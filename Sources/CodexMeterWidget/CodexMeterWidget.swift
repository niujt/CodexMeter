import SwiftUI
import WidgetKit

@main
struct CodexMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexMeterWidget()
    }
}

struct CodexMeterWidget: Widget {
    let kind = "CodexMeterWidgetV2"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            CodexMeterWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex 用量")
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
            updatedAt: .now
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, usage: WidgetUsageCache.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = UsageEntry(date: .now, usage: WidgetUsageCache.load())
        let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: .now) ?? .now.addingTimeInterval(1_800)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

private struct CodexMeterWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        if let usage = entry.usage {
            content(usage)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Codex 用量", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.headline)
                Spacer()
                Text("打开 CodexMeter\n以读取本机用量")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .containerBackground(for: .widget) { Color.clear }
        }
    }

    @ViewBuilder
    private func content(_ usage: WidgetUsageData) -> some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 8) {
                Label("Codex 用量", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(remainingText(usage))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.65)
                Text("7 天额度剩余")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let percent = usage.ratePercent {
                    ProgressView(value: max(0, 100 - percent), total: 100)
                    Text("今日 \(compact(usage.todayTokens)) Token")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .containerBackground(for: .widget) { Color.clear }
        default:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Codex 用量", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.headline)
                    Spacer()
                    Text(remainingText(usage))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    metric("今天", usage.todayTokens)
                    metric("近 7 天", usage.weekTokens)
                    metric("本月", usage.monthTokens)
                }
                if let percent = usage.ratePercent {
                    HStack {
                        Text(usage.rateWindowMinutes == 10_080 ? "7 天额度" : "额度")
                        Spacer()
                        Text("剩余 \(max(0, 100 - Int(percent.rounded())))%")
                    }
                    .font(.caption)
                    ProgressView(value: max(0, 100 - percent), total: 100)
                }
                Spacer(minLength: 0)
                Text("更新于 \(usage.updatedAt, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .containerBackground(for: .widget) { Color.clear }
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
        guard let percent = usage.ratePercent else { return "--" }
        return "\(max(0, 100 - Int(percent.rounded())))%"
    }
}
