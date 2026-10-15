import AppKit
import SwiftUI

/// Shared by the Mac app and WidgetKit extension; light colors match the UI palette.
enum DashboardPalette {
    static let ink = adaptive(light: 0x242426, dark: 0xF5F5F7)
    static let secondaryInk = adaptive(light: 0x86868B, dark: 0x98989D)
    static let chart = adaptive(light: 0x555558, dark: 0xAEAEB2)
    static let progress = adaptive(light: 0x636366, dark: 0x8E8E93)
    static let divider = adaptive(light: 0xE8E8ED, dark: 0x38383A)

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
