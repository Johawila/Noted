import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("vaultPath") private var vaultPath = ""

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
