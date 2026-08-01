import SwiftUI

@MainActor
struct ProjectsUsageView: View {
    let store: UsageStore
    let pathStore: ProjectPathStore
    @State private var range = ProjectRange.sevenDays
    @State private var showFullPaths = false
    @State private var selectedPath: String?

    private var projects: [ProjectUsage] {
        let discovered: [ProjectUsage] = switch range {
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
                    Text("项目与用量").font(.system(size: 30, weight: .bold))
                    Text("按 Codex 会话记录中的本地工作目录归类；不会读取项目源码。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加项目目录", systemImage: "folder.badge.plus") { pathStore.addFolder() }
                    .buttonStyle(.borderedProminent)
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .disabled(store.isRefreshing)
            }

            HStack(spacing: 12) {
                Picker("时间范围", selection: $range) {
                    ForEach(ProjectRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                Toggle("显示完整路径", isOn: $showFullPaths)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Text("\(projects.count) 个项目 · \(UsageFormatters.tokens(totalTokens)) Token")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if projects.isEmpty {
                ContentUnavailableView(
                    "暂未识别到项目路径",
                    systemImage: "folder.badge.questionmark",
                    description: Text("继续使用 Codex 后会自动从会话的工作目录归类；也可以手动添加关注目录。")
                )
                .frame(maxWidth: .infinity, minHeight: 350)
            } else {
                VStack(spacing: 10) {
                    ForEach(projects, id: \.path) { project in
                        ProjectUsageRow(
                            project: project,
                            total: totalTokens,
                            showFullPath: showFullPaths,
                            isFollowed: pathStore.followedPaths.contains(project.path),
                            remove: { pathStore.remove(project.path) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { selectedPath = project.path }
                    }
                }
            }
        }
        .padding(28)
        .frame(minWidth: 900, maxWidth: 1_420, alignment: .leading)
        .sheet(item: Binding(
            get: { selectedPath.map(ProjectSelection.init) },
            set: { selectedPath = $0?.path }
        )) { selection in
            ProjectDetailSheet(
                project: projects.first { $0.path == selection.path } ?? ProjectUsage(path: selection.path, tokens: 0),
                records: store.snapshot.recentRecords.filter { $0.project == selection.path }
            )
        }
    }
}

private enum ProjectRange: String, CaseIterable, Identifiable {
    case today, sevenDays, thirtyDays
    var id: String { rawValue }
    var title: String { switch self { case .today: "今天"; case .sevenDays: "近 7 天"; case .thirtyDays: "近 30 天" } }
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
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: isFollowed ? "folder.fill.badge.checkmark" : "folder.fill")
                    .font(.title3).foregroundStyle(isFollowed ? .green : .blue).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.headline)
                    Text(showFullPath ? (project.path.isEmpty ? "会话未提供工作目录" : project.path) : project.name)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(UsageFormatters.tokens(project.tokens)).font(.headline).monospacedDigit()
                    Text("\(project.sessions) 个会话" + (project.lastActive.map { " · \($0.formatted(.dateTime.month().day().hour().minute()))" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isFollowed {
                    Button(role: .destructive, action: remove) { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).help("移除关注目录")
                }
            }
            ProgressView(value: Double(project.tokens), total: Double(max(1, total)))
                .tint(.blue)
        }
        .padding(16)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ProjectDetailSheet: View {
    let project: ProjectUsage
    let records: [UsageRecord]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(project.name).font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text(project.path.isEmpty ? "会话未提供工作目录" : project.path)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 18) {
                Label(UsageFormatters.tokens(project.tokens), systemImage: "number")
                Label("\(project.sessions) 个会话", systemImage: "bubble.left.and.bubble.right")
            }.font(.callout.weight(.medium))
            Divider()
            Text("最近会话").font(.headline)
            List(records.sorted { $0.date > $1.date }.prefix(12), id: \.date) { record in
                HStack { Text(record.model).lineLimit(1); Spacer(); Text(UsageFormatters.tokens(record.tokens)); Text(record.date, style: .date).foregroundStyle(.secondary) }
            }
        }
        .padding(22)
        .frame(width: 600, height: 460)
    }
}
