import AppKit
import Testing
@testable import CodexMeter

@MainActor
struct MenuBarQuotaAppearanceTests {
    @Test func rendersNativeQuotaStatesWithoutOpeningMenuBar() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CODEX_HEALTH_PREVIEW_DIR"] else { return }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_791_000_000)
        let samples: [(String, QuotaSampleState)] = [
            ("剩余 100%", sample(remaining: 100, now: now)),
            ("剩余 56%", sample(remaining: 56, now: now)),
            ("剩余 50%", sample(remaining: 50, now: now)),
            ("剩余 20%", sample(remaining: 20, now: now)),
            ("剩余 10%", sample(remaining: 10, now: now)),
            ("剩余 0%", sample(remaining: 0, now: now)),
            ("未知额度", sample(remaining: nil, now: now)),
            ("旧采样 56%", sample(remaining: 56, now: now, stale: true))
        ]
        let panelSize = NSSize(width: 610, height: 398)
        let canvas = MenuBarQuotaPreviewSurface(frame: NSRect(x: 0, y: 0, width: panelSize.width,
                                                              height: panelSize.height * 2), background: .white)
        let window = NSWindow(contentRect: canvas.bounds, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = canvas
        for (index, dark) in [false, true].enumerated() {
            let panel = MenuBarQuotaPreviewSurface(
                frame: NSRect(x: 0, y: CGFloat(index) * panelSize.height,
                              width: panelSize.width, height: panelSize.height),
                background: dark ? NSColor(white: 0.10, alpha: 1) : .white)
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            panel.appearance = appearance
            canvas.addSubview(panel)
            label(dark ? "深色 · 彩色圆环 + 系统文字" : "浅色 · 彩色圆环 + 系统文字", x: 18, y: 15,
                  width: 560, size: 15, weight: .semibold, in: panel)
            label("隐藏百分比", x: 160, y: 51, width: 120, size: 12, in: panel)
            label("显示百分比", x: 286, y: 51, width: 120, size: 12, in: panel)
            label("隐藏百分比 + 权限", x: 428, y: 51, width: 165, size: 12, in: panel)
            for (row, entry) in samples.enumerated() {
                let y = CGFloat(78 + row * 34)
                label(entry.0, x: 18, y: y + 5, width: 130, size: 13, in: panel)
                for (x, showsPercentage, attentionCount) in [(CGFloat(162), false, 0), (288, true, 0), (430, false, 2)] {
                    let display = MenuBarQuotaDisplay(sample: entry.1, showsPercentage: showsPercentage,
                                                     attentionCount: attentionCount)
                    let image = display.image(appearance: appearance)
                    #expect(!image.isTemplate)
                    #expect(image.size.height == 19)
                    let button = NSButton(image: image, target: nil, action: nil)
                    button.isBordered = false
                    button.title = display.title
                    button.font = NSFont.systemFont(ofSize: 13)
                    button.imagePosition = display.title.isEmpty ? .imageOnly : .imageLeading
                    button.imageScaling = .scaleNone
                    button.contentTintColor = nil
                    let titleWidth = (display.title as NSString).size(withAttributes: [
                        .font: NSFont.systemFont(ofSize: 13)
                    ]).width
                    let contentWidth = image.size.width + (display.title.isEmpty ? 0 : titleWidth + 6)
                    button.frame = NSRect(x: x, y: y, width: ceil(contentWidth) + 10, height: 28)
                    panel.addSubview(button)
                }
            }
            label("真实图像 · 原尺寸 · 虚构额度 · 未启动状态栏或主应用", x: 18, y: 368,
                  width: 570, size: 11, in: panel)
        }
        canvas.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("menu-bar-quota-light-dark.png"))
        #expect(bitmap.pixelsWide * 796 == bitmap.pixelsHigh * 610)
    }

    private func sample(remaining: Double?, now: Date, stale: Bool = false) -> QuotaSampleState {
        QuotaSampleState(percent: remaining.map { 100 - $0 },
                         sampledAt: remaining == nil ? nil : now.addingTimeInterval(stale ? -1_800 : -30),
                         resetsAt: remaining == nil ? nil : now.addingTimeInterval(86_400), now: now)
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat,
                       weight: NSFont.Weight = .regular, in view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = .labelColor
        label.frame = NSRect(x: x, y: y, width: width, height: 22)
        view.addSubview(label)
    }
}

@MainActor
private final class MenuBarQuotaPreviewSurface: NSView {
    private let background: NSColor
    override var isFlipped: Bool { true }

    init(frame: NSRect, background: NSColor) {
        self.background = background
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { return nil }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
    }
}
