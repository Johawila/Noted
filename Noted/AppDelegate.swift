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

        // Picks up a session already running — the state file outlives the app, so quitting
        // mid-pomodoro and relaunching resumes rather than restarts.
        PomodoroTimer.shared.begin()

        // Quitting mid-ingest strands the progress note in the vault. Nothing can be in flight
        // at launch, so any note still sitting there is an orphan.
        IngestProgress.clearStale()

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
