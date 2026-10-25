import AppKit
import Testing
@testable import CodexMeter

@MainActor
struct MenuBarQuotaDisplayTests {
    private let now = Date(timeIntervalSince1970: 1_792_900_000)

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
