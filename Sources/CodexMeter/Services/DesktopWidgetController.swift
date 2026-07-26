import AppKit
import SwiftUI

@MainActor
final class DesktopWidgetController {
    private var panel: NSPanel?

    func toggle(store: UsageStore) {
        if panel?.isVisible == true {
            hide()
        } else {
            show(store: store)
        }
    }

    func show(store: UsageStore) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 80, y: 110, width: 300, height: 245),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.setFrameAutosaveName("CodexMeterDesktopWidget")
        panel.contentView = NSHostingView(
            rootView: DesktopWidgetView(store: store) { [weak self] in
                self?.hide()
            }
        )
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
        Task { await store.refresh() }
    }

    func hide() {
        panel?.orderOut(nil)
    }
}
