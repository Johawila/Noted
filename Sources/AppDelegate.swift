import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var capturePanel: CapturePanel!
    private var hotkeyManager: HotkeyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only — no dock icon
        NSApp.setActivationPolicy(.accessory)

        // Status bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "square.and.pencil",
            accessibilityDescription: "Noted"
        )

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "New entry  ⌘⇧Space", action: #selector(showCapture), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        capturePanel = CapturePanel()

        hotkeyManager = HotkeyManager()
        hotkeyManager.onHotKey = { [weak self] in
            self?.toggleCapture()
        }

        // First launch: prompt for vault path
        if JournalWriter.shared.vaultPath.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openSettings()
            }
        }
    }

    @objc private func showCapture() { toggleCapture() }

    @objc private func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleCapture() {
        if capturePanel.isVisible {
            capturePanel.close()
        } else {
            capturePanel.showAndFocus()
        }
    }
}
