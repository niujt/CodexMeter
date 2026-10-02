import SwiftUI

struct ResetHistoryView: View {
    let codexPath: String
    @State private var events: [ResetHistoryEvent] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("使用限额重置", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                Text("过去 30 天 · 账户记录").font(.caption).foregroundStyle(.secondary)
                Button(isLoading ? "读取中…" : (hasLoaded ? "刷新重置历史" : "读取重置历史")) {
                    Task { await refresh() }
                }
                .disabled(isLoading)
            }
            if isLoading {
                ProgressView("正在读取重置历史…").controlSize(.small)
            } else if let error {
                Text(error).font(.callout).foregroundStyle(.secondary)
            } else if hasLoaded && events.isEmpty {
                Text("过去 30 天没有获得或使用重置次数的记录。")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !hasLoaded {
                Text("将自动查询重置历史，仅查询，不消耗重置次数。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(events) { event in
                HStack {
                    Text(event.title).font(.callout)
                    Spacer()
                    Text(event.occurredAt.formatted(.dateTime.year().month().day().hour().minute().timeZone()))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 5)
                Divider()
            }
        }
        .task(id: codexPath) {
            requestID = UUID()
            events = []
            hasLoaded = false
            isLoading = false
            error = nil
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        let id = UUID()
        requestID = id
        isLoading = true
        error = nil
        do {
            let loaded = try await ResetHistoryClient().load(codexPath: codexPath)
            guard requestID == id else { return }
            events = loaded
            hasLoaded = true
        } catch {
            guard requestID == id else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
