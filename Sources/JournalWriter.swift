import Foundation

class JournalWriter {
    static let shared = JournalWriter()
    private init() {}

    var vaultPath: String {
        get { UserDefaults.standard.string(forKey: "vaultPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "vaultPath") }
    }

    func append(text: String, type: CaptureType) {
        guard !vaultPath.isEmpty else { return }

        let today = todayDateString()
        let journalFolder = URL(fileURLWithPath: vaultPath).appendingPathComponent("Journal")
        let fileURL = journalFolder.appendingPathComponent("\(today).md")

        try? FileManager.default.createDirectory(at: journalFolder, withIntermediateDirectories: true)

        var content: String
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            content = existing
        } else {
            content = buildTemplate(dateStr: today)
        }

        let line = type == .task ? "- [ ] \(text)" : text
        let section = type == .task ? "## Tasks" : "## Journal"
        content = insertAfterHeader(content: content, header: section, newLine: line)

        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Private

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
