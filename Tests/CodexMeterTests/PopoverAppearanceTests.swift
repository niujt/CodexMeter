import AppKit
import SwiftUI
import Testing
@testable import CodexMeter

@MainActor
struct PopoverAppearanceTests {
    @Test func popoverUsesAppThemeEvenWhenMenuBarUsesOppositeTheme() throws {
        _ = NSApplication.shared
        for systemName in [NSAppearance.Name.aqua, .darkAqua] {
            let system = try #require(NSAppearance(named: systemName))
            for mode in AppAppearance.allCases {
                let popover = NSPopover()
                let host = NSHostingController(rootView: Text("97%"))
                popover.contentViewController = host
                let expected = mode.resolvedColorScheme(for: system) == .dark
                    ? NSAppearance.Name.darkAqua : .aqua
                let resolved = mode.resolvedPopoverAppearance(for: system)
                popover.appearance = resolved
                host.view.appearance = resolved
                // An opposite appearance on the containing menu-bar window
                // must not leak into the content after presentation.
                let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 340),
                                      styleMask: [.borderless], backing: .buffered, defer: true)
                window.appearance = NSAppearance(named: expected == .darkAqua ? .aqua : .darkAqua)
                window.contentView = host.view
                #expect(host.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            }
        }
    }

    @Test func auxiliaryTextMeetsContrastTargetOnOpaquePopoverSurface() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua,
                     .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            var colors: [NSColor?] = []
            appearance.performAsCurrentDrawingAppearance {
                colors = [DashboardPalette.popoverBackground, DashboardPalette.popoverSecondaryInk, DashboardPalette.ink]
                    .map { NSColor($0).usingColorSpace(.sRGB) }
            }
            let background = try #require(colors[0])
            let secondary = try #require(colors[1])
            let ink = try #require(colors[2])
            #expect(background.alphaComponent == 1)
            #expect(contrast(secondary, background) >= 4.5)
            #expect(contrast(ink, background) >= 7)
        }
    }

    @Test func increasedContrastSurvivesThemeOverride() throws {
        let system = try #require(NSAppearance(named: .accessibilityHighContrastAqua))
        // Some macOS versions canonicalize accessibility names to Aqua when
        // Increase Contrast is off; compare against the system's actual result.
        let expectedDark = try #require(NSAppearance(named: .accessibilityHighContrastDarkAqua))
        #expect(AppAppearance.dark.resolvedPopoverAppearance(for: system).name == expectedDark.name)
        #expect(AppAppearance.system.resolvedPopoverAppearance(for: system).name == system.name)
    }

    @Test func rendersRealSurfacesWithSyntheticData() async throws {
        _ = NSApplication.shared
        let now = Date.now
        let root = ProcessInfo.processInfo.environment["CODEX_HEALTH_PREVIEW_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? TestFixtureDirectory.root.appendingPathComponent("appearance-previews-" + UUID().uuidString)
        let fixture = root.appendingPathComponent("synthetic-home")
        let sessions = fixture.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "CodexMeterTests.Popover." + UUID().uuidString))
        let auth = fixture.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": "popover-demo", "access_token": "synthetic"]])
            .write(to: auth, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-300)], ofItemAtPath: auth.path)
        func event(_ offset: Double, _ payload: [String: Any]) throws -> String {
            let object: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)),
                                       "type": "event_msg", "payload": payload]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
        }
        let data = try event(-240, ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": 0, "output_tokens": 0, "total_tokens": 0
            ]]])
            + event(-200, ["type": "task_started"])
            + event(-100, ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": 60_000, "cached_input_tokens": 30_000, "output_tokens": 840, "total_tokens": 60_840
            ]], "rate_limits": ["limit_id": "codex", "primary": ["used_percent": 3, "window_minutes": 10_080,
                "resets_at": now.addingTimeInterval(86_400).timeIntervalSince1970]]])
            + event(-100, ["type": "task_complete"])
        try data.write(to: sessions.appendingPathComponent("demo.jsonl"), atomically: true, encoding: .utf8)
        let store = UsageStore(reader: CodexUsageReader(),
                              folderAccess: CodexFolderAccess(defaults: defaults, selectedURL: fixture),
                              defaults: defaults, effectsEnabled: false)
        await store.refresh()
        #expect(store.snapshot.today.total == 60_840)
        #expect(store.snapshot.sevenDayRate?.usedPercent == 3)
        #expect(RecentReplySpeed.summarize(store.snapshot.replySpeedSamples)?.sampleCount == 1)
        #expect(RecentReplySpeed.summarize(store.snapshot.replySpeedSamples)?.tokensPerSecond == 8.4)
        let permissions = PermissionStore(persistenceURL: fixture.appendingPathComponent("permissions.json"), defaults: defaults)

        for dark in [false, true] {
            defaults.set(dark ? "dark" : "light", forKey: AppAppearance.preferenceKey)
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            let view = UsagePopoverView(store: store, permissionStore: permissions, compact: true, isVisible: false)
                .defaultAppStorage(defaults).environment(\.locale, Locale(identifier: "zh_CN"))
            let host = NSHostingView(rootView: view)
            host.appearance = appearance
            host.setFrameSize(host.fittingSize)
            let size = host.frame.size
            #expect(size.width == 320)
            #expect(size.height > 250 && size.height < 500)
            for bright in [false, true] {
                let canvas = NSView(frame: .init(x: 0, y: 0, width: size.width + 48, height: size.height + 48))
                canvas.wantsLayer = true
                canvas.layer?.backgroundColor = (bright ? NSColor.white : NSColor.black).cgColor
                let window = NSWindow(contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
                window.appearance = NSAppearance(named: bright ? .aqua : .darkAqua)
                window.contentView = canvas
                host.setFrameOrigin(.init(x: 24, y: 24))
                canvas.addSubview(host)
                canvas.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let name = "popover-\(dark ? "dark" : "light")-on-\(bright ? "light" : "dark").png"
                try png.write(to: root.appendingPathComponent(name))
                let scale = Double(bitmap.pixelsWide) / canvas.bounds.width
                let pixel = try #require(bitmap.colorAt(x: Int(32 * scale), y: Int(32 * scale))?.usingColorSpace(.sRGB))
                #expect(dark ? pixel.redComponent < 0.2 : pixel.redComponent > 0.9)
                #expect(pixel.alphaComponent == 1)
                host.removeFromSuperview()
            }
        }

        // Render the dashboard with a locally observed account quota and again
        // without one. Unknown remote-device usage must remain visibly unknown.
        for dark in [false, true] {
            for hasQuota in [false, true] {
                for width: CGFloat in [780, 1_040] {
                    var snapshot = store.snapshot
                    snapshot.today = TokenUsage(input: 158_000, cachedInput: 96_000, output: 26_000, total: 184_000)
                    snapshot.lastSevenDays = TokenUsage(total: 1_240_000)
                    snapshot.thisMonth = TokenUsage(total: 4_900_000)
                    snapshot.dailyUsage = [92_000, 186_000, 126_000, 242_000, 98_000, 312_000, 184_000].enumerated().map {
                        DailyUsage(date: Calendar.current.startOfDay(for: now).addingTimeInterval(Double($0.offset - 6) * 86_400), tokens: $0.element)
                    }
                    snapshot.topModels = [
                        .init(name: "gpt-6.1-sol", tokens: 824_000, requests: 42, averageTurnSeconds: 76, cacheHitRate: 0.61),
                        .init(name: "gpt-6-astra", tokens: 312_000, requests: 18, averageTurnSeconds: 126, cacheHitRate: 0.42),
                        .init(name: "gpt-6-luna", tokens: 104_000, requests: 12, averageTurnSeconds: 38, cacheHitRate: 0.28)
                    ]
                    snapshot.topProjects = [("aurora-app", 620_000), ("canvas-ui", 372_000), ("data-tools", 186_000), ("docs-site", 62_000)].map {
                        ProjectUsage(path: "/demo/" + $0.0, tokens: $0.1)
                    }
                    snapshot.fileCount = 42
                    snapshot.sessionCount = 24
                    if !hasQuota {
                        snapshot.mainMenuRate = nil
                        snapshot.primaryRate = nil
                        snapshot.secondaryRate = nil
                        snapshot.mainRateSampledAt = nil
                    }
                    let view = DashboardContent(snapshot: snapshot, errorMessage: nil, isRefreshing: false,
                                                measuredVelocity: nil, quotaMessage: "等待采样", chooseFolder: {})
                        .padding(28).frame(width: width)
                        .foregroundStyle(DashboardPalette.ink).tint(DashboardPalette.ink)
                        .progressViewStyle(FlatProgressStyle())
                        .background(DashboardPalette.canvas)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.setFrameSize(host.fittingSize)
                    let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
                    window.appearance = host.appearance
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(150))
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let suffix = width > 800 ? "-wide" : ""
                    try png.write(to: root.appendingPathComponent("dashboard-\(dark ? "dark" : "light")-\(hasQuota ? "quota" : "no-quota")\(suffix).png"))
                }
            }
        }
    }

    private func contrast(_ first: NSColor, _ second: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            func linear(_ value: CGFloat) -> Double {
                let value = Double(value)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
                + 0.0722 * linear(color.blueComponent)
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
