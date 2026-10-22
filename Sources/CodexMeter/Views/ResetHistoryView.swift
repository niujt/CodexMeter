import SwiftUI

struct ResetHistoryView: View {
    let store: UsageStore
    @State private var showsAllEvents = false

    private var history: ResetHistoryStore { store.resetHistory }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("使用限额重置", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                Text("账户历史").font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                Button(history.isLoading ? "读取中…" : "刷新重置历史") {
                    Task { await refresh(force: true) }
                }
                .disabled(history.isLoading || store.context?.quotaScope == nil)
            }
            if history.isLoading {
                ProgressView(history.hasLoaded ? "正在补取新记录…" : "正在读取重置历史…").controlSize(.small)
            } else if let error = history.error {
                Text(error).font(.callout).foregroundStyle(DashboardPalette.secondaryInk)
            } else if history.hasLoaded && history.events.isEmpty {
                Text("暂无获得或使用重置次数的记录。")
                    .font(.callout).foregroundStyle(DashboardPalette.secondaryInk)
            } else if !history.hasLoaded {
                Text(store.context?.quotaScope == nil ? store.accountStatus : "自动同步当前账户的重置历史，已同步的记录会保存在本地；仅查询，不消耗重置次数。")
                    .font(.callout).foregroundStyle(DashboardPalette.secondaryInk)
            }
            if let warning = history.persistenceWarning {
                Text(warning).font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
            if let checkedAt = history.loadedAt {
                Text("\(history.hasSavedHistory ? "本地已保存" : "当前已读取") \(history.events.count) 条 · 最近同步 \(checkedAt.formatted(.dateTime.month().day().hour().minute()))")
                    .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
            ForEach(Array(history.events.prefix(showsAllEvents ? history.events.count : 10))) { event in
                HStack {
                    Text(event.title).font(.callout)
                    Spacer()
                    Text(event.occurredAt.formatted(.dateTime.year().month().day().hour().minute().timeZone()))
                        .font(.callout.monospacedDigit()).foregroundStyle(DashboardPalette.secondaryInk)
                }
                .padding(.vertical, 5)
                FlatDivider()
            }
            if history.events.count > 10 {
                Button(showsAllEvents ? "收起" : "更多（剩余 \(history.events.count - 10) 条）") {
                    showsAllEvents.toggle()
                }.buttonStyle(.plain).foregroundStyle(DashboardPalette.secondaryInk)
            }
        }
        .task(id: store.context?.id) {
            showsAllEvents = false
            await refresh()
        }
    }

    @MainActor
    private func refresh(force: Bool = false) async {
        store.synchronizeContext()
        await history.refresh(context: store.context, force: force)
        if force { showsAllEvents = false }
    }
}
