import Foundation
import AppKit

class JournalWriter {
    static let shared = JournalWriter()
    private init() {}

    var activeBackend: JournalBackend {
        let raw = UserDefaults.standard.string(forKey: "backendType") ?? BackendType.notion.rawValue
        switch BackendType(rawValue: raw) ?? .notion {
        case .obsidian: return ObsidianBackend.shared
        case .notion: return NotionBackend.shared
        }
    }

    func append(text: String, type: CaptureType) {
        Task {
            do {
                try await activeBackend.append(text: text, type: type)
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Could not save entry"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }
}
