// Headless rendering with synthetic data; never launches or contacts the installed app.
import AppKit
import SwiftUI
import WidgetKit

@main
struct WidgetSnapshotCheck {
    @MainActor
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_791_961_200)
        for family in [WidgetFamily.systemSmall, .systemMedium] {
            for scheme in [ColorScheme.light, .dark] {
                for state in ["fresh", "stale", "empty", "low", "expired", "unknown-time", "future-time", "unknown-quota",
                              "incomplete", "incomplete-zero", "incomplete-stale"] {
                    let isStale = state == "stale" || state == "incomplete-stale"
                    let usage: WidgetUsageData? = state == "empty" ? nil : WidgetUsageData(
                        todayTokens: state == "incomplete-zero" ? 0 : 3_731_923,
                        weekTokens: state == "incomplete-zero" ? 0 : 1_376_638_466,
                        monthTokens: state == "incomplete-zero" ? 0 : 1_792_003_171,
                        contextTokens: 141_007, contextLimit: 475_000,
                        ratePercent: state == "unknown-quota" ? nil : (state == "low" ? 88 : 21), rateWindowMinutes: 10_080,
                        updatedAt: now.addingTimeInterval(isStale ? -3_600 : 0),
                        sampledAt: state == "unknown-time" ? nil : now.addingTimeInterval(isStale ? -3_600 : (state == "future-time" ? 60 : 0)),
                        rateResetsAt: now.addingTimeInterval(state == "expired" ? -60 : 86_400),
                        sourceIncomplete: state.hasPrefix("incomplete"))
                    let width: CGFloat = family == .systemSmall ? 170 : 360
                    let view = CodexMeterWidgetView(entry: UsageEntry(date: now, usage: usage), family: family)
                        .environment(\.colorScheme, scheme)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                        .padding(16)
                        .frame(width: width, height: 170)
                        .background(scheme == .dark ? Color.black : Color.white)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let cgImage = renderer.cgImage else { throw CheckFailure.render }
                    let bitmap = NSBitmapImageRep(cgImage: cgImage)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CheckFailure.render }
                    // Reject an all-background rendering, including empty cache states.
                    var ink = 0
                    for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                            let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                            if scheme == .dark ? brightness > 0.15 : brightness < 0.85 { ink += 1 }
                        }
                    }
                    guard ink > 100 else { throw CheckFailure.blank }
                    let name = "\(family == .systemSmall ? "small" : "medium")-\(scheme == .dark ? "dark" : "light")-\(state).png"
                    try png.write(to: output.appendingPathComponent(name))
                    print("PASS \(name), \(ink) foreground samples")
                }
            }
        }
    }

    enum CheckFailure: Error { case render, blank }
}
