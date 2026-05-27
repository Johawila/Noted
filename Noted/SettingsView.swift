import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("backendType") private var backendTypeRaw = BackendType.notion.rawValue
    @AppStorage("vaultPath") private var vaultPath = ""
    private var notionReady: Bool {
        let hasKey = !(UserDefaults.shared.string(forKey: "notionApiKey") ?? "").isEmpty
        let hasDb = !(UserDefaults.shared.string(forKey: "hivemind.dailyNotesDbId") ?? "").isEmpty
        return hasKey && hasDb
    }

    private var backendType: BackendType {
        BackendType(rawValue: backendTypeRaw) ?? .obsidian
    }

    var body: some View {
        Form {
            Section("Backend") {
                Picker("Post entries to", selection: $backendTypeRaw) {
                    Text("Obsidian").tag(BackendType.obsidian.rawValue)
                    Text("Notion").tag(BackendType.notion.rawValue)
                }
                .pickerStyle(.radioGroup)
            }

            if backendType == .obsidian {
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
            } else {
                Section("Notion") {
                    if notionReady {
                        Label("Connected via Hivemind", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Run workspace setup in Hivemind first", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
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
