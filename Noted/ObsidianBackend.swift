import Foundation
import AppKit
import UserNotifications

// Writes quick captures into the SecondBrain Obsidian vault:
//  - the day's note at Journal/YYYY-MM-DD.md (## Tasks / ## Notes)
//  - #project → [[Project]], @person → [[Organisation/People/Name|Name]]
//  - a capture tagged @person is ALSO copied onto that person's page (## Notes).
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
        let vault = URL(fileURLWithPath: vaultPath)
        let entry = TagParser.parse(text)
        let wikified = wikify(text)

        try appendToDaily(vault: vault, wikified: wikified, type: type)
        for person in entry.people {
            try appendToEntity(vault: vault, folder: "Organisation/People", name: person, wikified: wikified, type: type, template: personTemplate(person))
        }
        for project in entry.projects {
            try appendToEntity(vault: vault, folder: "Organisation/Projects", name: project, wikified: wikified, type: type, template: projectTemplate(project))
        }
        notify(text: text, type: type)
    }

    // MARK: - Daily note

    private func appendToDaily(vault: URL, wikified: String, type: CaptureType) throws {
        let today = todayDateString()
        let folder = vault.appendingPathComponent("Journal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("\(today).md")

        var content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? dailyTemplate(today)
        // Notes carry a capture time so the day reads as an observed timeline; tasks stay bare.
        let line = type == .task ? "- [ ] \(wikified)" : "- \(nowTimeString()) — \(wikified)"
        let header = type == .task ? "## Tasks" : "## Notes"
        content = insertAfterHeader(content: content, header: header, newLine: line)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Person page (dual-write)

    // Ensures an entity page (person or project) exists, creating it from `template` if not.
    // Notes are mirrored as a dated bullet under ## Notes. Tasks are NOT copied here — the
    // page's ## Tasks Dataview block surfaces them live from the Journal (single source of
    // truth, no checkbox drift), so a task capture only guarantees the page exists.
    private func appendToEntity(vault: URL, folder: String, name: String, wikified: String, type: CaptureType, template: String) throws {
        let dir = vault.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(fileSafe(name)).md")
        let exists = FileManager.default.fileExists(atPath: fileURL.path)

        if type == .task {
            if !exists { try template.write(to: fileURL, atomically: true, encoding: .utf8) }
            return
        }

        var content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? template
        let line = "- \(todayDateString()) — \(wikified)"
        content = insertAfterHeader(content: content, header: "## Notes", newLine: line)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Tag → wikilink

    private func wikify(_ text: String) -> String {
        TagParser.tokenize(text).map { token in
            switch token {
            case .text(let t): return t
            case .person(let name): return "[[Organisation/People/\(fileSafe(name))|\(name)]]"
            case .project(let name): return "[[\(fileSafe(name))]]"
            }
        }.joined()
    }

    // MARK: - Templates / helpers

    private func dailyTemplate(_ dateStr: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let display = DateFormatter(); display.dateFormat = "EEEE, MMMM d, yyyy"
        let title = f.date(from: dateStr).map { display.string(from: $0) } ?? dateStr
        // Mirrors Meta/daily-template.md: the context strip sits BETWEEN the title and
        // ## Tasks so appended notes (which go after the last header) land at file end.
        return """
        # \(title)

        ```dataviewjs
        await dv.view("Meta/daily");
        ```

        ## Tasks

        ## Notes
        """
    }

    private func personTemplate(_ name: String) -> String {
        """
        ---
        role:
        tags: []
        manager:
        company:
        ---

        # \(name)

        ## 1:1 log

        ## Tasks
        ```dataview
        TASK FROM "Journal" WHERE contains(outlinks, this.file.link)
        ```

        ## Notes

        ## Mentioned in
        ```dataview
        LIST WHERE contains(file.outlinks, this.file.link)
        ```
        """
    }

    private func projectTemplate(_ name: String) -> String {
        """
        ---
        status:
        ---

        # \(name)

        ## Tasks
        ```dataview
        TASK FROM "Journal" WHERE contains(outlinks, this.file.link)
        ```

        ## Notes

        ## Mentioned in
        ```dataview
        LIST WHERE contains(file.outlinks, this.file.link)
        ```
        """
    }

    private func fileSafe(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    private func notify(text: String, type: CaptureType) {
        let content = UNMutableNotificationContent()
        content.title = type == .task ? "Task added" : "Note added"
        content.body = text
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func todayDateString() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func nowTimeString() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date())
    }

    private func insertAfterHeader(content: String, header: String, newLine: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let headerIdx = lines.firstIndex(where: { $0 == header }) else {
            return content + "\n\n" + header + "\n" + newLine
        }
        var insertAt = lines.count
        for i in (headerIdx + 1)..<lines.count {
            if lines[i].hasPrefix("## ") {
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
