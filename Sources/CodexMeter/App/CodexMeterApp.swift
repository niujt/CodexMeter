import AppKit
import SwiftUI
import UserNotifications

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

    static func energyInterval(configured: TimeInterval, foreground: Bool, lowPower: Bool,
                               thermalState: ProcessInfo.ThermalState) -> TimeInterval {
        var result = max(lowPowerDefault, configured)
        if !foreground { result = max(result, 900) }
        if lowPower { result = max(result, 1_800) }
        switch thermalState {
        case .nominal: break
        case .fair: result = max(result, 900)
        case .serious, .critical: result = max(result, 3_600)
        @unknown default: result = max(result, 1_800)
        }
        return result
    }

    /// Changing visibility must not restart the entire countdown on every switch.
    static func nextRefreshDate(lastAttempt: Date?, interval: TimeInterval, now: Date) -> Date {
        guard let lastAttempt, lastAttempt <= now else { return now }
        return max(now, lastAttempt.addingTimeInterval(interval))
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let preferenceKey = "codexMeter.appearance"

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

    func resolvedColorScheme(for systemAppearance: NSAppearance) -> ColorScheme {
        colorScheme ?? (systemAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
    }

    func resolvedPopoverAppearance(for systemAppearance: NSAppearance) -> NSAppearance {
        // A status item's appearance can follow the wallpaper independently of
        // the app. Resolve the popover from the app preference and system theme.
        let dark = resolvedColorScheme(for: systemAppearance) == .dark
        let highContrast = systemAppearance.name
        let increasedContrast = highContrast == .accessibilityHighContrastAqua
            || highContrast == .accessibilityHighContrastDarkAqua
        let name: NSAppearance.Name = increasedContrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        return NSAppearance(named: name) ?? systemAppearance
    }
}

extension Notification.Name {
    static let codexHealthDashboardWillOpen = Notification.Name("CodexHealth.dashboardWillOpen")
}

@main
struct CodexMeterApp: App {
    @State private var store = UsageStore.shared
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBar

    init() {
        RefreshPolicy.configure()
        PermissionPreferences.configure()
    }

    var body: some Scene {
        WindowGroup("Codex Health", id: "dashboard") {
            AnalyticsDashboardView(store: store)
                .frame(minWidth: 980, minHeight: 640)
                .task { menuBar.configure(with: store) }
                .onAppear { menuBar.dashboardDidAppear() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1_080, height: 740)
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

struct MenuBarQuotaDisplay: Equatable, Sendable {
    typealias Tint = QuotaRemainingTint
    static let showPercentageKey = "codexMeter.menuBar.showPercentage"

    let remainingFraction: Double?
    let isStale: Bool
    let title: String

    var tint: Tint {
        guard let remainingFraction else { return .unknown }
        if remainingFraction > 0.5 { return .green }
        return remainingFraction >= 0.2 ? .yellow : .red
    }

    static func showsPercentage(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: showPercentageKey)
    }

    init(sample: QuotaSampleState, showsPercentage: Bool, attentionCount: Int = 0) {
        remainingFraction = sample.recordedPercent.map { (100 - $0) / 100 }
        let stale = sample.isStale && remainingFraction != nil
        isStale = stale
        let quota = showsPercentage
            ? sample.recordedRemaining.map { "\($0)%" + (stale ? "·旧" : "") } ?? "—"
            : ""
        title = [quota, attentionCount > 0 ? "⚠ \(attentionCount)" : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @MainActor
    func image(appearance: NSAppearance? = nil) -> NSImage {
        let color = DashboardPalette.quotaNSColor(tint)
        var trackColor = NSColor.black.withAlphaComponent(0.22)
        var arcColor = color
        var monogramColor = NSColor.black
        (appearance ?? NSAppearance(named: .aqua))?.performAsCurrentDrawingAppearance {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            trackColor = resolved.withAlphaComponent(remainingFraction == nil ? 0.4 : 0.22)
            arcColor = resolved.withAlphaComponent(isStale ? 0.6 : 1)
            monogramColor = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        let resolvedTrack = trackColor
        let resolvedArc = arcColor
        let resolvedMonogram = monogramColor
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: false) { _ in
            let bounds = NSRect(x: 2.4, y: 2.4, width: 14.2, height: 14.2)
            let track = NSBezierPath(ovalIn: bounds)
            track.lineWidth = 2.2
            if remainingFraction == nil {
                track.setLineDash([1.5, 2.0], count: 2, phase: 0)
                track.lineCapStyle = .round
            }
            resolvedTrack.setStroke()
            track.stroke()

            if let fraction = remainingFraction, fraction > 0 {
                let arc = NSBezierPath()
                if fraction >= 1 {
                    arc.appendOval(in: bounds)
                } else {
                    arc.appendArc(withCenter: NSPoint(x: 9.5, y: 9.5), radius: 7.1,
                                  startAngle: 90, endAngle: 90 - 360 * fraction, clockwise: true)
                }
                arc.lineWidth = 2.2
                arc.lineCapStyle = .round
                if isStale { arc.setLineDash([1.5, 1.5], count: 2, phase: 0) }
                resolvedArc.setStroke()
                arc.stroke()
            }

            let monogram = NSBezierPath()
            monogram.move(to: NSPoint(x: 7, y: 6.1))
            monogram.line(to: NSPoint(x: 7, y: 12.9))
            monogram.move(to: NSPoint(x: 12, y: 6.1))
            monogram.line(to: NSPoint(x: 12, y: 12.9))
            monogram.move(to: NSPoint(x: 7, y: 9.5))
            monogram.line(to: NSPoint(x: 12, y: 9.5))
            monogram.lineWidth = 1.4
            monogram.lineCapStyle = .round
            resolvedMonogram.setStroke()
            monogram.stroke()
            return true
        }
        // Keep the ring's colors; the native status button draws its text separately.
        image.isTemplate = false
        return image
    }
}

/// AppKit can report effectiveAppearance again while updating status-item
/// snapshots. Commit the render key before changing the button, and never
/// recreate an unchanged image in response to those notifications.
@MainActor
final class MenuBarQuotaRenderer {
    private var renderedDisplay: MenuBarQuotaDisplay?
    private var renderedAppearance: NSAppearance.Name?

    @discardableResult
    func apply(_ display: MenuBarQuotaDisplay, description: String, to button: NSButton) -> Bool {
        let appearance = button.effectiveAppearance
        let appearanceName = appearance.name
        let needsImage = display != renderedDisplay || appearanceName != renderedAppearance || button.image == nil
        if needsImage {
            renderedDisplay = display
            renderedAppearance = appearanceName
        }
        if button.toolTip != description {
            button.toolTip = description
            button.setAccessibilityLabel(description)
        }
        guard needsImage else { return false }
        button.image = display.image(appearance: appearance)
        button.title = display.title
        button.imagePosition = display.title.isEmpty ? .imageOnly : .imageLeading
        button.contentTintColor = nil
        return true
    }
}

@MainActor
private final class MenuBarController: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let sharedStore = UsageStore.shared
    private let permissionStore = PermissionStore.shared
    private lazy var popoverController = NSHostingController(
        rootView: UsagePopoverView(store: sharedStore, permissionStore: permissionStore, compact: true, isVisible: false)
    )
    private weak var store: UsageStore?
    private var refreshTimer: Timer?
    private var scheduledRefreshInterval: TimeInterval?
    private var scheduledInBackground: Bool?
    private var lastRefreshAttempt: Date?
    private var energyObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var isSleeping = false
    private var usageRefreshObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var dashboardWillOpenObserver: NSObjectProtocol?
    private var permissionObserver: NSObjectProtocol?
    private var dockAppearanceObservation: NSKeyValueObservation?
    private var statusAppearanceObservation: NSKeyValueObservation?
    private var quotaExpiryTask: Task<Void, Never>?
    private var quotaSample = QuotaSampleState(percent: nil, sampledAt: nil, resetsAt: nil, now: .now)
    private let statusRenderer = MenuBarQuotaRenderer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start as a menu-bar accessory. The dashboard promotes the app to a
        // regular Dock application when it is explicitly opened.
        _ = NSApp.setActivationPolicy(.accessory)
        AppIconStyle.applyDockIcon()
        dockAppearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                AppIconStyle.applyDockIcon()
                self?.applyPopoverAppearance()
            }
        }
        guard let button = statusItem.button else { return }
        statusAppearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.applyStatusAppearance() }
        }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "Codex Health"
        applyStatusAppearance()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = popoverController
        applyPopoverAppearance()
        popoverController.sizingOptions = [.preferredContentSize]
        popover.contentSize = NSSize(width: 320, height: 340)
        UNUserNotificationCenter.current().delegate = self
        // Sparkle replaces the bundle, but WidgetKit can retain an extension
        // process from the previous installation. Retire only that old binary.
        WidgetExtensionRecovery.recoverAfterUpdate()
        sharedStore.synchronizeContext()
        PermissionAttentionService.shared.start()
        permissionObserver = NotificationCenter.default.addObserver(
            forName: .codexPermissionStoreDidChange,
            object: permissionStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyStatusAppearance() }
        }
        dashboardWillOpenObserver = NotificationCenter.default.addObserver(
            forName: .codexHealthDashboardWillOpen,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dashboardDidAppear() }
        }
        configure(with: sharedStore)
    }

    func dashboardDidAppear() {
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func configure(with store: UsageStore) {
        guard self.store !== store else { return }
        self.store = store
        popoverController.rootView = UsagePopoverView(store: store, permissionStore: permissionStore, compact: true, isVisible: popover.isShown)
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
        observeEnergyState()
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleRefreshTimer()
                    AppIconStyle.applyDockIcon()
                    self?.applyStatusAppearance()
                    self?.applyPopoverAppearance()
                }
            }
        }
    }

    private func scheduleRefreshTimer() {
        let background = !hasVisibleInterface
        let interval = RefreshPolicy.energyInterval(configured: RefreshPolicy.interval(), foreground: !background,
                                                   lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                                   thermalState: ProcessInfo.processInfo.thermalState)
        guard isSleeping || scheduledRefreshInterval != interval || scheduledInBackground != background else { return }
        refreshTimer?.invalidate()
        refreshTimer = nil
        scheduledRefreshInterval = nil
        scheduledInBackground = nil
        guard !isSleeping else { return }
        scheduledRefreshInterval = interval
        scheduledInBackground = background
        // A background activity is discretionary and may be postponed beyond
        // the widget's freshness window. Keep the energy-aware cadence while
        // using the same timer in the foreground and background.
        let nextDate = RefreshPolicy.nextRefreshDate(lastAttempt: lastRefreshAttempt, interval: interval, now: .now)
        let timer = Timer(fireAt: nextDate, interval: interval, target: self,
                          selector: #selector(refreshTimerFired(_:)), userInfo: nil, repeats: true)
        timer.tolerance = min(60, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private var hasVisibleInterface: Bool {
        NSApp.isActive && (popover.isShown || NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
                && ($0.canBecomeMain || ($0.styleMask.contains(.titled) && $0.canBecomeKey))
        })
    }

    private func observeEnergyState() {
        guard energyObservers.isEmpty else { return }
        let names: [Notification.Name] = [ProcessInfo.thermalStateDidChangeNotification,
                                         .NSProcessInfoPowerStateDidChange, NSWindow.didChangeOcclusionStateNotification]
        for name in names {
            energyObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleRefreshTimer() }
            })
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isSleeping = true
                self?.scheduleRefreshTimer()
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isSleeping = false
                // Desktop widgets remain visible even when the app has no window.
                self.refreshStatus()
                self.scheduleRefreshTimer()
            }
        })
    }

    func applicationDidBecomeActive(_ notification: Notification) { scheduleRefreshTimer() }
    func applicationDidResignActive(_ notification: Notification) { scheduleRefreshTimer() }

    func popoverDidClose(_ notification: Notification) {
        if let store {
            popoverController.rootView = UsagePopoverView(store: store, permissionStore: permissionStore, compact: true, isVisible: false)
        }
        scheduleRefreshTimer()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            applyPopoverAppearance()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let store {
                popoverController.rootView = UsagePopoverView(store: store, permissionStore: permissionStore, compact: true, isVisible: true)
            }
            NSApp.activate(ignoringOtherApps: true)
            scheduleRefreshTimer()
        }
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        refreshStatus()
    }

    private func refreshStatus() {
        guard let store, !store.isRefreshing else { return }
        lastRefreshAttempt = .now
        Task { [weak self, weak store] in
            guard let self, let store else { return }
            // The scheduler owns the cadence. Applying the window-open throttle
            // here would skip a tick when the previous parse finished after it began.
            await store.refresh()
            update(snapshot: store.snapshot)
        }
    }

    private func update(snapshot: UsageSnapshot) {
        quotaExpiryTask?.cancel()
        guard statusItem.button != nil else { return }
        let now = Date.now
        let rate = snapshot.sevenDayRate
        let sample = QuotaSampleState(percent: rate?.usedPercent, sampledAt: snapshot.mainRateSampledAt,
                                      resetsAt: rate?.resetsAt, now: now)
        quotaSample = sample
        applyStatusAppearance()
        if let deadline = snapshot.quotaDisplayDeadlines.filter({ $0 > now }).min() {
            quotaExpiryTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(max(0.025, deadline.timeIntervalSinceNow))) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                self.update(snapshot: self.store?.snapshot ?? snapshot)
            }
        }
    }

    private func applyStatusAppearance() {
        guard let button = statusItem.button else { return }
        let showBadge = UserDefaults.standard.bool(forKey: PermissionPreferences.badgeEnabledKey)
        let count = showBadge ? permissionStore.newCount : 0
        let display = MenuBarQuotaDisplay(sample: quotaSample,
            showsPercentage: MenuBarQuotaDisplay.showsPercentage(), attentionCount: count)
        let quotaDescription = quotaSample.recordedRemaining.map {
            "\(quotaSample.isStale ? "上次剩余" : "剩余") \($0)%"
        } ?? "等待有效额度采样"
        let attentionDescription = count > 0 ? " · \(count) 个权限请求需要关注" : ""
        let description = "Codex Health · " + quotaDescription + attentionDescription + "\n" + quotaSample.description
        statusRenderer.apply(display, description: description, to: button)
    }

    private func applyPopoverAppearance() {
        let mode = AppAppearance(rawValue: UserDefaults.standard.string(forKey: AppAppearance.preferenceKey) ?? "") ?? .system
        let appearance = mode.resolvedPopoverAppearance(for: NSApp.effectiveAppearance)
        popover.appearance = appearance
        popoverController.view.appearance = appearance
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.userInfo["kind"] as? String == "codex.permission.request" else { return }
        let eventID = response.notification.request.content.userInfo["eventId"] as? String
        await MainActor.run {
            PermissionAttentionService.shared.openCodex(eventID: eventID)
        }
    }
}
