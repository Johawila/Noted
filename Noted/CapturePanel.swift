import AppKit
import SwiftUI

class CapturePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 160),
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
        appearance = NSAppearance(named: .darkAqua)

        contentView = NSHostingView(rootView: CaptureView(
            onDismiss: { [weak self] in self?.close() },
            onHeightChange: { [weak self] height in
                guard let self, self.isVisible else { return }
                var f = self.frame
                f.origin.y += f.height - height
                f.size.height = height
                self.setFrame(f, display: true, animate: false)
            }
        ))
    }

    func showAndFocus() {
        if let screen = NSScreen.main {
            let x = screen.frame.midX - frame.width / 2
            let y = screen.frame.maxY - (screen.frame.height * 0.38)
            setFrameOrigin(NSPoint(x: x, y: y))
        }
        NotificationCenter.default.post(name: .captureWillShow, object: nil)
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    override func resignKey() {
        super.resignKey()
        close()
    }

    override var canBecomeKey: Bool { true }
}
