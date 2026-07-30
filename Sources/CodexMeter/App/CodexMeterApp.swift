import AppKit
import SwiftUI

@main
struct CodexMeterApp: App {
    @State private var store = UsageStore()
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBar

    var body: some Scene {
        WindowGroup("Codex Health", id: "dashboard") {
            AnalyticsDashboardView(store: store)
                .frame(minWidth: 1_180, minHeight: 760)
                .task { menuBar.configure(with: store) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_300, height: 860)

        Settings {
            SettingsView(store: store)
        }
    }
}

extension UsageSnapshot {
    var sevenDayRate: RateWindow? {
        [primaryRate, secondaryRate].compactMap { $0 }.first { $0.windowMinutes == 10_080 }
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
    private let sparkBadge = SparkBadgeView()
    private weak var store: UsageStore?
    private var refreshTimer: Timer?
    private var usageRefreshObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let button = statusItem.button else { return }
        button.image = Self.menuBarMark()
        button.imagePosition = .imageLeading
        button.title = "  —"
        button.addSubview(sparkBadge)
        NSLayoutConstraint.activate([
            sparkBadge.widthAnchor.constraint(equalToConstant: 24),
            sparkBadge.heightAnchor.constraint(equalToConstant: 14),
            sparkBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -4),
            sparkBadge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -2)
        ])
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.toolTip = "Codex Health"
        popover.behavior = .transient
        popover.contentViewController = popoverController
        popover.contentSize = NSSize(width: 392, height: 292)
    }

    func configure(with store: UsageStore) {
        guard self.store !== store else { return }
        self.store = store
        popoverController.rootView = UsagePopoverView(store: store, compact: true)
        popover.contentViewController = popoverController
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
        let configured = UserDefaults.standard.object(forKey: "codexMeter.refreshInterval") as? Double ?? 60
        refreshTimer = Timer.scheduledTimer(
            timeInterval: max(30, configured),
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
        let mainRate = snapshot.mainMenuRate ?? snapshot.sevenDayRate
        let sparkRate = snapshot.sparkRate
        let remaining = snapshot.remainingPercent(for: mainRate)
        let sparkRemaining = snapshot.remainingPercent(for: sparkRate)
        statusItem.button?.title = "  \(remaining)%"
        statusItem.button?.contentTintColor = remaining < 20 ? .systemRed : remaining < 50 ? .systemOrange : .systemGreen
        sparkBadge.update(percentage: sparkRate == nil ? nil : sparkRemaining)
    }

    private static func menuBarMark() -> NSImage {
        let size = NSSize(width: 19, height: 19)
        let image = NSImage(size: size, flipped: false) { _ in
            let ring = NSBezierPath()
            ring.appendArc(withCenter: NSPoint(x: 9.5, y: 9.5), radius: 7.1, startAngle: 42, endAngle: 318, clockwise: false)
            ring.lineWidth = 3.1
            NSColor.systemBlue.setStroke()
            ring.stroke()

            let h = NSBezierPath()
            h.move(to: NSPoint(x: 8.0, y: 6.3)); h.line(to: NSPoint(x: 8.0, y: 12.8))
            h.move(to: NSPoint(x: 11.3, y: 6.3)); h.line(to: NSPoint(x: 11.3, y: 12.8))
            h.move(to: NSPoint(x: 8.0, y: 9.5)); h.line(to: NSPoint(x: 11.3, y: 9.5))
            h.lineWidth = 1.45
            NSColor.white.setStroke()
            h.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}

private final class SparkBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.95).cgColor
        layer?.cornerRadius = 7
        layer?.masksToBounds = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 9, weight: .semibold)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        isHidden = true
    }

    func update(percentage: Int?) {
        guard let percentage else {
            isHidden = true
            return
        }
        label.stringValue = "\(percentage)%"
        isHidden = false
    }
}
