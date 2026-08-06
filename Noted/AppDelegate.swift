import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var capturePanel: CapturePanel!
    private var hotkeyManager: HotkeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        capturePanel = CapturePanel()

        hotkeyManager = HotkeyManager()
        hotkeyManager.onHotKey = { [weak self] in
            self?.toggleCapture()
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // No vault yet means nothing can be saved — open Settings so that's obvious.
        if ObsidianBackend.shared.vaultPath.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    func toggleCapture() {
        if capturePanel.isVisible {
            capturePanel.close()
        } else {
            capturePanel.showAndFocus()
        }
    }
}
