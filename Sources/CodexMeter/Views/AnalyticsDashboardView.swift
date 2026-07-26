import SwiftUI

@MainActor
struct AnalyticsDashboardView: View {
    let store: UsageStore
    var body: some View {
        Group {
            if #available(macOS 26.0, *) { glassDashboard } else { standardDashboard }
        }
        .navigationTitle("Codex Pulse")
        .task { await store.refresh() }
    }

    @available(macOS 26.0, *)
    private var glassDashboard: some View {
        ScrollView { UsagePopoverView(store: store, compact: false).padding(24) }
            .padding(18)
    }

    private var standardDashboard: some View {
        ScrollView { UsagePopoverView(store: store, compact: false).padding(24) }
            .background(.regularMaterial)
    }
}
