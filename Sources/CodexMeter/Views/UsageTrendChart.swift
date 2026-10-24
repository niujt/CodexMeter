import SwiftUI
import Charts

enum TrendChartStyle: String, CaseIterable, Identifiable {
    case bars, line, area, points
    static let preferenceKey = "codexMeter.trendChartStyle"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bars: "柱状图"
        case .line: "折线图"
        case .area: "面积图"
        case .points: "散点图"
        }
    }
    var symbol: String {
        switch self {
        case .bars: "chart.bar.fill"
        case .line: "chart.xyaxis.line"
        case .area: "chart.line.uptrend.xyaxis"
        case .points: "chart.dots.scatter"
        }
    }
}

struct TrendChartPicker: View {
    @Binding var selection: String
    var body: some View {
        Picker("图表类型", selection: $selection) {
            ForEach(TrendChartStyle.allCases) { style in
                Label(style.title, systemImage: style.symbol).tag(style.rawValue)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 120)
        .help("选择趋势图，默认为柱状图")
    }
}

struct UsageTrendChart: View {
    let samples: [TrendPoint]
    let hourly: Bool
    let style: TrendChartStyle
    @State private var hovered: TrendPoint?

    private var domain: ClosedRange<Date> {
        let first = samples.first?.date ?? .now
        let last = samples.last?.date ?? first
        return first...(last > first ? last : first.addingTimeInterval(hourly ? 3_600 : 86_400))
    }

    var body: some View {
        if style == .bars {
            TrendBars(samples: samples, hourly: hourly)
        } else {
            chart
        }
    }

    private var chart: some View {
        let segments = TrendSeries.contiguousSegments(samples)
        let maximum = max(1, samples.compactMap(\.tokens).max() ?? 1)
        return Chart {
            ForEach(Array(segments.enumerated()), id: \.offset) { segmentID, segment in
                ForEach(segment) { point in
                    if style == .area {
                        AreaMark(x: .value("时间", point.date), y: .value("Token", point.tokens ?? 0),
                                 series: .value("连续记录", segmentID))
                            .foregroundStyle(DashboardPalette.chart.opacity(0.18))
                            .interpolationMethod(.linear)
                    }
                    if style != .points {
                        LineMark(x: .value("时间", point.date), y: .value("Token", point.tokens ?? 0),
                                 series: .value("连续记录", segmentID))
                            .foregroundStyle(DashboardPalette.chart)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.linear)
                    }
                    PointMark(x: .value("时间", point.date), y: .value("Token", point.tokens ?? 0))
                        .foregroundStyle(DashboardPalette.chart)
                        .symbolSize(style == .points ? 35 : 18)
                }
            }
            if let hovered {
                RuleMark(x: .value("所选时间", hovered.date))
                    .foregroundStyle(DashboardPalette.secondaryInk.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...maximum)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: hourly ? 6 : 7)) { _ in
                AxisGridLine().foregroundStyle(DashboardPalette.divider)
                AxisValueLabel(format: hourly ? Date.FormatStyle.dateTime.hour() : Date.FormatStyle.dateTime.month().day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(DashboardPalette.divider)
                AxisValueLabel {
                    if let tokens = value.as(Int.self) {
                        Text(UsageFormatters.tokens(tokens))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else { return }
                            let frame = geometry[plotFrame]
                            guard frame.contains(location),
                                  let date: Date = proxy.value(atX: location.x - frame.minX) else {
                                hovered = nil
                                return
                            }
                            hovered = samples.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                        case .ended:
                            hovered = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let hovered {
                Text(detail(hovered))
                    .font(.caption2).padding(6)
                    .background(DashboardPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                    .allowsHitTesting(false)
            } else if samples.allSatisfy({ $0.tokens == nil }) {
                Text("暂无已记录用量")
                    .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
        }
        .onChange(of: style) { _, _ in hovered = nil }
        .onChange(of: samples) { _, _ in hovered = nil }
        .accessibilityLabel(style.title)
        .accessibilityValue("已记录 \(samples.compactMap(\.tokens).count) 个时间段；缺少记录的时间段不连线，也不作为零消耗")
    }

    private func detail(_ point: TrendPoint) -> String {
        let zone = TimeZone.current.abbreviation(for: point.date) ?? ""
        let value = point.tokens.map { "\(UsageFormatters.tokens($0)) Token" } ?? "未记录"
        return "\(point.date.formatted(date: .abbreviated, time: .shortened)) \(zone) · \(value)"
    }
}

