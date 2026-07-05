import Foundation
import SwiftUI
import Combine

struct TagInfo: Equatable {
    let name: String
    let color: String  // Notion palette name, e.g. "blue", "green", "" = none assigned
}

class TagManager: ObservableObject {
    static let shared = TagManager()
    private init() {}

    @Published var projects: [TagInfo] = []
    @Published var people: [TagInfo] = []

    private var vaultPath: String { UserDefaults.standard.string(forKey: "vaultPath") ?? "" }

    // Autocomplete is sourced from the Obsidian vault: #project ← Organisation/Projects,
    // @person ← Organisation/People (one markdown file per entity).
    func fetchAll() async {
        let projects = readNames(folder: "Organisation/Projects")
        let people = readNames(folder: "Organisation/People")
        await MainActor.run {
            self.projects = projects
            self.people = people
        }
    }

    func suggestions(for prefix: String, partial: String) -> [TagInfo] {
        let list = prefix == "#" ? projects : people
        let normalized = partial.replacingOccurrences(of: "\u{00A0}", with: " ")
        guard !normalized.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(normalized) }
    }

    func color(for name: String, prefix: String) -> String {
        let list = prefix == "#" ? projects : people
        return list.first { $0.name == name }?.color ?? ""
    }

    // MARK: - Private

    private func readNames(folder: String) -> [TagInfo] {
        guard !vaultPath.isEmpty else { return [] }
        let dir = URL(fileURLWithPath: vaultPath).appendingPathComponent(folder)
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == "md" }
            .map { TagInfo(name: $0.deletingPathExtension().lastPathComponent, color: "") }
            .sorted { $0.name < $1.name }
    }
}

extension TagInfo {
    var swiftUIColor: Color {
        switch color {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "gray": return .gray
        default: return .secondary
        }
    }
}
