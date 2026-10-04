// Compiled only by preview_screenshots.py, with in-memory data providers.
import AppKit
import Observation
import SwiftUI

enum ScreenshotFixture {
    static let now = Date.now
    static var snapshot: UsageSnapshot {
        var result = UsageSnapshot.empty
        result.today = TokenUsage(input: 158_000, cachedInput: 96_000, output: 26_000, total: 184_000)
        result.lastSevenDays = TokenUsage(total: 1_240_000)
        result.thisMonth = TokenUsage(total: 4_860_000)
        result.mainMenuRate = RateWindow(usedPercent: 28, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3 * 86_400))
        result.lastUpdated = now
        result.fileCount = 42
        result.sessionCount = 24
        result.currentContextUsed = 42_000
        result.contextWindow = 258_000
        result.replySpeedSamples = [
            .init(completedAt: now.addingTimeInterval(-90), outputTokens: 3_860, turnSeconds: 100),
            .init(completedAt: now.addingTimeInterval(-240), outputTokens: 2_316, turnSeconds: 60),
            .init(completedAt: now.addingTimeInterval(-360), outputTokens: 1_544, turnSeconds: 40)
        ]
        result.dailyUsage = [92_000, 186_000, 126_000, 242_000, 98_000, 312_000, 184_000].enumerated().map {
            DailyUsage(date: Calendar.current.date(byAdding: .day, value: $0.offset - 6, to: now)!, tokens: $0.element)
        }
        result.topModels = [
            .init(name: "gpt-6.1-sol", tokens: 824_000, requests: 42, averageTurnSeconds: 86, cacheHitRate: 0.64),
            .init(name: "gpt-6-astra", tokens: 312_000, requests: 18, averageTurnSeconds: 132, cacheHitRate: 0.48),
            .init(name: "gpt-6-luna", tokens: 104_000, requests: 12, averageTurnSeconds: 38, cacheHitRate: 0.51)
        ]
        result.panelModels = result.topModels
        result.topProjects = [
            .init(path: "/demo/aurora-app", tokens: 620_000, sessions: 12, lastActive: now),
            .init(path: "/demo/canvas-ui", tokens: 372_000, sessions: 6, lastActive: now.addingTimeInterval(-3_600)),
            .init(path: "/demo/data-tools", tokens: 186_000, sessions: 4, lastActive: now.addingTimeInterval(-7_200)),
            .init(path: "/demo/docs-site", tokens: 62_000, sessions: 2, lastActive: now.addingTimeInterval(-86_400))
        ]
        result.allProjects = result.topProjects
        result.monthProjects = result.topProjects
        result.todayProjects = result.topProjects
        result.recentRecords = (0..<8).map { index in
            UsageRecord(date: now.addingTimeInterval(-Double(index) * 3_600),
                        project: result.topProjects[index % 4].path,
                        model: result.topModels[index % 3].name,
                        tokens: [24_000, 18_000, 32_000, 16_000][index % 4])
        }
        result.rateTimeline = [
            .init(date: now, usedPercent: 28, resetsAt: now.addingTimeInterval(3 * 86_400), limitID: "codex"),
            .init(date: now.addingTimeInterval(-7 * 86_400), usedPercent: 64,
                  resetsAt: now.addingTimeInterval(-4 * 86_400), limitID: "codex")
        ]
        return result
    }

    static var widgetUsage: WidgetUsageData {
        .init(todayTokens: 184_000, weekTokens: 1_240_000, monthTokens: 4_860_000,
              contextTokens: 42_000, contextLimit: 258_000, ratePercent: 28,
              rateWindowMinutes: 10_080, updatedAt: now, rateResetsAt: now.addingTimeInterval(3 * 86_400))
    }
}

@MainActor @Observable final class ScreenshotState {
    var section: String? = "健康报告"
    var surface = "dashboard"
    var width: CGFloat = 1_080
    var height: CGFloat = 820
}

@MainActor
final class ScreenshotAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ScreenshotApp: App {
    @NSApplicationDelegateAdaptor(ScreenshotAppDelegate.self) private var delegate
    @State private var state = ScreenshotState()
    @State private var store = UsageStore()
    @State private var permissions = PermissionStore(
        persistenceURL: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("synthetic-permissions.json")
    )

    init() {
        UserDefaults.standard.set("light", forKey: "codexMeter.appearance")
    }

    var body: some Scene {
        WindowGroup("Codex Health") {
            Group {
                switch state.surface {
                case "menu":
                    UsagePopoverView(store: store, permissionStore: permissions, compact: true, isVisible: false)
                case "widget":
                    DocumentationWidgetPreview()
                default:
                    AnalyticsDashboardView(store: store, selectedSection: $state.section)
                }
            }
            .frame(width: state.width, height: state.height, alignment: .topLeading)
            .environment(\.locale, Locale(identifier: "zh_CN"))
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("演示预览") {
                Button("分析页面") { show("dashboard", width: 1_080, height: 820) }
                    .keyboardShortcut("1", modifiers: [.command, .option])
                Button("菜单栏摘要") { show("menu", width: 320, height: 330) }
                    .keyboardShortcut("2", modifiers: [.command, .option])
                Button("桌面小组件") { show("widget", width: 630, height: 230) }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                Divider()
                Button("浅色模式") {
                    UserDefaults.standard.set("light", forKey: "codexMeter.appearance")
                    NSApp.appearance = NSAppearance(named: .aqua)
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
                Button("深色模式") {
                    UserDefaults.standard.set("dark", forKey: "codexMeter.appearance")
                    NSApp.appearance = NSAppearance(named: .darkAqua)
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
            }
        }
    }

    @MainActor private func show(_ surface: String, width: CGFloat, height: CGFloat) {
        state.surface = surface
        state.width = width
        state.height = height
    }
}
