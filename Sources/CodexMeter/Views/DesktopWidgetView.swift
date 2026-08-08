import SwiftUI

struct DesktopWidgetView: View {
    let store: UsageStore
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Codex Health", systemImage: "gauge.with.dots.needle.33percent")
                    .font(.headline)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("隐藏桌面小组件")
            }

            HStack(spacing: 8) {
                Metric(title: "今天", value: UsageFormatters.tokens(store.snapshot.today.total))
                Metric(title: "近 7 天", value: UsageFormatters.tokens(store.snapshot.lastSevenDays.total))
                Metric(title: "本月", value: UsageFormatters.tokens(store.snapshot.thisMonth.total))
            }

            if store.snapshot.contextWindow > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("当前上下文")
                        Spacer()
                        Text("\(UsageFormatters.tokens(store.snapshot.currentContextUsed)) / \(UsageFormatters.tokens(store.snapshot.contextWindow))")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    ProgressView(
                        value: Double(store.snapshot.currentContextUsed),
                        total: Double(store.snapshot.contextWindow)
                    )
                }
            }

            if let window = store.snapshot.primaryRate {
                HStack {
                    Text(rateTitle(window))
                    Spacer()
                    Text("\(window.usedPercent, specifier: "%.0f")%")
                        .monospacedDigit()
                }
                .font(.caption.weight(.medium))
                ProgressView(value: min(window.usedPercent, 100), total: 100)
                    .tint(window.usedPercent >= 90 ? .red : .accentColor)
            } else {
                Text("等待新周期数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
            HStack {
                Text("低功耗自动刷新")
                Spacer()
                Button {
                    Task { await store.refresh(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 300, height: 245, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func rateTitle(_ window: RateWindow) -> String {
        window.windowMinutes == 10_080 ? "7 天额度" : "5 小时额度"
    }
}

private struct Metric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
    }
}
