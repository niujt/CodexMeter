import AppKit
import SwiftUI
import Observation

// The documentation app owns its own bundle ID and only in-memory demo values.
enum ScreenshotFixture {
    static let now = Date.now
    static func tokens(_ total: Int) -> TokenUsage {
        let input = Int((Double(total) * 0.86).rounded())
        return TokenUsage(input: input, cachedInput: Int(Double(input) * 0.6), output: total - input,
                          reasoningOutput: Int(Double(total - input) * 0.3), total: total)
    }
    static let snapshot: UsageSnapshot = {
        var result = UsageSnapshot.empty
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let amounts = [92_000, 186_000, 126_000, 242_000, 98_000, 312_000, 184_000]
        result.dailyUsage = amounts.enumerated().map { i, n in
            DailyUsage(date: calendar.date(byAdding: .day, value: i - 6, to: today)!, tokens: n)
        }
        result.today = tokens(184_000); result.lastSevenDays = tokens(1_240_000)
        result.thisMonth = tokens(4_900_000); result.allTime = tokens(8_120_000)
        result.allProjects = [("aurora-app",620_000,8),("canvas-ui",372_000,6),("data-tools",186_000,6),("docs-site",62_000,4)].map {
            ProjectUsage(path: "/demo/projects/" + $0.0, tokens: $0.1, sessions: $0.2, lastActive: now.addingTimeInterval(-120))
        }
        result.topProjects = result.allProjects
        result.todayProjects = result.allProjects.map { ProjectUsage(path: $0.path, tokens: Int(Double($0.tokens) / 1_240_000 * 184_000), sessions: $0.sessions, lastActive: $0.lastActive) }
        result.monthProjects = result.allProjects.map { ProjectUsage(path: $0.path, tokens: Int(Double($0.tokens) / 1_240_000 * 4_900_000), sessions: $0.sessions, lastActive: $0.lastActive) }
        result.topModels = [ModelUsage(name: "gpt-6.1-sol", tokens: 824_000, requests: 42, averageTurnSeconds: 76, cacheHitRate: 0.61),
                            ModelUsage(name: "gpt-6-astra", tokens: 312_000, requests: 18, averageTurnSeconds: 126, cacheHitRate: 0.42),
                            ModelUsage(name: "gpt-6-luna", tokens: 104_000, requests: 12, averageTurnSeconds: 38, cacheHitRate: 0.28)]
        result.panelModels = result.topModels
        for day in result.dailyUsage {
            for project in result.allProjects {
                for model in result.topModels {
                    result.recentRecords.append(UsageRecord(date: day.date, project: project.path, model: model.name,
                        tokens: Int((Double(day.tokens) * Double(project.tokens) / 1_240_000 * Double(model.tokens) / 1_240_000).rounded())))
                }
            }
        }
        result.recentRecords.sort { $0.date > $1.date }
        let weekly = RateWindow(usedPercent: 28, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(65 * 3_600))
        result.primaryRate = RateWindow(usedPercent: 16, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3_600))
        result.secondaryRate = weekly; result.mainMenuRate = weekly
        result.sparkRate = RateWindow(usedPercent: 8, windowMinutes: 10_080, resetsAt: weekly.resetsAt)
        result.mainRateSampledAt = now.addingTimeInterval(-120)
        result.sparkRateSampledAt = result.mainRateSampledAt
        result.replySpeedSamples = (0..<3).map { ReplySpeedSample(completedAt: now.addingTimeInterval(-Double($0 + 1) * 60), outputTokens: 2_700 + $0 * 100, turnSeconds: 70 + Double($0) * 3) }
        result.rateTimeline = [RateTimelineEvent(date: now.addingTimeInterval(-120), usedPercent: 28, resetsAt: weekly.resetsAt, limitID: "codex", tokens: 1_240_000)]
        result.currentContextUsed = 42_000; result.contextWindow = 258_000
        result.lastUpdated = now.addingTimeInterval(-9); result.sessionCount = 24; result.fileCount = 42
        result.dataPath = "/demo/codex"; result.dataDirectoryExists = true
        return result
    }()
    static let widgetUsage = WidgetUsageData(todayTokens: 184_000, weekTokens: 1_240_000, monthTokens: 4_900_000,
        contextTokens: 42_000, contextLimit: 258_000, ratePercent: 28, rateWindowMinutes: 10_080,
        updatedAt: now, sampledAt: now, rateResetsAt: now.addingTimeInterval(65 * 3_600))
}

@MainActor @Observable private final class DocumentationState {
    static let shared = DocumentationState()
    var section: String? = "健康报告"
    var mode = "dashboard"
    var dark = false
    @ObservationIgnored weak var window: NSWindow?
    func show(_ mode: String) {
        self.mode = mode
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard let window else { return }
            let size: NSSize = mode == "desktop" ? .init(width:300,height:320) : mode == "widget" ? .init(width:630,height:230) : mode == "menu" ? .init(width:320,height:300) : .init(width:1080,height:872)
            window.styleMask = mode == "dashboard" ? [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView] : [.borderless]
            window.contentMinSize = .zero; window.minSize = .zero
            window.setContentSize(size); window.center(); window.makeKeyAndOrderFront(nil)
        }
    }
    func appearance(_ dark: Bool) {
        self.dark = dark
        UserDefaults.standard.set(dark ? "dark" : "light", forKey: AppAppearance.preferenceKey)
        window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }
}

@main struct DocumentationSnapshotApp: App {
    @NSApplicationDelegateAdaptor(DocumentationDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Codex Health") { DocumentationRoot() }
            .defaultSize(width: 1_080, height: 872)
            .commands {
                CommandMenu("演示预览") {
                    Button("健康报告窗口") { DocumentationState.shared.show("dashboard") }
                    Button("菜单栏摘要") { DocumentationState.shared.show("menu") }
                    Button("桌面悬浮摘要") { DocumentationState.shared.show("desktop") }
                    Button("WidgetKit 系统组件") { DocumentationState.shared.show("widget") }
                    Divider()
                    Button("浅色模式") { DocumentationState.shared.appearance(false) }
                    Button("深色模式") { DocumentationState.shared.appearance(true) }
                }
            }
    }
}

private struct DocumentationRoot: View {
    @State private var state = DocumentationState.shared
    var body: some View {
        Group {
            switch state.mode {
            case "menu": UsagePopoverView(store: .shared, permissionStore: PermissionStore(), compact: true, isVisible: false)
            case "widget": DocumentationWidgetPreview()
            case "desktop": DesktopWidgetView(store: .shared, dismiss: {})
            default: AnalyticsDashboardView(store: .shared, selectedSection: $state.section)
            }
        }
        .preferredColorScheme(state.dark ? .dark : .light)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor private final class DocumentationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            let state = DocumentationState.shared
            state.window = NSApp.windows.first(where: { $0.contentView != nil && $0.canBecomeMain })
            state.appearance(false)
            state.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
