import SwiftUI

/// Shared quota display for dashboard, popover and desktop windows.
struct QuotaSampleView: View {
    let title: String
    let window: RateWindow?
    let sampledAt: Date?
    var numberSize: CGFloat = 28

    var body: some View {
        TimelineView(.explicit([Date.now] + QuotaSampleState.deadlines(sampledAt: sampledAt, resetsAt: window?.resetsAt))) { context in
            let sample = QuotaSampleState(percent: window?.usedPercent, sampledAt: sampledAt, resetsAt: window?.resetsAt, now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                Text(sample.isStale && sample.recordedRemaining != nil ? "\(title) · 上次记录" : title)
                    .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                Text(sample.recordedRemaining.map { "\($0)%" } ?? "—")
                    .font(.system(size: numberSize, weight: .medium)).monospacedDigit()
                if let remaining = sample.recordedRemaining {
                    ProgressView(value: Double(remaining), total: 100)
                        .tint(DashboardPalette.progress)
                    if sample.isStale {
                        Text("等待新采样").font(.caption2).foregroundStyle(DashboardPalette.secondaryInk)
                    }
                }
                Text(sample.description).font(.caption2).foregroundStyle(DashboardPalette.secondaryInk)
            }
        }
    }
}

struct RateLimitView: View {
    let title: String
    let window: RateWindow
    var sampledAt: Date? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            QuotaSampleView(title: title, window: window, sampledAt: sampledAt, numberSize: 20)
            Text("约 \(UsageFormatters.countdown(to: window.resetsAt)) 后重置")
                .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
        }
    }
}
