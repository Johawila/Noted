import SwiftUI

struct NotedMenuBarView: View {
    let appDelegate: AppDelegate

    var body: some View {
        Button("New entry  ⌘⇧Space") {
            appDelegate.toggleCapture()
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
