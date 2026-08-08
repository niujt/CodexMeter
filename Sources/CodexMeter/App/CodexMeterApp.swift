import AppKit
import SwiftUI

enum RefreshPolicy {
    static let intervalKey = "codexMeter.refreshInterval"
    static let lowPowerDefault: TimeInterval = 300
    private static let migrationKey = "codexMeter.lowPowerRefreshMigration.v1"

    static func configure(defaults: UserDefaults = .standard) {
        defaults.register(defaults: [intervalKey: lowPowerDefault])
        guard !defaults.bool(forKey: migrationKey) else { return }

        if let interval = defaults.object(forKey: intervalKey) as? Double,
           interval < lowPowerDefault {
            defaults.set(lowPowerDefault, forKey: intervalKey)
        }
        defaults.set(true, forKey: migrationKey)
    }

    static func interval(defaults: UserDefaults = .standard) -> TimeInterval {
        let configured = defaults.object(forKey: intervalKey) as? Double ?? lowPowerDefault
        return max(lowPowerDefault, configured)
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "白天模式"
        case .dark: "暗黑模式"
        }
    }
    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension Notification.Name {
    static let codexHealthDashboardWillOpen = Notification.Name("CodexHealth.dashboardWillOpen")
}

@main
struct CodexMeterApp: App {
    @State private var store = UsageStore()
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBar

    init() {
        RefreshPolicy.configure()
    }

    var body: some Scene {
        WindowGroup("Codex Health", id: "dashboard") {
            AnalyticsDashboardView(store: store)
                .frame(minWidth: 1_180, minHeight: 760)
                .task { menuBar.configure(with: store) }
                .onAppear { menuBar.dashboardDidAppear() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_300, height: 860)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(store: store)
        }
    }
}

extension UsageSnapshot {
    var sevenDayRate: RateWindow? {
        mainMenuRate
            ?? [primaryRate, secondaryRate].compactMap { $0 }.first { $0.windowMinutes == 10_080 }
            ?? secondaryRate
            ?? primaryRate
    }

    func remainingPercent(for rate: RateWindow?) -> Int {
        max(0, 100 - Int((rate?.usedPercent ?? 0).rounded()))
    }
}

@MainActor
private final class MenuBarController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let fallbackStore = UsageStore()
    private lazy var popoverController = NSHostingController(rootView: UsagePopoverView(store: fallbackStore, compact: true))
    private weak var store: UsageStore?
    private var refreshTimer: Timer?
    private var usageRefreshObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var dashboardWillOpenObserver: NSObjectProtocol?
    private var appearanceObservation: NSKeyValueObservation?
    private var displayedTitle = "—"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start as a menu-bar accessory. The dashboard promotes the app to a
        // regular Dock application when it is explicitly opened.
        _ = NSApp.setActivationPolicy(.accessory)
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "Codex Health"
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.applyStatusAppearance() }
        }
        applyStatusAppearance()
        popover.behavior = .transient
        popover.contentViewController = popoverController
        popover.contentSize = NSSize(width: 392, height: 292)
        dashboardWillOpenObserver = NotificationCenter.default.addObserver(
            forName: .codexHealthDashboardWillOpen,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dashboardDidAppear() }
        }
        configure(with: fallbackStore)
    }

    func dashboardDidAppear() {
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func configure(with store: UsageStore) {
        guard self.store !== store else { return }
        self.store = store
        popoverController.rootView = UsagePopoverView(store: store, compact: true)
        popover.contentViewController = popoverController
        update(snapshot: store.snapshot)
        if let usageRefreshObserver { NotificationCenter.default.removeObserver(usageRefreshObserver) }
        usageRefreshObserver = NotificationCenter.default.addObserver(
            forName: .codexHealthUsageDidRefresh,
            object: store,
            queue: .main
        ) { [weak self, weak store] _ in
            Task { @MainActor [weak self, weak store] in
                guard let self, let store else { return }
                self.update(snapshot: store.snapshot)
            }
        }
        refreshStatus()
        scheduleRefreshTimer()
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefreshTimer() }
            }
        }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: RefreshPolicy.interval(),
            target: self,
            selector: #selector(refreshTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        refreshStatus()
    }

    private func refreshStatus() {
        guard let store else { return }
        Task { [weak self, weak store] in
            guard let self, let store else { return }
            await store.refresh()
            update(snapshot: store.snapshot)
        }
    }

    private func update(snapshot: UsageSnapshot) {
        guard statusItem.button != nil else { return }
        guard let rate = snapshot.mainMenuRate ?? snapshot.sevenDayRate else {
            displayedTitle = "—"
            applyStatusAppearance()
            return
        }
        let remaining = snapshot.remainingPercent(for: rate)
        displayedTitle = "\(remaining)%"
        applyStatusAppearance()
    }

    private func applyStatusAppearance() {
        guard let button = statusItem.button else { return }
        // Draw the percentage into the same non-template image as the mark.
        // NSStatusBarButton can otherwise re-tint attributed titles according
        // to the menu bar appearance even when a white foreground is supplied.
        button.image = Self.menuBarMark(title: displayedTitle)
        button.title = ""
        button.contentTintColor = NSColor.white
    }

    private static func menuBarMark(title: String) -> NSImage {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let titleSize = (title as NSString).size(withAttributes: titleAttributes)
        let size = NSSize(width: 19 + 7 + titleSize.width, height: 19)
        let image = NSImage(size: size, flipped: false) { _ in
            let ring = NSBezierPath()
            ring.appendArc(withCenter: NSPoint(x: 9.5, y: 9.5), radius: 7.1, startAngle: 42, endAngle: 318, clockwise: false)
            ring.lineWidth = 3.1
            NSColor.white.setStroke()
            ring.stroke()

            let h = NSBezierPath()
            h.move(to: NSPoint(x: 8.0, y: 6.3)); h.line(to: NSPoint(x: 8.0, y: 12.8))
            h.move(to: NSPoint(x: 11.3, y: 6.3)); h.line(to: NSPoint(x: 11.3, y: 12.8))
            h.move(to: NSPoint(x: 8.0, y: 9.5)); h.line(to: NSPoint(x: 11.3, y: 9.5))
            h.lineWidth = 1.45
            NSColor.white.setStroke()
            h.stroke()

            let titleY = (size.height - titleSize.height) / 2
            (title as NSString).draw(
                at: NSPoint(x: 26, y: titleY),
                withAttributes: titleAttributes
            )
            return true
        }
        // Keep the mark as a regular image so AppKit does not replace the
        // white strokes with the menu bar's automatic template tint.
        image.isTemplate = false
        return image
    }
}
