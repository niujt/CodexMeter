import AppKit
import SwiftUI

/// Shared by the Mac app and WidgetKit extension; light colors match the UI palette.
enum DashboardPalette {
    static let ink = adaptive(light: 0x202020, dark: 0xF2F2F2)
    static let secondaryInk = adaptive(light: 0x666666, dark: 0xB0B0B0)
    static let chart = adaptive(light: 0x555555, dark: 0xB8B8B8)
    static let progress = adaptive(light: 0x666666, dark: 0xA3A3A3)
    static let divider = adaptive(light: 0xE2E2E2, dark: 0x383838)
    static let canvas = adaptive(light: 0xF5F5F5, dark: 0x181818)
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x222222)
    static let hover = adaptive(light: 0xEAEAEA, dark: 0x303030)

    // The small popover needs a stable surface even over a bright wallpaper.
    static let popoverBackground = surface
    static let popoverSecondaryInk = secondaryInk

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
