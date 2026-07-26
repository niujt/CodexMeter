import SwiftUI

struct RateLimitView: View {
    let title: String
    let window: RateWindow

    private var remaining: Int { max(0, 100 - Int(window.usedPercent.rounded())) }
    private var quotaColor: Color {
        if remaining < 20 { return .red }
        if remaining < 50 { return .yellow }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("剩余 \(remaining)%")
                    .monospacedDigit()
                    .foregroundStyle(quotaColor)
            }
            .font(.callout.weight(.medium))

            ProgressView(value: max(0, 100 - min(window.usedPercent, 100)), total: 100)
                .tint(quotaColor)

            Text("约 \(UsageFormatters.countdown(to: window.resetsAt)) 后重置")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
