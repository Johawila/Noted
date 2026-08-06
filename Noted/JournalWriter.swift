import Foundation
import AppKit

class JournalWriter {
    static let shared = JournalWriter()
    private init() {}

    func append(text: String, type: CaptureType) {
        Task {
            do {
                try await ObsidianBackend.shared.append(text: text, type: type)
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
