import SwiftUI

struct RateLimitView: View {
    let title: String
    let window: RateWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("剩余 \(max(0, 100 - Int(window.usedPercent.rounded())))%")
                    .monospacedDigit()
            }
            .font(.callout.weight(.medium))

            ProgressView(value: max(0, 100 - min(window.usedPercent, 100)), total: 100)
                .tint(.green)

            Text("约 \(UsageFormatters.countdown(to: window.resetsAt)) 后重置")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
