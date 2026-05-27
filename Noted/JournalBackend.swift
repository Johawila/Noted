import Foundation

enum BackendType: String {
    case obsidian
    case notion

    var displayName: String {
        switch self {
        case .notion: return "Notion"
        case .obsidian: return "Obsidian"
        }
    }
}

enum CaptureType: String, CaseIterable {
    case task = "Task"
    case note = "Note"
}

protocol JournalBackend {
    var displayName: String { get }
    func append(text: String, type: CaptureType) async throws
}
