import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var capturePanel: CapturePanel!
    private var hotkeyManager: HotkeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.string(forKey: "backendType") == nil {
            UserDefaults.standard.set(BackendType.notion.rawValue, forKey: "backendType")
        }

        capturePanel = CapturePanel()

        hotkeyManager = HotkeyManager()
        hotkeyManager.onHotKey = { [weak self] in
            self?.toggleCapture()
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if ObsidianBackend.shared.vaultPath.isEmpty &&
           (BackendType(rawValue: UserDefaults.standard.string(forKey: "backendType") ?? "") ?? .obsidian) == .obsidian {
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
