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

    private let baseURL = "https://api.notion.com/v1"
    private let notionVersion = "2022-06-28"

    private var apiKey: String { UserDefaults.shared.string(forKey: "notionApiKey") ?? "" }
    private var projectsDbId: String { UserDefaults.shared.string(forKey: "hivemind.projectsDbId") ?? "" }
    private var peopleDbId: String { UserDefaults.shared.string(forKey: "hivemind.peopleDbId") ?? "" }

    func fetchAll() async {
        async let p = fetchTagInfos(databaseId: projectsDbId)
        async let pe = fetchTagInfos(databaseId: peopleDbId)
        let (projects, people) = await (p, pe)
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

    private func fetchTagInfos(databaseId: String) async -> [TagInfo] {
        guard !databaseId.isEmpty, !apiKey.isEmpty else { return [] }

        let url = URL(string: "\(baseURL)/databases/\(databaseId)/query")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [:])

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }

        return results.compactMap { page -> TagInfo? in
            let props = page["properties"] as? [String: Any]
            let nameProp = props?["Name"] as? [String: Any]
            let titleArr = nameProp?["title"] as? [[String: Any]]
            guard let name = titleArr?.first?["plain_text"] as? String else { return nil }
            let colorProp = props?["Color"] as? [String: Any]
            let color = (colorProp?["select"] as? [String: Any])?["name"] as? String ?? ""
            return TagInfo(name: name, color: color)
        }
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
