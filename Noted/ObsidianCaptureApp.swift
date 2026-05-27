import SwiftUI

@main
struct NotedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Noted", systemImage: "square.and.pencil") {
            NotedMenuBarView(appDelegate: appDelegate)
        }

        Settings {
            SettingsView()
        }
    }
}
