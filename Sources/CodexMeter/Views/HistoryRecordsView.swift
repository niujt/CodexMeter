import SwiftUI

@MainActor
struct HistoryRecordsView: View {
    let store: UsageStore
    @Bindable var viewState: DashboardViewState

    init(store: UsageStore, viewState: DashboardViewState? = nil) {
        self.store = store
        self.viewState = viewState ?? DashboardViewState()
    }

    private var records: [UsageRecord] {
        let cutoff = Date.now.addingTimeInterval(-Double(viewState.historyRange.days) * 86_400)
        return store.snapshot.recentRecords
            .filter { $0.date >= cutoff }
            .filter { viewState.historyModel == "全部" || $0.model == viewState.historyModel }
            .filter { viewState.historyProject == "全部" || $0.project == viewState.historyProject }
            .sorted { $0.date > $1.date }
    }
    private var models: [String] { ["全部"] + Array(Set(store.snapshot.recentRecords.map(\.model))).sorted() }
    private var projects: [String] { ["全部"] + Array(Set(store.snapshot.recentRecords.map(\.project))).sorted() }
    private var total: Int { records.reduce(0) { $0 + $1.tokens } }
    private var grouped: [(Date, [UsageRecord])] {
        let calendar = Calendar.current
        return Dictionary(grouping: records, by: { calendar.startOfDay(for: $0.date) })
            .sorted { $0.key > $1.key }
    }
    private var rateTimeline: [RateTimelineEvent] {
        let cutoff = Date.now.addingTimeInterval(-Double(viewState.historyRange.days) * 86_400)
        return store.snapshot.rateTimeline.filter { $0.date >= cutoff }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "历史记录", subtitle: "按小时、模型和工作目录汇总 Token 增量，不保存或展示会话正文。", store: store)
            DashboardCard {
                ResetHistoryView(store: store)
            }
            HStack(spacing: 12) {
                Picker("范围", selection: $viewState.historyRange) {
                    ForEach(HistoryRange.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
                Picker("模型", selection: $viewState.historyModel) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }.frame(maxWidth: 220)
                Picker("项目", selection: $viewState.historyProject) {
                    ForEach(projects, id: \.self) { Text($0.isEmpty ? "未归属路径" : URL(fileURLWithPath: $0).lastPathComponent).tag($0) }
                }.frame(maxWidth: 220)
                Spacer()
                Text("\(records.count) 条 · \(UsageFormatters.tokens(total)) Token")
                    .foregroundStyle(DashboardPalette.secondaryInk)
            }
            if !rateTimeline.isEmpty {
                DashboardCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("7 天额度周期时间线", systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline)
                            Spacer()
                            Text("按重置周期合并 · 仅本机记录")
                                .font(.caption)
                                .foregroundStyle(DashboardPalette.secondaryInk)
                        }
                        ForEach(Array(rateTimeline.prefix(viewState.showsAllHistoryCycles ? rateTimeline.count : 10).enumerated()), id: \.offset) { index, event in
                            ResetTimelineRow(event: event, isLatest: index == 0 && event.resetsAt > .now)
                        }
                        if rateTimeline.count > 10 {
                            Button(viewState.showsAllHistoryCycles ? "收起" : "更多（剩余 \(rateTimeline.count - 10) 个）") {
                                viewState.showsAllHistoryCycles.toggle()
                            }
                            .buttonStyle(.plain).foregroundStyle(DashboardPalette.secondaryInk)
                        }
                    }
                }
            }
            if records.isEmpty {
                ContentUnavailableView("没有符合条件的本地记录", systemImage: "clock.badge.questionmark", description: Text("当前可浏览最近 30 天内已写入 Token 计数的会话记录。"))
                    .frame(maxWidth: .infinity, minHeight: 380)
            } else {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(grouped, id: \.0) { day, dayRecords in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(day.formatted(.dateTime.year().month().day().weekday())).font(.headline)
                                Spacer()
                                Text(UsageFormatters.tokens(dayRecords.reduce(0) { $0 + $1.tokens })).font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                            }
                            ForEach(Array(dayRecords.enumerated()), id: \.offset) { _, record in
                                HistoryRecordRow(record: record)
                            }
                        }
                    }
                }
            }
        }
        .padding(28).frame(maxWidth: 1_100, alignment: .leading)
        .onChange(of: viewState.historyRange) { viewState.showsAllHistoryCycles = false }
        .onChange(of: store.context?.id) { viewState.showsAllHistoryCycles = false }
    }
}

private struct ResetTimelineRow: View {
    let event: RateTimelineEvent
    let isLatest: Bool

    private var used: Int { Int(event.usedPercent.rounded()) }
    private var remaining: Int { max(0, 100 - used) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isLatest ? "clock.arrow.circlepath" : "circle.fill")
                .font(.callout)
                .foregroundStyle(isLatest ? DashboardPalette.ink : DashboardPalette.secondaryInk)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(isLatest ? "当前额度周期" : "已观察到的额度周期")
                    .font(.callout.weight(.semibold))
                Text("本周期累计 \(UsageFormatters.tokens(event.tokens)) Token · 本机已记录")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .help("按本地 Token 增量统计；重置时间改变后单独累计，不包含其他设备或未记录的使用量。")
                Text("最近采样 \(event.date.formatted(.dateTime.month().day().hour().minute())) · 已用 \(used)% · 剩余 \(remaining)%")
                    .font(.caption)
                    .foregroundStyle(DashboardPalette.secondaryInk)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("重置时间")
                    .font(.caption2)
                    .foregroundStyle(DashboardPalette.secondaryInk)
                Text(event.resetsAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            if !isLatest { FlatDivider() }
        }
    }
}

private struct HistoryRecordRow: View {
    let record: UsageRecord
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "clock").foregroundStyle(DashboardPalette.ink).frame(width: 20)
            Text(record.date.formatted(.dateTime.hour().minute()))
                .font(.callout.monospacedDigit()).frame(width: 50, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.model).font(.callout.weight(.semibold)).lineLimit(1)
                Text(record.project.isEmpty ? "未归属工作目录" : record.project)
                    .font(.caption).foregroundStyle(DashboardPalette.secondaryInk).lineLimit(1).textSelection(.enabled)
            }
            Spacer()
            Text(UsageFormatters.tokens(record.tokens))
                .font(.callout.weight(.semibold)).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .overlay(alignment: .bottom) { FlatDivider() }
    }
}
