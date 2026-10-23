import SwiftUI

@MainActor
struct ProjectsUsageView: View {
    let store: UsageStore
    let pathStore: ProjectPathStore
    @Bindable var viewState: DashboardViewState
    @State private var selectedPath: String?

    init(store: UsageStore, pathStore: ProjectPathStore, viewState: DashboardViewState? = nil) {
        self.store = store
        self.pathStore = pathStore
        self.viewState = viewState ?? DashboardViewState()
    }

    private var projects: [ProjectUsage] {
        let discovered: [ProjectUsage] = switch viewState.projectRange {
        case .today: store.snapshot.todayProjects
        case .sevenDays: store.snapshot.allProjects
        case .thirtyDays: store.snapshot.monthProjects
        }
        let known = Set(discovered.map(\.path))
        let followedOnly = pathStore.followedPaths
            .filter { !known.contains($0) }
            .map { ProjectUsage(path: $0, tokens: 0) }
        return discovered + followedOnly
    }

    private var totalTokens: Int { projects.reduce(0) { $0 + $1.tokens } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("项目与用量").font(.system(size: 24, weight: .semibold))
                    Text("按 Codex 会话记录中的本地工作目录归类；不会读取项目源码。")
                        .font(.subheadline).foregroundStyle(DashboardPalette.secondaryInk)
                }
                Spacer()
                Button("添加项目目录", systemImage: "folder.badge.plus") { pathStore.addFolder() }
                    .buttonStyle(.bordered)
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .disabled(store.isRefreshing)
            }

            HStack(spacing: 12) {
                Picker("时间范围", selection: $viewState.projectRange) {
                    ForEach(ProjectRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .frame(width: 280)
                Toggle("显示完整路径", isOn: $viewState.showsFullProjectPaths)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Text("\(projects.count) 个项目 · \(UsageFormatters.tokens(totalTokens)) Token")
                    .font(.callout).foregroundStyle(DashboardPalette.secondaryInk)
            }

            if projects.isEmpty {
                ContentUnavailableView(
                    "暂未识别到项目路径",
                    systemImage: "folder.badge.questionmark",
                    description: Text("继续使用 Codex 后会自动从会话的工作目录归类；也可以手动添加关注目录。")
                )
                .frame(maxWidth: .infinity, minHeight: 350)
            } else {
                VStack(spacing: 0) {
                    ForEach(projects, id: \.path) { project in
                        ProjectUsageRow(
                            project: project,
                            total: totalTokens,
                            showFullPath: viewState.showsFullProjectPaths,
                            isFollowed: pathStore.followedPaths.contains(project.path),
                            showDetails: { selectedPath = project.path },
                            remove: { pathStore.remove(project.path) }
                        )
                    }
                }
            }
        }
        .padding(28)
        .tint(DashboardPalette.ink)
        .progressViewStyle(FlatProgressStyle())
        .frame(maxWidth: 1_100, alignment: .leading)
        .sheet(item: Binding(
            get: { selectedPath.map(ProjectSelection.init) },
            set: { selectedPath = $0?.path }
        )) { selection in
            ProjectDetailSheet(
                project: projects.first { $0.path == selection.path } ?? ProjectUsage(path: selection.path, tokens: 0),
                range: viewState.projectRange,
                records: viewState.projectRange.records(store.snapshot.recentRecords, projectPath: selection.path)
            )
        }
    }
}

private struct ProjectSelection: Identifiable {
    let path: String
    var id: String { path }
}

private struct ProjectUsageRow: View {
    let project: ProjectUsage
    let total: Int
    let showFullPath: Bool
    let isFollowed: Bool
    let showDetails: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button(action: showDetails) {
                    HStack(spacing: 14) {
                        Image(systemName: isFollowed ? "folder.fill.badge.checkmark" : "folder.fill")
                            .font(.title3).foregroundStyle(DashboardPalette.secondaryInk).frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(project.name).font(.headline)
                            Text(showFullPath ? (project.path.isEmpty ? "会话未提供工作目录" : project.path) : project.name)
                                .font(.caption).foregroundStyle(DashboardPalette.secondaryInk).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 5) {
                            Text(UsageFormatters.tokens(project.tokens)).font(.headline).monospacedDigit()
                            Text("\(project.sessions) 个会话" + (project.lastActive.map { " · \($0.formatted(.dateTime.month().day().hour().minute()))" } ?? ""))
                                .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(DashboardPalette.secondaryInk)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("查看 \(project.name) 的用量记录")
                .accessibilityLabel("查看 \(project.name) 的用量记录")
                .accessibilityValue("\(UsageFormatters.tokens(project.tokens)) Token，\(project.sessions) 个会话")
                if isFollowed {
                    Button(role: .destructive, action: remove) { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).help("移除关注目录")
                        .accessibilityLabel("移除关注目录 \(project.name)")
                }
            }
            ProgressView(value: Double(project.tokens), total: Double(max(1, total)))
                .tint(DashboardPalette.progress)
        }
        .padding(.vertical, 18)
        .overlay(alignment: .bottom) { FlatDivider() }
    }
}

private struct ProjectDetailSheet: View {
    let project: ProjectUsage
    let range: ProjectRange
    let records: [UsageRecord]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(project.name).font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(project.path.isEmpty ? "会话未提供工作目录" : project.path)
                .font(.caption).foregroundStyle(DashboardPalette.secondaryInk).textSelection(.enabled)
            HStack(spacing: 18) {
                Text(range.title)
                Label(UsageFormatters.tokens(project.tokens), systemImage: "number")
                Label("\(project.sessions) 个会话", systemImage: "bubble.left.and.bubble.right")
            }.font(.callout.weight(.medium))
            FlatDivider()
            VStack(alignment: .leading, spacing: 4) {
                Text("最近用量记录").font(.headline)
                Text("\(range.title) · 本机已记录 \(records.count) 条，显示最近 \(min(12, records.count)) 条")
                    .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
            if records.isEmpty {
                ContentUnavailableView("所选范围内暂无用量记录", systemImage: "clock.badge.questionmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(records.prefix(12).enumerated()), id: \.offset) { _, record in
                    HStack {
                        Text(record.model).lineLimit(1)
                        Spacer()
                        Text(UsageFormatters.tokens(record.tokens)).monospacedDigit()
                        Text(record.date.formatted(.dateTime.month().day().hour().minute()))
                            .foregroundStyle(DashboardPalette.secondaryInk)
                    }
                }
            }
            Text("按小时和模型汇总所选目录中的 Token 增量；未记录不代表消耗为 0。")
                .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
        }
        .padding(22)
        .frame(width: 600, height: 460)
    }
}
