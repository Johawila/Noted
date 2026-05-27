import Foundation

enum NotionError: Error, LocalizedError {
    case notConfigured
    case apiError(Int, String)
    case noPageId

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Notion is not configured. Run workspace setup in Dispatch."
        case .apiError(let status, let message):
            return "Notion API error (\(status)): \(message)"
        case .noPageId:
            return "Notion returned no page ID."
        }
    }
}

class NotionBackend: JournalBackend {
    static let shared = NotionBackend()
    private init() {}

    var displayName: String { "Notion" }

    private let baseURL = "https://api.notion.com/v1"
    private let notionVersion = "2022-06-28"

    private var apiKey: String { UserDefaults.shared.string(forKey: "notionApiKey") ?? "" }
    private var tasksDbId: String { UserDefaults.shared.string(forKey: "hivemind.tasksDbId") ?? "" }
    private var todayPageId: String { UserDefaults.shared.string(forKey: "hivemind.todayPageId") ?? "" }
    private var projectsDbId: String { UserDefaults.shared.string(forKey: "hivemind.projectsDbId") ?? "" }
    private var peopleDbId: String { UserDefaults.shared.string(forKey: "hivemind.peopleDbId") ?? "" }
    private var notesDbId: String { UserDefaults.shared.string(forKey: "hivemind.notesDbId") ?? "" }

    func append(text: String, type: CaptureType) async throws {
        guard !apiKey.isEmpty else { throw NotionError.notConfigured }

        switch type {
        case .task:
            try await appendTask(text: text)
        case .note:
            try await appendNote(text: text)
        }
    }

    // MARK: - Task → Tasks database + mirror to project/person pages

    private func appendTask(text: String) async throws {
        guard !tasksDbId.isEmpty else { throw NotionError.notConfigured }

        let entry = TagParser.parse(text)
        let today = todayDateString()

        var properties: [String: Any] = [
            "Name": ["title": [["type": "text", "text": ["content": entry.text]]]],
            "Date": ["date": ["start": today]],
            "Done": ["checkbox": false]
        ]

        var projectPageId: String? = nil
        var personPageId: String? = nil

        if let projectName = entry.projectTag {
            guard !projectsDbId.isEmpty else { throw NotionError.notConfigured }
            let pageId = try await findOrCreatePage(databaseId: projectsDbId, name: projectName)
            properties["Project"] = ["relation": [["id": pageId]]]
            projectPageId = pageId
        }

        if let personName = entry.personTag {
            guard !peopleDbId.isEmpty else { throw NotionError.notConfigured }
            let pageId = try await findOrCreatePage(databaseId: peopleDbId, name: personName)
            properties["Person"] = ["relation": [["id": pageId]]]
            personPageId = pageId
        }

        let url = URL(string: "\(baseURL)/pages")!
        var request = makeRequest(url: url, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "parent": ["database_id": tasksDbId],
            "properties": properties
        ])
        _ = try await perform(request)

