import AppKit
import Darwin
import Testing
@testable import CodexMeter

@MainActor
struct MenuBarQuotaDisplayTests {
    private let now = Date(timeIntervalSince1970: 1_792_900_000)

    @Test func isolatedStatusItemSettlesAfterRepeatedAppearanceNotifications() async throws {
        guard ProcessInfo.processInfo.environment["CODEX_HEALTH_STATUS_CPU_PROBE"] == "1" else { return }
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let button = try #require(item.button)
        button.appearance = NSAppearance(named: .aqua)
        let renderer = MenuBarQuotaRenderer()
        let display = MenuBarQuotaDisplay(sample: sample(used: 44), showsPercentage: false)
        let counts = StatusRenderProbeCounts()
        let observation = button.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            Task { @MainActor in
                counts.callbacks += 1
                if renderer.apply(display, description: "Synthetic CPU probe", to: button) { counts.images += 1 }
            }
        }
        if renderer.apply(display, description: "Synthetic CPU probe", to: button) { counts.images += 1 }
        func sendAppearanceNotifications() {
            for _ in 0..<1_000 {
                button.willChangeValue(forKey: "effectiveAppearance")
                button.didChangeValue(forKey: "effectiveAppearance")
            }
        }
        sendAppearanceNotifications()
        try await Task.sleep(for: .seconds(3))
        let image = try #require(button.image)
        let callbacksBeforeIdle = counts.callbacks
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        let start = ProcessInfo.processInfo.systemUptime
        let cpuStart = cpuSeconds()
        try await Task.sleep(for: .seconds(20))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let cpuPercent = (cpuSeconds() - cpuStart) / elapsed * 100
        #expect(button.image === image)
        #expect(counts.images == 1)
        #expect(counts.callbacks >= 1_000)
        #expect(cpuPercent < 15)
        if let directory = ProcessInfo.processInfo.environment["CODEX_HEALTH_PREVIEW_DIR"] {
            let report: [String: Any] = ["syntheticAppearanceNotifications": 1_000,
                "appearanceCallbacks": counts.callbacks, "idleCallbacks": counts.callbacks - callbacksBeforeIdle,
                "imageAssignments": counts.images, "idleSeconds": elapsed, "cpuPercent": cpuPercent,
                "scope": "Isolated native status item with synthetic quota; installed app untouched"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent("status-item-cpu-probe.json"))
        }
        withExtendedLifetime((item, observation)) {}
    }

    @Test func repeatedAppearanceCallbacksPreserveTheExistingStatusImage() throws {
        _ = NSApplication.shared
        let button = NSButton()
        button.appearance = NSAppearance(named: .aqua)
        let renderer = MenuBarQuotaRenderer()
        let display = MenuBarQuotaDisplay(sample: sample(used: 44), showsPercentage: true)
        #expect(renderer.apply(display, description: "sample one", to: button))
        let first = try #require(button.image)
        for _ in 0..<1_000 {
            #expect(!renderer.apply(display, description: "sample one", to: button))
        }
        #expect(button.image === first)
        #expect(!renderer.apply(display, description: "sample two", to: button))
        #expect(button.image === first)
        #expect(button.toolTip == "sample two")
        #expect(button.accessibilityLabel() == "sample two")
    }

    @Test func actualAppearanceAndQuotaChangesStillUpdateTheStatusImage() throws {
        _ = NSApplication.shared
        let button = NSButton()
        let renderer = MenuBarQuotaRenderer()
        let display = MenuBarQuotaDisplay(sample: sample(used: 44), showsPercentage: false)
        var previous: NSImage?
        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            button.appearance = NSAppearance(named: name)
            #expect(renderer.apply(display, description: "same sample", to: button))
            #expect(button.image !== previous)
            previous = button.image
            #expect(!renderer.apply(display, description: "same sample", to: button))
        }
        let changed = MenuBarQuotaDisplay(sample: sample(used: 88), showsPercentage: true, attentionCount: 2)
        #expect(renderer.apply(changed, description: "changed quota", to: button))
        #expect(button.image !== previous)
        #expect(button.title == changed.title)
        button.image = nil
        #expect(renderer.apply(changed, description: "changed quota", to: button))
        #expect(button.image != nil)
    }

    @Test func imageAssignmentCannotStartAReentrantRenderLoop() throws {
        _ = NSApplication.shared
        let button = ReentrantStatusButton()
        let renderer = MenuBarQuotaRenderer()
        let display = MenuBarQuotaDisplay(sample: sample(used: 44), showsPercentage: false)
        var callbackCount = 0
        button.onImageChanged = {
            callbackCount += 1
            #expect(!renderer.apply(display, description: "same sample", to: button))
        }
        #expect(renderer.apply(display, description: "same sample", to: button))
        #expect(callbackCount == 1)
    }

    @Test func ringAndPercentageBothRepresentRemainingQuota() throws {
        for (used, remaining, title) in [(44.0, 0.56, "56%"), (0.0, 1.0, "100%"), (100.0, 0.0, "0%")] {
            let display = MenuBarQuotaDisplay(sample: sample(used: used), showsPercentage: true)
            #expect(abs(try #require(display.remainingFraction) - remaining) < 0.000_001)
            #expect(display.title == title)
            #expect(!display.isStale)
        }
    }

    @Test func staleSampleKeepsItsRecordedRingAndExplicitOldLabel() throws {
        let oldSample = sample(used: 44, sampledAgo: QuotaSampleState.lifetime)
        let visible = MenuBarQuotaDisplay(sample: oldSample, showsPercentage: true)
        #expect(abs(try #require(visible.remainingFraction) - 0.56) < 0.000_001)
        #expect(visible.isStale)
        #expect(visible.title == "56%·旧")
        let hidden = MenuBarQuotaDisplay(sample: oldSample, showsPercentage: false)
        #expect(hidden.remainingFraction == visible.remainingFraction)
        #expect(hidden.isStale)
        #expect(hidden.title.isEmpty)
    }

    @Test func ringColorUsesRemainingQuotaAtTheExactThresholds() {
        #expect(MenuBarQuotaDisplay(sample: sample(used: 49), showsPercentage: false).tint == .green)
        #expect(MenuBarQuotaDisplay(sample: sample(used: 50), showsPercentage: false).tint == .yellow)
        #expect(MenuBarQuotaDisplay(sample: sample(used: 80), showsPercentage: false).tint == .yellow)
        #expect(MenuBarQuotaDisplay(sample: sample(used: 81), showsPercentage: false).tint == .red)
        #expect(MenuBarQuotaDisplay(sample: sample(used: 100), showsPercentage: false).tint == .red)
        let unknown = QuotaSampleState(percent: nil, sampledAt: nil, resetsAt: nil, now: now)
        #expect(MenuBarQuotaDisplay(sample: unknown, showsPercentage: false).tint == .unknown)
    }

    @Test func unknownExpiredAndFutureSamplesNeverInventRemainingQuota() {
        let samples = [
            QuotaSampleState(percent: nil, sampledAt: now, resetsAt: now.addingTimeInterval(3_600), now: now),
            QuotaSampleState(percent: 44, sampledAt: nil, resetsAt: now.addingTimeInterval(3_600), now: now),
            QuotaSampleState(percent: 44, sampledAt: now, resetsAt: nil, now: now),
            QuotaSampleState(percent: 44, sampledAt: now.addingTimeInterval(-60), resetsAt: now, now: now),
            QuotaSampleState(percent: 44, sampledAt: now.addingTimeInterval(1), resetsAt: now.addingTimeInterval(3_600), now: now),
            sample(used: -1), sample(used: 101), sample(used: .nan), sample(used: .infinity)
        ]
        for sample in samples {
            let visible = MenuBarQuotaDisplay(sample: sample, showsPercentage: true)
            #expect(visible.remainingFraction == nil)
            #expect(visible.title == "—")
            let hidden = MenuBarQuotaDisplay(sample: sample, showsPercentage: false)
            #expect(hidden.remainingFraction == nil)
            #expect(hidden.title.isEmpty)
        }
    }

    @Test func percentageDefaultsToHiddenAndPersistsOnlyInTheChosenPreferences() throws {
        // Keep synthetic preference domains; removing fixtures needs project confirmation.
        let suite = "CodexMeterTests.MenuBarQuota." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let unrelated = try #require(UserDefaults(suiteName: suite + ".independent"))
        #expect(!MenuBarQuotaDisplay.showsPercentage(defaults: defaults))
        defaults.set(true, forKey: MenuBarQuotaDisplay.showPercentageKey)
        let reopened = try #require(UserDefaults(suiteName: suite))
        #expect(MenuBarQuotaDisplay.showsPercentage(defaults: reopened))
        #expect(!MenuBarQuotaDisplay.showsPercentage(defaults: unrelated))
        reopened.set(false, forKey: MenuBarQuotaDisplay.showPercentageKey)
        #expect(!MenuBarQuotaDisplay.showsPercentage(defaults: defaults))
    }

    @Test func hidingQuotaTextPreservesPermissionAttentionBadge() {
        let fresh = sample(used: 44)
        #expect(MenuBarQuotaDisplay(sample: fresh, showsPercentage: false).title.isEmpty)
        #expect(MenuBarQuotaDisplay(sample: fresh, showsPercentage: false, attentionCount: 3).title == "⚠ 3")
        #expect(MenuBarQuotaDisplay(sample: fresh, showsPercentage: true, attentionCount: 3).title == "56% · ⚠ 3")
        let stale = sample(used: 44, sampledAgo: QuotaSampleState.lifetime)
        #expect(MenuBarQuotaDisplay(sample: stale, showsPercentage: true, attentionCount: 3).title == "56%·旧 · ⚠ 3")
        let unknown = QuotaSampleState(percent: nil, sampledAt: nil, resetsAt: nil, now: now)
        #expect(MenuBarQuotaDisplay(sample: unknown, showsPercentage: false, attentionCount: 3).title == "⚠ 3")
        #expect(MenuBarQuotaDisplay(sample: unknown, showsPercentage: true, attentionCount: 3).title == "— · ⚠ 3")
    }

    @Test func menuBarRingImagesStayColoredAndFixedSizeRegardlessOfTheirNativeTitle() throws {
        _ = NSApplication.shared
        let ring = MenuBarQuotaDisplay(sample: sample(used: 44), showsPercentage: false).image()
        #expect(!ring.isTemplate)
        #expect(ring.size == NSSize(width: 19, height: 19))
        #expect(try alphaPixels(ring).contains { $0 > 0 })
        let percentage = MenuBarQuotaDisplay(sample: sample(used: 44), showsPercentage: true).image()
        let attention = MenuBarQuotaDisplay(sample: sample(used: 44), showsPercentage: false, attentionCount: 3).image()
        for image in [percentage, attention] {
            #expect(!image.isTemplate)
            #expect(image.size == ring.size)
            #expect(try alphaPixels(image).contains { $0 > 0 })
            #expect(try colorPixels(image) == colorPixels(ring))
        }
    }

    @Test func changingRemainingQuotaChangesRingPixelsWithoutAnyPercentageText() throws {
        _ = NSApplication.shared
        let full = MenuBarQuotaDisplay(sample: sample(used: 0), showsPercentage: false).image()
        let partial = MenuBarQuotaDisplay(sample: sample(used: 44), showsPercentage: false).image()
        let empty = MenuBarQuotaDisplay(sample: sample(used: 100), showsPercentage: false).image()
        let fullPixels = try colorPixels(full)
        let partialPixels = try colorPixels(partial)
        let emptyPixels = try colorPixels(empty)
        // Compare states within this render, avoiding a machine-specific pixel snapshot.
        #expect(fullPixels != partialPixels)
        #expect(partialPixels != emptyPixels)
        #expect(fullPixels != emptyPixels)
    }

    @Test func centralAppMarkStaysVisibleAtNormalZeroAndUnknownQuotaInBothAppearances() throws {
        _ = NSApplication.shared
        let unknown = QuotaSampleState(percent: nil, sampledAt: nil, resetsAt: nil, now: now)
        let centralRange: Range<CGFloat> = 6.5..<12.5
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for state in [sample(used: 44), sample(used: 100), unknown] {
                let image = MenuBarQuotaDisplay(sample: state, showsPercentage: false).image(appearance: appearance)
                let rendered = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                let bitmap = NSBitmapImageRep(cgImage: rendered)
                var opaqueMarkPixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let logicalX = (CGFloat(x) + 0.5) * image.size.width / CGFloat(bitmap.pixelsWide)
                        let logicalY = (CGFloat(y) + 0.5) * image.size.height / CGFloat(bitmap.pixelsHigh)
                        // This central 6×6-point area is inside the ring's inner radius,
                        // so the old ring without an H cannot satisfy the assertion.
                        guard centralRange.contains(logicalX), centralRange.contains(logicalY) else { continue }
                        if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.75 {
                            opaqueMarkPixels += 1
                        }
                    }
                }
                #expect(opaqueMarkPixels >= 3)
            }
        }
    }

    private func sample(used: Double, sampledAgo: TimeInterval = 0) -> QuotaSampleState {
        QuotaSampleState(percent: used, sampledAt: now.addingTimeInterval(-sampledAgo),
                         resetsAt: now.addingTimeInterval(3_600), now: now)
    }

    private func alphaPixels(_ image: NSImage) throws -> [UInt8] {
        let rendered = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        return (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).map { x in
                UInt8(((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255).rounded())
            }
        }
    }

    private func colorPixels(_ image: NSImage) throws -> [UInt8] {
        let rendered = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        return (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).flatMap { x -> [UInt8] in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [0, 0, 0, 0] }
                return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                    .map { UInt8(($0 * 255).rounded()) }
            }
        }
    }
}

@MainActor
private final class StatusRenderProbeCounts {
    var callbacks = 0
    var images = 0
}

@MainActor
private final class ReentrantStatusButton: NSButton {
    var onImageChanged: (() -> Void)?
    override var image: NSImage? {
        get { super.image }
        set { super.image = newValue; onImageChanged?() }
    }
}
