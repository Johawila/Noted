import Foundation
import AppKit
import UserNotifications

class ObsidianBackend: JournalBackend {
    static let shared = ObsidianBackend()
    private init() {}

    var displayName: String { "Obsidian" }

    var vaultPath: String {
        get { UserDefaults.standard.string(forKey: "vaultPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "vaultPath") }
    }

    func promptForVault() {
        NSApp.activate(ignoringOtherApps: true)
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

    func append(text: String, type: CaptureType) async throws {
        guard !vaultPath.isEmpty else {
            await MainActor.run { promptForVault() }
            return
        }

        let today = todayDateString()
        let journalFolder = URL(fileURLWithPath: vaultPath).appendingPathComponent("Journal")
        let fileURL = journalFolder.appendingPathComponent("\(today).md")

        try FileManager.default.createDirectory(at: journalFolder, withIntermediateDirectories: true)

        var content: String
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            content = existing
        } else {
            content = buildTemplate(dateStr: today)
        }

        let line = type == .task ? "- [ ] \(text)" : text
        let section = type == .task ? "## Tasks" : "### Notes"
        content = insertAfterHeader(content: content, header: section, newLine: line)

        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        notify(text: text, type: type)
    }

    // MARK: - Private

    private func notify(text: String, type: CaptureType) {
        let content = UNMutableNotificationContent()
        content.title = type == .task ? "Task added" : "Note added"
        content.body = text
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func todayDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func buildTemplate(dateStr: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let date = f.date(from: dateStr) else { return "" }

        let display = DateFormatter()
        display.dateFormat = "EEEE, MMMM d, yyyy"

        return """
        ---
        tags: []
        ---
        # \(display.string(from: date))

        ## Tasks

        ## Journal
        ### Focus

        ### Notes

        ### End of Day
        """
    }

    private func insertAfterHeader(content: String, header: String, newLine: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let headerIdx = lines.firstIndex(where: { $0 == header }) else {
            return content + "\n" + newLine
        }

        var insertAt = lines.count
        for i in (headerIdx + 1)..<lines.count {
            if lines[i].hasPrefix("## ") || lines[i].hasPrefix("### ") {
                insertAt = i
                while insertAt > headerIdx + 1 && lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    insertAt -= 1
                }
                break
            }
        }

        lines.insert(newLine, at: insertAt)
        return lines.joined(separator: "\n")
    }
}