        // Write synced to_do block on Today page, mirror to project/person pages
        if !todayPageId.isEmpty {
            let children = try await fetchBlockChildren(blockId: todayPageId)
            let afterId = findInsertionPoint(in: children, sectionTitle: "Tasks")
            let hasMirror = projectPageId != nil || personPageId != nil

            let projectColor = entry.projectTag.flatMap { n in
                let c = TagManager.shared.color(for: n, prefix: "#"); return c.isEmpty ? nil : c
            }
            let personColor = entry.personTag.flatMap { n in
                let c = TagManager.shared.color(for: n, prefix: "@"); return c.isEmpty ? nil : c
            }
            let richText = coloredRichText(text: text, entry: entry,
                projectPageId: projectPageId, projectColor: projectColor,
                personPageId: personPageId, personColor: personColor)

            if hasMirror {
                let syncedBlock: [String: Any] = [
                    "object": "block", "type": "synced_block",
                    "synced_block": [
                        "synced_from": NSNull(),
                        "children": [[
                            "object": "block", "type": "to_do",
                            "to_do": ["rich_text": richText, "checked": false]
                        ]]
                    ]
                ]
                let originId = try await appendBlockReturningId(to: todayPageId, block: syncedBlock, afterId: afterId)
                let refBlock: [String: Any] = [
                    "object": "block", "type": "synced_block",
                    "synced_block": ["synced_from": ["type": "block_id", "block_id": originId]]
                ]
                if let pid = projectPageId { try await appendBlock(to: pid, block: refBlock, afterId: nil) }
                if let pid = personPageId { try await appendBlock(to: pid, block: refBlock, afterId: nil) }
            } else {
                let toDoBlock: [String: Any] = [
                    "object": "block", "type": "to_do",
                    "to_do": ["rich_text": richText, "checked": false]
                ]
                try await appendBlock(to: todayPageId, block: toDoBlock, afterId: afterId)
            }
        }
    }

    // MARK: - Note → Today page Notes section + synced mirror to project/person pages

    private func appendNote(text: String) async throws {
        guard !todayPageId.isEmpty else { throw NotionError.notConfigured }

        let entry = TagParser.parse(text)

        // Fetch page IDs first so we can use them in the mention pills
        var projectPageId: String? = nil
        var personPageId: String? = nil
        if let name = entry.projectTag, !projectsDbId.isEmpty {
            projectPageId = try await findOrCreatePage(databaseId: projectsDbId, name: name)
        }
        if let name = entry.personTag, !peopleDbId.isEmpty {
            personPageId = try await findOrCreatePage(databaseId: peopleDbId, name: name)
        }
        let hasMirror = projectPageId != nil || personPageId != nil

        let children = try await fetchBlockChildren(blockId: todayPageId)
        let afterId = findInsertionPoint(in: children, sectionTitle: "Notes")

        let projectColor = entry.projectTag.flatMap { n in
            let c = TagManager.shared.color(for: n, prefix: "#"); return c.isEmpty ? nil : c
        }
        let personColor = entry.personTag.flatMap { n in
            let c = TagManager.shared.color(for: n, prefix: "@"); return c.isEmpty ? nil : c
        }
        let richText = coloredRichText(text: text, entry: entry,
            projectPageId: projectPageId, projectColor: projectColor,
            personPageId: personPageId, personColor: personColor)

        // If mirroring is needed, write as a synced_block so edits sync everywhere
        if hasMirror {
            let syncedBlock: [String: Any] = [
                "object": "block", "type": "synced_block",
                "synced_block": [
                    "synced_from": NSNull(),
                    "children": [[
                        "object": "block", "type": "paragraph",
                        "paragraph": ["rich_text": richText]
                    ]]
                ]
            ]
            let originId = try await appendBlockReturningId(to: todayPageId, block: syncedBlock, afterId: afterId)
            let refBlock: [String: Any] = [
                "object": "block", "type": "synced_block",
                "synced_block": ["synced_from": ["type": "block_id", "block_id": originId]]
            ]
            if let pid = projectPageId { try await appendBlock(to: pid, block: refBlock, afterId: nil) }
            if let pid = personPageId { try await appendBlock(to: pid, block: refBlock, afterId: nil) }
        } else {
            let noteBlock: [String: Any] = [
                "object": "block", "type": "paragraph",
                "paragraph": ["rich_text": richText]
            ]
            try await appendBlock(to: todayPageId, block: noteBlock, afterId: afterId)
        }

        if !notesDbId.isEmpty {
            try await createNotesDbEntry(entry: entry, rawText: text,
                                         projectPageId: projectPageId, personPageId: personPageId)
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.hivemind.noteAdded"), object: nil, userInfo: nil, deliverImmediately: true
            )
        }
    }

    private func createNotesDbEntry(entry: ParsedEntry, rawText: String,
                                     projectPageId: String?, personPageId: String?) async throws {
        let title = entry.text.count > 80 ? String(entry.text.prefix(80)) + "…" : entry.text
        var tags: [[String: Any]] = []
        if let tag = entry.projectTag { tags.append(["name": tag]) }

        var properties: [String: Any] = [
            "Name": ["title": [["type": "text", "text": ["content": title]]]],
            "Content": ["rich_text": [["type": "text", "text": ["content": rawText]]]],
            "Tags": ["multi_select": tags]
        ]
        if let pid = projectPageId { properties["Project"] = ["relation": [["id": pid]]] }
        if let pid = personPageId  { properties["Person"]  = ["relation": [["id": pid]]] }

        let url = URL(string: "\(baseURL)/pages")!
        var request = makeRequest(url: url, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "parent": ["database_id": notesDbId],
            "properties": properties
        ])
        _ = try await perform(request)
    }

    // MARK: - Helpers

    private func findOrCreatePage(databaseId: String, name: String) async throws -> String {
        let url = URL(string: "\(baseURL)/databases/\(databaseId)/query")!
        var request = makeRequest(url: url, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "filter": ["property": "Name", "title": ["equals": name]]
        ])
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let existing = (json?["results"] as? [[String: Any]])?.first?["id"] as? String {
            return existing
        }

        var createProperties: [String: Any] = [
            "Name": ["title": [["type": "text", "text": ["content": name]]]],
            "Color": ["select": ["name": autoColor(for: name)]]
        ]
        if databaseId == projectsDbId {
            createProperties["Status"] = ["select": ["name": "Active"]]
        }
        let createUrl = URL(string: "\(baseURL)/pages")!
        var createRequest = makeRequest(url: createUrl, method: "POST")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "parent": ["database_id": databaseId],
            "properties": createProperties
        ])
        let createData = try await perform(createRequest)
        let createJson = try JSONSerialization.jsonObject(with: createData) as? [String: Any]
        guard let pageId = createJson?["id"] as? String else { throw NotionError.noPageId }
        Task { await TagManager.shared.fetchAll() }
        return pageId
    }

    private func autoColor(for name: String) -> String {
        let palette = ["red", "orange", "yellow", "green", "blue", "purple", "pink", "gray"]
        let hash = name.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return palette[hash % palette.count]
    }

    // Replaces tag words with colored page mention pills; non-tag text is plain.
    // Handles trailing punctuation (e.g. #ICA. → mention + ".") and two-word person names.
    private func coloredRichText(text: String, entry: ParsedEntry,
                                  projectPageId: String?, projectColor: String?,
                                  personPageId: String?, personColor: String?) -> [[String: Any]] {
        let words = text.components(separatedBy: " ")
        var result: [[String: Any]] = []
        var buffer = ""
        var i = 0

        while i < words.count {
            let word = words[i]
            let normalized = word.replacingOccurrences(of: "\u{00A0}", with: " ")

            var matchedPageId: String? = nil
            var matchedColor: String? = nil
            var trailingPunct = ""
            var wordsConsumed = 1

            if normalized.hasPrefix("#"), let projectTag = entry.projectTag, let pid = projectPageId {
                let tagPart = String(normalized.dropFirst())
                let stripped = TagParser.stripTrailingPunctuation(tagPart)
                if stripped == projectTag {
                    trailingPunct = String(tagPart.dropFirst(stripped.count))
                    matchedPageId = pid
                    matchedColor = projectColor
                }
            } else if normalized.hasPrefix("@"), let personTag = entry.personTag, let pid = personPageId {
                let tagPart = String(normalized.dropFirst()).replacingOccurrences(of: "\u{00A0}", with: " ")
                let stripped = TagParser.stripTrailingPunctuation(tagPart)
                if stripped == personTag {
                    // Single-word person name
                    trailingPunct = String(tagPart.dropFirst(stripped.count))
                    matchedPageId = pid
                    matchedColor = personColor
                } else if personTag.hasPrefix(stripped + " "), i + 1 < words.count {
                    // Potential two-word person name — check if next word is the surname
                    let nextWord = words[i + 1].replacingOccurrences(of: "\u{00A0}", with: " ")
                    let nextStripped = TagParser.stripTrailingPunctuation(nextWord)
                    let expectedSurname = String(personTag.dropFirst(stripped.count + 1))
                    if nextStripped == expectedSurname {
                        trailingPunct = String(nextWord.dropFirst(nextStripped.count))
                        matchedPageId = pid
                        matchedColor = personColor
                        wordsConsumed = 2
                    }
                }
            }

            if let pid = matchedPageId {
                if !buffer.isEmpty {
                    result.append(["type": "text", "text": ["content": buffer]])
                    buffer = ""
                }
                if i > 0 { result.append(["type": "text", "text": ["content": " "]]) }
                var mention: [String: Any] = [
                    "type": "mention",
                    "mention": ["type": "page", "page": ["id": pid]]
                ]
                if let c = matchedColor { mention["annotations"] = ["color": c + "_background"] }
                result.append(mention)
                if !trailingPunct.isEmpty { buffer = trailingPunct }
            } else {
                let sep = i > 0 ? " " : ""
                buffer += sep + word
            }

            i += wordsConsumed
        }

        if !buffer.isEmpty { result.append(["type": "text", "text": ["content": buffer]]) }
        return result.isEmpty ? [["type": "text", "text": ["content": text]]] : result
    }

    private func mentionPageBlock(pageId: String) -> [String: Any] {
        let mention: [String: Any] = [
            "type": "mention",
            "mention": ["type": "page", "page": ["id": pageId]]
        ]
        return [
            "object": "block", "type": "paragraph",
            "paragraph": ["rich_text": [mention]]
        ]
    }

    private func fetchBlockChildren(blockId: String) async throws -> [[String: Any]] {
        let url = URL(string: "\(baseURL)/blocks/\(blockId)/children?page_size=100")!
        let request = makeRequest(url: url, method: "GET")
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["results"] as? [[String: Any]] ?? []
    }

    private func findInsertionPoint(in blocks: [[String: Any]], sectionTitle: String) -> String? {
        var inSection = false
        var lastId: String? = nil
        for block in blocks {
            let type = block["type"] as? String ?? ""
            let id = block["id"] as? String ?? ""

            var title = ""
            if type == "heading_2" {
                let content = block["heading_2"] as? [String: Any]
                title = (content?["rich_text"] as? [[String: Any]])?.compactMap { $0["plain_text"] as? String }.joined() ?? ""
            } else if type == "callout" {
                let content = block["callout"] as? [String: Any]
                title = (content?["rich_text"] as? [[String: Any]])?.compactMap { $0["plain_text"] as? String }.joined() ?? ""
            }

            if !title.isEmpty {
                let matches = title == sectionTitle || title.hasSuffix(sectionTitle)
                if matches { inSection = true; lastId = id; continue }
                if inSection { break }
            }
            if inSection && type == "divider" { break }
            if inSection { lastId = id }
        }
        return lastId
    }

    private func appendBlock(to pageId: String, block: [String: Any], afterId: String?) async throws {
        let url = URL(string: "\(baseURL)/blocks/\(pageId)/children")!
        var request = makeRequest(url: url, method: "PATCH")
        var body: [String: Any] = ["children": [block]]
        if let afterId { body["after"] = afterId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    private func appendBlockReturningId(to pageId: String, block: [String: Any], afterId: String?) async throws -> String {
        let url = URL(string: "\(baseURL)/blocks/\(pageId)/children")!
        var request = makeRequest(url: url, method: "PATCH")
        var body: [String: Any] = ["children": [block]]
        if let afterId { body["after"] = afterId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = (json?["results"] as? [[String: Any]])?.first?["id"] as? String else {
            throw NotionError.noPageId
        }
        return id
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NotionError.apiError(http.statusCode, message)
        }
        return data
    }

    private func todayDateString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
