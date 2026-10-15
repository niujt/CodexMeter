import SwiftUI

struct ResetHistoryView: View {
    let store: UsageStore
    @State private var events: [ResetHistoryEvent] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var showsAllEvents = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("使用限额重置", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                Text("过去 30 天 · 账户记录").font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                Button(isLoading ? "读取中…" : (hasLoaded ? "刷新重置历史" : "读取重置历史")) {
                    Task { await refresh() }
                }
                .disabled(isLoading || store.context?.quotaScope == nil)
            }
            if isLoading {
                ProgressView("正在读取重置历史…").controlSize(.small)
            } else if let error {
                Text(error).font(.callout).foregroundStyle(DashboardPalette.secondaryInk)
            } else if hasLoaded && events.isEmpty {
                Text("过去 30 天没有获得或使用重置次数的记录。")
                    .font(.callout).foregroundStyle(DashboardPalette.secondaryInk)
            } else if !hasLoaded {
                Text(store.context?.quotaScope == nil ? store.accountStatus : "点击后使用所选目录的当前登录向 ChatGPT 查询，仅查询，不消耗重置次数。")
                    .font(.callout).foregroundStyle(DashboardPalette.secondaryInk)
            }
            ForEach(Array(events.prefix(showsAllEvents ? events.count : 10))) { event in
                HStack {
                    Text(event.title).font(.callout)
                    Spacer()
                    Text(event.occurredAt.formatted(.dateTime.year().month().day().hour().minute().timeZone()))
                        .font(.callout.monospacedDigit()).foregroundStyle(DashboardPalette.secondaryInk)
                }
                .padding(.vertical, 5)
                FlatDivider()
            }
            if events.count > 10 {
                Button(showsAllEvents ? "收起" : "更多（剩余 \(events.count - 10) 条）") {
                    showsAllEvents.toggle()
                }.buttonStyle(.plain).foregroundStyle(DashboardPalette.secondaryInk)
            }
        }
        .task(id: store.context?.id) {
            requestID = UUID()
            events = []
            showsAllEvents = false
            hasLoaded = false
            isLoading = false
            error = nil
        }
    }

    @MainActor
    private func refresh() async {
        store.synchronizeContext()
        guard !isLoading, let context = store.context, context.quotaScope != nil else { return }
        let id = UUID()
        requestID = id
        isLoading = true
        error = nil
        do {
            let loaded = try await ResetHistoryClient().load(context: context)
            guard requestID == id, store.context?.id == context.id else { return }
            events = loaded
            showsAllEvents = false
            hasLoaded = true
        } catch {
            guard requestID == id, store.context?.id == context.id else { return }
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
