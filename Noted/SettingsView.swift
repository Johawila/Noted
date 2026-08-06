import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("vaultPath") private var vaultPath = ""
    @AppStorage("hivemind.anthropicApiKey", store: .shared) private var anthropicApiKey = ""
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Obsidian Vault") {
                HStack {
                    Text(vaultPath.isEmpty ? "No vault selected" : URL(fileURLWithPath: vaultPath).lastPathComponent)
                        .foregroundStyle(vaultPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseVault() }
                }
                if !vaultPath.isEmpty {
                    Text(vaultPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Section("Article ingestion") {
                SecureField("Anthropic API Key", text: $anthropicApiKey)
                Text("Used to read & summarise pasted article links. Shared with Hivemind.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                Text("Installs a LaunchAgent pointing at this copy of the app, so reinstalling doesn't drop it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Hotkey") {
                HStack {
                    Text("Show capture bar")
                    Spacer()
                    Text("⌘ ⇧ Space").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding(.bottom)
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }

    // Reverts the toggle to the real on-disk state if writing the LaunchAgent fails, so the
    // checkbox never claims something that isn't true.
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try LoginItem.enable() } else { try LoginItem.disable() }
        } catch {
            launchAtLogin = LoginItem.isEnabled
        }
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your Obsidian vault folder"
        panel.prompt = "Select Vault"
        if panel.runModal() == .OK, let url = panel.url {
            vaultPath = url.path
        }
    }
}
