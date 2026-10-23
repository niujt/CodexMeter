import SwiftUI

struct DesktopWidgetView: View {
    let store: UsageStore
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Codex Health", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.headline)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DashboardPalette.secondaryInk)
                .help("隐藏桌面小组件")
            }

            HStack(spacing: 8) {
                Metric(title: "今天", value: UsageFormatters.tokens(store.snapshot.today.total))
                Metric(title: "近 7 天", value: UsageFormatters.tokens(store.snapshot.lastSevenDays.total))
                Metric(title: "本月", value: UsageFormatters.tokens(store.snapshot.thisMonth.total))
            }

            QuotaSampleView(title: "7 天剩余额度", window: store.snapshot.sevenDayRate,
                            sampledAt: store.snapshot.mainRateSampledAt, numberSize: 28,
                            showsResetTime: true, compactMetadata: true)

            if store.snapshot.contextWindow > 0 {
                HStack {
                    Text("当前上下文")
                    Spacer()
                    Text("\(UsageFormatters.tokens(store.snapshot.currentContextUsed)) / \(UsageFormatters.tokens(store.snapshot.contextWindow))")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(DashboardPalette.secondaryInk)
            }

            Spacer(minLength: 0)
            HStack {
                UsageRefreshStatusView(store: store, compact: true)
                Spacer()
                Button {
                    Task { await store.refresh(userInitiated: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
                .help("刷新本机用量")
                .accessibilityLabel("刷新本机用量")
            }
            .font(.caption)
            .foregroundStyle(DashboardPalette.secondaryInk)
        }
        .padding(16)
        .frame(width: 300, height: 320, alignment: .topLeading)
        .foregroundStyle(DashboardPalette.ink)
        .tint(DashboardPalette.ink)
        .progressViewStyle(FlatProgressStyle())
        .modifier(PeripheralGlass(cornerRadius: 20))
    }

}

private struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(DashboardPalette.secondaryInk)
            Text(value)
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}
