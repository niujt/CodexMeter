import SwiftUI

@main
struct CodexMeterApp: App {
    @State private var store = UsageStore()

    var body: some Scene {
        Window("Codex Pulse", id: "dashboard") {
            AnalyticsDashboardView(store: store)
                .frame(minWidth: 680, minHeight: 460)
        }
        MenuBarExtra {
            UsagePopoverView(store: store, compact: true)
        } label: {
            MenuBarUsageLabel(rate: store.snapshot.sevenDayRate)
        }
        .menuBarExtraStyle(.window)
    }
}

extension UsageSnapshot {
    var sevenDayRate: RateWindow? {
        [primaryRate, secondaryRate].compactMap { $0 }.first { $0.windowMinutes == 10_080 }
            ?? secondaryRate
            ?? primaryRate
    }
}

private struct MenuBarUsageLabel: View {
    let rate: RateWindow?

    var body: some View {
        let remaining = max(0, 100 - Int((rate?.usedPercent ?? 0).rounded()))
        HStack(spacing: 4) {
            Image("CodexUsageTemplate")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 18, height: 18)
            Text("\(remaining)%")
                .monospacedDigit()
        }
    }
}
