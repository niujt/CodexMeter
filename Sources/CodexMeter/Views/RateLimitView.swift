import SwiftUI

/// Shared quota display for dashboard, popover and desktop windows.
struct QuotaSampleView: View {
    let title: String
    let window: RateWindow?
    let sampledAt: Date?
    var numberSize: CGFloat = 28
    var secondaryInk: Color = DashboardPalette.secondaryInk
    var showsResetTime = false
    var compactMetadata = false

    var body: some View {
        TimelineView(.explicit([Date.now] + QuotaSampleState.deadlines(sampledAt: sampledAt, resetsAt: window?.resetsAt))) { context in
            let sample = QuotaSampleState(percent: window?.usedPercent, sampledAt: sampledAt, resetsAt: window?.resetsAt, now: context.date)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(title).font(.caption).foregroundStyle(secondaryInk)
                    if sample.isStale && sample.recordedRemaining != nil {
                        sampleBadge("上次记录", icon: "clock")
                    } else if let remaining = sample.recordedRemaining, remaining < 20 {
                        sampleBadge("额度紧张", icon: "exclamationmark.triangle.fill")
                    } else if sample.recordedRemaining == nil {
                        sampleBadge("待更新", icon: "hourglass")
                    }
                }
                Text(sample.recordedRemaining.map { "\($0)%" } ?? "—")
                    .font(.system(size: numberSize, weight: .medium)).monospacedDigit()
                if let remaining = sample.recordedRemaining {
                    ProgressView(value: Double(remaining), total: 100)
                        .tint(DashboardPalette.progress)
                    if sample.isStale {
                        Text("等待新采样").font(.caption2).foregroundStyle(secondaryInk)
                    }
                }
                Text(sampleDescription(sample, at: context.date))
                    .font(.caption2).foregroundStyle(secondaryInk)
                    .help(sample.description)
                if showsResetTime, let window, window.resetsAt > context.date,
                   sample.recordedRemaining != nil {
                    Text("重置于 \(window.resetsAt.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.caption2).foregroundStyle(secondaryInk)
                        .help("本地采样记录的重置时间：\(window.resetsAt.formatted(date: .complete, time: .standard))")
                }
            }
        }
    }

    private func sampleBadge(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(DashboardPalette.ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(DashboardPalette.divider, lineWidth: 1))
            .fixedSize()
    }

    private func sampleDescription(_ sample: QuotaSampleState, at now: Date) -> String {
        guard compactMetadata, !sample.isStale, sample.recordedRemaining != nil,
              let sampledAt, sampledAt <= now else { return sample.description }
        let timestamp = Calendar.current.isDate(sampledAt, inSameDayAs: now)
            ? sampledAt.formatted(.dateTime.hour().minute())
            : sampledAt.formatted(.dateTime.month().day().hour().minute())
        return "本地采样 · \(timestamp) · 非实时"
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
