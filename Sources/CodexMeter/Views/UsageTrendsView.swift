import SwiftUI

@MainActor
struct UsageTrendsView: View {
    let store: UsageStore
    @Bindable var viewState: DashboardViewState

    init(store: UsageStore, viewState: DashboardViewState? = nil) {
        self.store = store
        self.viewState = viewState ?? DashboardViewState()
    }

    private var points: [TrendPoint] {
        switch viewState.trendGranularity {
        case .daily:
            return store.snapshot.dailyUsage.map { TrendPoint(date: $0.date, tokens: $0.tokens) }
        case .hourly:
            return TrendSeries.hourly(records: store.snapshot.recentRecords)
        }
    }

    private var total: Int { points.compactMap(\.tokens).reduce(0, +) }
    private var peak: Int? { points.compactMap(\.tokens).max() }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "使用趋势", subtitle: "按 Token 计数增量归属实际发生的日期和小时。", store: store)
            HStack {
                Picker("粒度", selection: $viewState.trendGranularity) {
                    ForEach(TrendGranularity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                Text("已记录总计 \(UsageFormatters.tokens(total)) Token")
                    .foregroundStyle(DashboardPalette.secondaryInk)
            }
            DashboardCard {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(viewState.trendGranularity == .daily ? "近 7 天 Token 趋势" : "近 24 小时 Token 趋势").font(.headline)
                        Spacer()
                        Text(peak.map { "峰值 \(UsageFormatters.tokens($0))" } ?? "暂无记录")
                            .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                    }
                    if points.isEmpty {
                        ContentUnavailableView("暂无趋势样本", systemImage: "chart.bar.xaxis")
                            .frame(maxWidth: .infinity, minHeight: 250)
                    } else {
                        TrendBars(samples: points, hourly: viewState.trendGranularity == .hourly)
                            .frame(height: 250)
                    }
                    if viewState.trendGranularity == .hourly {
                        Text("连续 24 个小时，含当前未结束的小时。— 表示未记录 Token 增量，不能据此判断消耗为 0。")
                            .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
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

struct TrendBars: View {
    let samples: [TrendPoint]
    let hourly: Bool

    init(points: [(Date, Int)], hourly: Bool) {
        self.samples = points.map { TrendPoint(date: $0.0, tokens: $0.1) }
        self.hourly = hourly
    }

    init(samples: [TrendPoint], hourly: Bool) {
        self.samples = samples
        self.hourly = hourly
    }

    var body: some View {
        GeometryReader { proxy in
            let maxValue = max(1, samples.compactMap(\.tokens).max() ?? 1)
            let slotWidth = proxy.size.width / CGFloat(max(1, samples.count))
            let labelStep = max(1, Int(ceil(42 / max(1, slotWidth))))
            HStack(alignment: .bottom, spacing: max(2, slotWidth * 0.16)) {
                ForEach(Array(samples.enumerated()), id: \.element.id) { index, point in
                    VStack(spacing: 7) {
                        Spacer(minLength: 0)
                        Text(point.tokens.map(UsageFormatters.tokens) ?? "—")
                            .font(.caption2).foregroundStyle(DashboardPalette.secondaryInk)
                            .lineLimit(1)
                            .opacity(index % labelStep == 0 ? 1 : 0)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(point.tokens == nil ? DashboardPalette.divider : DashboardPalette.chart)
                            .frame(width: min(32, slotWidth * 0.5),
                                   height: max(3, proxy.size.height * 0.65 * CGFloat(point.tokens ?? 0) / CGFloat(maxValue)))
                        Text(point.date.formatted(hourly ? .dateTime.hour() : .dateTime.month().day()))
                            .font(.caption2).foregroundStyle(DashboardPalette.secondaryInk).lineLimit(1)
                            .opacity(index % labelStep == 0 ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .help(detail(for: point))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(detail(for: point))
                }
            }
        }
    }

    private func detail(for point: TrendPoint) -> String {
        let zone = TimeZone.current.abbreviation(for: point.date) ?? ""
        let time = point.date.formatted(date: .abbreviated, time: .shortened)
        let value = point.tokens.map { "\(UsageFormatters.tokens($0)) Token" } ?? "未记录 Token 增量"
        return "\(time) \(zone)：\(value)"
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
