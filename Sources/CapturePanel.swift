import AppKit
import SwiftUI

class CapturePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 96),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false

        contentView = NSHostingView(
            rootView: CaptureView(onDismiss: { [weak self] in self?.close() })
        )
    }

    func showAndFocus() {
        if let screen = NSScreen.main {
            let x = screen.frame.midX - frame.width / 2
            let y = screen.frame.maxY - (screen.frame.height * 0.35)
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Dismiss when focus moves to another window
    override func resignKey() {
        super.resignKey()
        close()
    }

    override var canBecomeKey: Bool { true }
}
