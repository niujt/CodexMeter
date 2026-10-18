import SwiftUI

@MainActor
struct AnalyticsDashboardView: View {
    let store: UsageStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedSection: String? = "健康报告"
    @State private var projectPathStore = ProjectPathStore()
    @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.system.rawValue

    private var appearanceMode: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(selection: $selectedSection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            ScrollView {
                Group {
                    switch selectedSection ?? "健康报告" {
                    case "健康报告":
                        DashboardContent(
                            snapshot: store.snapshot,
                            errorMessage: store.errorMessage,
                            isRefreshing: store.isRefreshing,
                            measuredVelocity: store.measuredVelocity?.percentPerHour,
                            quotaMessage: store.quotaWaitingMessage,
                            chooseFolder: { store.chooseCodexFolder() }
                        )
                            .padding(28)
                            .frame(maxWidth: 1_100, alignment: .leading)
                    case "项目与用量":
                        ProjectsUsageView(store: store, pathStore: projectPathStore)
                    case "使用趋势":
                        UsageTrendsView(store: store)
                    case "模型与效率":
                        ModelEfficiencyView(store: store)
                    case "预测与风险":
                        ForecastRiskView(store: store)
                    case "历史记录":
                        HistoryRecordsView(store: store)
                    default:
                        FeaturePlaceholderView(section: selectedSection ?? "健康报告")
                            .frame(minHeight: 500)
                    }
                }
                .id(selectedSection)
                .transition(.opacity)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: selectedSection)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DashboardPalette.canvas)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if store.isRefreshing {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(store.loadingMessage)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.bar)
            }
        }
        .foregroundStyle(DashboardPalette.ink)
        .tint(DashboardPalette.ink)
        .progressViewStyle(FlatProgressStyle())
        .preferredColorScheme(appearanceMode.colorScheme)
        .onChange(of: appearance) { _, _ in AppIconStyle.applyDockIcon() }
        .navigationTitle("Codex Health")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WeeklyReceiptButton(snapshot: store.snapshot)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("刷新本机用量") { Task { await store.refresh(userInitiated: true) } }
                    Button("重新读取全部记录") { Task { await store.refresh(force: true, userInitiated: true) } }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                } primaryAction: {
                    Task { await store.refresh(userInitiated: true) }
                }
                .disabled(store.isRefreshing)
                .help("刷新本机用量；展开菜单可重新读取全部记录")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    ForEach(AppAppearance.allCases) { mode in
                        Button { appearance = mode.rawValue } label: {
                            Label(mode.title, systemImage: appearance == mode.rawValue ? "checkmark" : mode.icon)
                        }
                    }
                } label: {
                    Label("外观", systemImage: appearanceMode.icon)
                }
                Button { openSettings() } label: { Label("设置", systemImage: "gearshape") }
            }
        }
        .task { await store.refreshIfNeeded() }
    }
}

private struct FeaturePlaceholderView: View {
    let section: String
    var body: some View {
        ContentUnavailableView(
            "\(section)正在实现",
            systemImage: "hammer.fill",
            description: Text("此页面不再展示模拟数据。下一步将按功能计划接入本机 Codex 记录。")
        )
        .foregroundStyle(DashboardPalette.secondaryInk)
    }
}
