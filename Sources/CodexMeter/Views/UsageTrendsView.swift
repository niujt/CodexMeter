import SwiftUI

struct UsageTrendsView: View {
    let store: UsageStore
    @State private var granularity = TrendGranularity.daily

    private var points: [(Date, Int)] {
        switch granularity {
        case .daily:
            return store.snapshot.dailyUsage.map { ($0.date, $0.tokens) }
        case .hourly:
            let calendar = Calendar.current
            return Dictionary(grouping: store.snapshot.recentRecords.filter {
                $0.date >= .now.addingTimeInterval(-24 * 3_600)
            }, by: { calendar.dateInterval(of: .hour, for: $0.date)?.start ?? $0.date })
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.tokens }) }
            .sorted { $0.0 < $1.0 }
        }
    }

    private var total: Int { points.reduce(0) { $0 + $1.1 } }
    private var peak: Int { points.map(\.1).max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "使用趋势", subtitle: "按 Token 计数增量归属实际发生的日期和小时。", store: store)
            HStack {
                Picker("粒度", selection: $granularity) {
                    ForEach(TrendGranularity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                Text("总计 \(UsageFormatters.tokens(total)) Token")
                    .foregroundStyle(DashboardPalette.secondaryInk)
            }
            DashboardCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(granularity == .daily ? "近 7 天 Token 趋势" : "近 24 小时 Token 趋势").font(.headline)
                        Spacer()
                        Text("峰值 \(UsageFormatters.tokens(peak))").font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                    }
                    if points.isEmpty {
                        ContentUnavailableView("暂无趋势样本", systemImage: "chart.bar.xaxis")
                            .frame(maxWidth: .infinity, minHeight: 250)
                    } else {
                        TrendBars(points: points, hourly: granularity == .hourly)
                            .frame(height: 250)
                    }
                }
            }
            HStack(spacing: 16) {
                TrendMetric(title: "今天", value: UsageFormatters.tokens(store.snapshot.today.total))
                TrendMetric(title: "近 7 天", value: UsageFormatters.tokens(store.snapshot.lastSevenDays.total))
                TrendMetric(title: "本月", value: UsageFormatters.tokens(store.snapshot.thisMonth.total))
            }
        }
        .padding(28).frame(maxWidth: 1_100, alignment: .leading)
    }
}

private enum TrendGranularity: String, CaseIterable, Identifiable {
    case daily, hourly
    var id: String { rawValue }
    var title: String { self == .daily ? "按天" : "近 24 小时" }
}

struct TrendBars: View {
    let points: [(Date, Int)]
    let hourly: Bool
    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(1, points.map(\.1).max() ?? 1)
            HStack(alignment: .bottom, spacing: max(5, proxy.size.width / CGFloat(max(1, points.count)) * 0.16)) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    VStack(spacing: 7) {
                        Spacer(minLength: 0)
                        Text(UsageFormatters.tokens(point.1))
                            .font(.caption2).foregroundStyle(DashboardPalette.secondaryInk).lineLimit(1)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(DashboardPalette.chart)
                            .frame(width: min(32, proxy.size.width / CGFloat(max(1, points.count)) * 0.5),
                                   height: max(3, proxy.size.height * 0.65 * CGFloat(point.1) / CGFloat(maxValue)))
                        Text(point.0.formatted(hourly ? .dateTime.hour() : .dateTime.month().day()))
                            .font(.caption2).foregroundStyle(DashboardPalette.secondaryInk).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .help("\(point.0.formatted(date: .abbreviated, time: .shortened))：\(UsageFormatters.tokens(point.1)) Token")
                }
            }
        }
    }
}

private struct TrendMetric: View {
    let title: String; let value: String
    var body: some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                Text(value).font(.title2.weight(.medium)).foregroundStyle(DashboardPalette.ink).monospacedDigit()
                Text("Token 消耗").font(.caption2).foregroundStyle(DashboardPalette.secondaryInk)
            }
        }.frame(maxWidth: .infinity)
    }
}
