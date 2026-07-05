import Foundation

enum ArticleWriteError: Error, LocalizedError {
    case notConfigured
    case apiError(Int, String)
    case noPageId

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Articles/Concepts databases not found. Run workspace setup in Hivemind."
        case .apiError(let status, let message): return "Notion API error (\(status)): \(message)"
        case .noPageId: return "Notion returned no page ID."
        }
    }
}

struct ArticleWriteResult {
    let articlePageURL: String
    let conceptCount: Int
}

// A just-created Article page in "Processing" state, with the id of its progress
// callout block so the orchestrator can update it as each phase completes.
struct ArticlePlaceholder {
    let articleId: String
    let progressBlockId: String?
    let articleURL: String
}

// Writes an analyzed article into Notion: one Article page plus one durable Concept
// page per concept (created or expanded), cross-linked both ways.
class NotionArticleWriter {
    static let shared = NotionArticleWriter()
    private init() {}

    private let baseURL = "https://api.notion.com/v1"
    private let notionVersion = "2022-06-28"

    private var apiKey: String { UserDefaults.shared.string(forKey: "notionApiKey") ?? "" }
    private var articlesDbId: String { UserDefaults.shared.string(forKey: "hivemind.articlesDbId") ?? "" }
    private var conceptsDbId: String { UserDefaults.shared.string(forKey: "hivemind.conceptsDbId") ?? "" }

    // Names of every existing concept page — passed to the AI so it can reuse them.
    func existingConceptNames() async throws -> [String] {
        guard !conceptsDbId.isEmpty else { throw ArticleWriteError.notConfigured }
        let results = try await queryDatabase(databaseId: conceptsDbId, body: ["page_size": 100])
        return results.compactMap { title(of: $0) }
    }

    // Phase 1 — create the Article page immediately in "Processing" state so it shows
    // up in Notion right away with a status pill and a progress line.
    func createPlaceholder(url: String) async throws -> ArticlePlaceholder {
        guard !apiKey.isEmpty, !articlesDbId.isEmpty, !conceptsDbId.isEmpty else {
            throw ArticleWriteError.notConfigured
        }
        let properties: [String: Any] = [
            "Name": ["title": [["type": "text", "text": ["content": placeholderTitle(url)]]]],
            "URL": ["url": url],
            "Saved": ["date": ["start": todayString()]],
            "Status": ["select": ["name": "Processing"]],
            "Progress": ["number": 0.05]
        ]
        let articleId = try await createPage(parent: ["database_id": articlesDbId], properties: properties, children: [], icon: "📄")
        let ids = try await appendChildrenReturningIds(to: articleId, blocks: [
            callout("⏳", "Queued…", color: "yellow_background")
        ])
        return ArticlePlaceholder(articleId: articleId, progressBlockId: ids.first, articleURL: pageURL(for: articleId))
    }

    // Best-effort phase update: fills the Progress bar property and rewrites the callout line.
    func updateProgress(_ placeholder: ArticlePlaceholder, emoji: String, _ text: String, fraction: Double) async {
        try? await updatePage(placeholder.articleId, properties: ["Progress": ["number": fraction]])
        guard let blockId = placeholder.progressBlockId else { return }
        try? await updateBlock(blockId, body: ["callout": [
            "rich_text": richText(text),
            "icon": ["type": "emoji", "emoji": emoji],
            "color": "yellow_background"
        ]])
    }

    // Best-effort: flip the page to Failed and write the error into the progress line.
    func markFailed(_ placeholder: ArticlePlaceholder, message: String) async {
        try? await updatePage(placeholder.articleId, properties: ["Status": ["select": ["name": "Failed"]]])
        guard let blockId = placeholder.progressBlockId else { return }
        try? await updateBlock(blockId, body: ["callout": [
            "rich_text": richText("Failed — " + String(message.prefix(1800))),
            "icon": ["type": "emoji", "emoji": "⚠️"],
            "color": "red_background"
        ]])
    }

    // Phase 2 — fill in the placeholder page, create/expand its concepts, mark it Ready.
    func finalize(_ placeholder: ArticlePlaceholder, analysis: ArticleAnalysis, url: String) async throws -> ArticleWriteResult {
        let articleId = placeholder.articleId
        let articleTopics = analysis.article.topics
        let (resolved, nameToId) = try await resolveConcepts(analysis.concepts, articleTopics: articleTopics)
        let conceptIds = resolved.map { $0.pageId }

        try await updatePage(articleId, properties: articleProperties(meta: analysis.article, url: url, conceptIds: conceptIds))
        try await appendChildren(to: articleId, blocks: articleBodyBlocks(meta: analysis.article, url: url, conceptIds: conceptIds))

        for entry in resolved {
            try await appendContribution(conceptId: entry.pageId, articleId: articleId, text: entry.extraction.contribution)

            if !entry.isNew {
                if let merged = try? await ArticleAIService.shared.resynthesize(
                    concept: entry.extraction.name,
                    existingSummary: entry.oldSummary,
                    newContribution: entry.extraction.contribution
                ), !merged.isEmpty {
                    try await updateSummary(conceptId: entry.pageId, summary: merged)
                }

                // Concepts inherit the topics of every article that references them.
                let unioned = Array(Set(entry.oldTopics).union(articleTopics))
                if Set(unioned) != Set(entry.oldTopics) {
                    try await updateTopics(conceptId: entry.pageId, topics: unioned)
                }
            }

            let relatedIds = entry.extraction.relatedConcepts
                .compactMap { nameToId[$0.lowercased()] }
                .filter { $0 != entry.pageId }
            if !relatedIds.isEmpty {
                try await updateRelated(conceptId: entry.pageId, relatedIds: Array(Set(relatedIds)))
            }
        }

        if let blockId = placeholder.progressBlockId { try? await deleteBlock(blockId) }
        await rebuildKnowledgeMap()
        return ArticleWriteResult(articlePageURL: pageURL(for: articleId), conceptCount: resolved.count)
    }

    // MARK: - Concept resolution

    private struct ResolvedConcept {
        let extraction: ConceptExtraction
        let pageId: String
        let isNew: Bool
        let oldSummary: String
        let oldTopics: [String]
    }

    // Maps each extracted concept to a page id, creating new pages (seeded with the
    // article's topics) and matching existing ones (via the AI's existingMatch) so we
    // expand rather than duplicate.
    private func resolveConcepts(_ concepts: [ConceptExtraction], articleTopics: [String]) async throws -> ([ResolvedConcept], [String: String]) {
        var resolved: [ResolvedConcept] = []
        var nameToId: [String: String] = [:]
        for concept in concepts {
            let lookupName = concept.existingMatch ?? concept.name
            if let found = try await findConcept(named: lookupName) {
                resolved.append(ResolvedConcept(extraction: concept, pageId: found.id, isNew: false, oldSummary: found.summary, oldTopics: found.topics))
                nameToId[concept.name.lowercased()] = found.id
                nameToId[lookupName.lowercased()] = found.id
            } else {
                let id = try await createConcept(name: concept.name, summary: concept.contribution, topics: articleTopics)
                resolved.append(ResolvedConcept(extraction: concept, pageId: id, isNew: true, oldSummary: "", oldTopics: articleTopics))
                nameToId[concept.name.lowercased()] = id
            }
        }
        return (resolved, nameToId)
    }

    // MARK: - Knowledge Map

    private var knowledgeMapPageId: String { UserDefaults.shared.string(forKey: "hivemind.knowledgeMapPageId") ?? "" }

    // Regenerates the Knowledge Map page: every concept grouped under its topics, as
    // headings with clickable concept links. Best-effort — never fails an ingest.
    private func rebuildKnowledgeMap() async {
        let mapId = knowledgeMapPageId
        guard !mapId.isEmpty, !conceptsDbId.isEmpty else { return }
        guard let pages = try? await queryDatabase(databaseId: conceptsDbId, body: [
            "page_size": 100,
            "sorts": [["property": "Name", "direction": "ascending"]]
        ]) else { return }

        var byTopic: [String: [(name: String, id: String)]] = [:]
        for page in pages {
            guard let id = page["id"] as? String, let name = title(of: page) else { continue }
            let props = page["properties"] as? [String: Any]
            let topics = multiSelectValues(props?["Topics"])
            for topic in (topics.isEmpty ? ["Uncategorised"] : topics) {
                byTopic[topic, default: []].append((name, id))
            }
        }

        if let existing = try? await fetchAllChildIds(mapId) {
            for blockId in existing { try? await deleteBlock(blockId) }
        }

        var blocks: [[String: Any]] = []
        for topic in byTopic.keys.sorted() {
            blocks.append(heading2(topic))
            for concept in byTopic[topic]!.sorted(by: { $0.name < $1.name }) {
                blocks.append(mentionBullet(concept.id))
            }
        }
        guard !blocks.isEmpty else { return }

        // Notion caps children at 100 per append call.
        var start = 0
        while start < blocks.count {
            let chunk = Array(blocks[start..<min(start + 100, blocks.count)])
            try? await appendChildren(to: mapId, blocks: chunk)
            start += 100
        }
    }

    private func fetchAllChildIds(_ blockId: String) async throws -> [String] {
        var ids: [String] = []
        var cursor: String?
        repeat {
            var path = "/blocks/\(blockId)/children?page_size=100"
            if let cursor { path += "&start_cursor=\(cursor)" }
            let request = makeRequest(path: path, method: "GET")
            let data = try await perform(request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = json?["results"] as? [[String: Any]] ?? []
            ids.append(contentsOf: results.compactMap { $0["id"] as? String })
            let hasMore = json?["has_more"] as? Bool ?? false
            cursor = hasMore ? (json?["next_cursor"] as? String) : nil
        } while cursor != nil
        return ids
    }

    // MARK: - Concept pages

    private func findConcept(named name: String) async throws -> (id: String, summary: String, topics: [String])? {
        let results = try await queryDatabase(databaseId: conceptsDbId, body: [
            "filter": ["property": "Name", "title": ["equals": name]],
            "page_size": 1
        ])
        guard let page = results.first, let id = page["id"] as? String else { return nil }
        let props = page["properties"] as? [String: Any]
        let summary = plainText((props?["Summary"] as? [String: Any])?["rich_text"])
        return (id, summary, multiSelectValues(props?["Topics"]))
    }

    private func createConcept(name: String, summary: String, topics: [String]) async throws -> String {
        let properties: [String: Any] = [
            "Name": ["title": [["type": "text", "text": ["content": name]]]],
            "Summary": ["rich_text": richText(summary)],
            "Topics": ["multi_select": topics.map { ["name": $0] }]
        ]
        let children: [[String: Any]] = [heading2("From your sources")]
        return try await createPage(parent: ["database_id": conceptsDbId], properties: properties, children: children, icon: "🧩")
    }

    private func updateTopics(conceptId: String, topics: [String]) async throws {
        try await updatePage(conceptId, properties: ["Topics": ["multi_select": topics.map { ["name": $0] }]])
    }

    private func appendContribution(conceptId: String, articleId: String, text: String) async throws {
        let block: [String: Any] = [
            "object": "block", "type": "bulleted_list_item",
            "bulleted_list_item": ["rich_text": [
                pageMention(articleId),
                ["type": "text", "text": ["content": " — \(text)"]]
            ]]
        ]
        try await appendChildren(to: conceptId, blocks: [block])
    }

    private func updateSummary(conceptId: String, summary: String) async throws {
        try await updatePage(conceptId, properties: ["Summary": ["rich_text": richText(summary)]])
    }

    private func updateRelated(conceptId: String, relatedIds: [String]) async throws {
        try await updatePage(conceptId, properties: ["Related": ["relation": relatedIds.map { ["id": $0] }]])
    }

    // MARK: - Article page

    private func articleProperties(meta: ArticleMeta, url: String, conceptIds: [String]) -> [String: Any] {
        var properties: [String: Any] = [
            "Name": ["title": [["type": "text", "text": ["content": meta.title]]]],
            "URL": ["url": url],
            "Source": ["rich_text": richText(meta.source)],
            "Read Time": ["number": meta.readingMinutes],
            "Topics": ["multi_select": meta.topics.map { ["name": $0] }],
            "Status": ["select": ["name": "Ready"]],
            "Progress": ["number": 1.0],
            "Concepts": ["relation": conceptIds.map { ["id": $0] }]
        ]
        if let author = meta.author, !author.isEmpty {
            properties["Author"] = ["rich_text": richText(author)]
        }
        if let published = meta.publishedDate, !published.isEmpty {
            properties["Published"] = ["date": ["start": published]]
        }
        return properties
    }

    private func articleBodyBlocks(meta: ArticleMeta, url: String, conceptIds: [String]) -> [[String: Any]] {
        var children: [[String: Any]] = [callout("💡", meta.tldr)]
        if !meta.keyTakeaways.isEmpty {
            children.append(heading2("Key takeaways"))
            children.append(contentsOf: meta.keyTakeaways.map { bulleted($0) })
        }
        if !conceptIds.isEmpty {
            children.append(divider())
            children.append(heading2("Concepts"))
            children.append(contentsOf: conceptIds.map { mentionParagraph($0) })
        }
        children.append(divider())
        children.append(linkParagraph(label: "Read original ↗", url: url))
        return children
    }

    // MARK: - Notion primitives

    private func createPage(parent: [String: Any], properties: [String: Any], children: [[String: Any]], icon: String?) async throws -> String {
        var body: [String: Any] = ["parent": parent, "properties": properties]
        if !children.isEmpty { body["children"] = children }
        if let icon { body["icon"] = ["type": "emoji", "emoji": icon] }

        var request = makeRequest(path: "/pages", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(request)
        guard let id = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else {
            throw ArticleWriteError.noPageId
        }
        return id
    }

    private func updatePage(_ pageId: String, properties: [String: Any]) async throws {
        var request = makeRequest(path: "/pages/\(pageId)", method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["properties": properties])
        _ = try await perform(request)
    }

    private func appendChildren(to blockId: String, blocks: [[String: Any]]) async throws {
        var request = makeRequest(path: "/blocks/\(blockId)/children", method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["children": blocks])
        _ = try await perform(request)
    }

    private func appendChildrenReturningIds(to blockId: String, blocks: [[String: Any]]) async throws -> [String] {
        var request = makeRequest(path: "/blocks/\(blockId)/children", method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["children": blocks])
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["results"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }

    private func updateBlock(_ blockId: String, body: [String: Any]) async throws {
        var request = makeRequest(path: "/blocks/\(blockId)", method: "PATCH")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await perform(request)
    }

    private func deleteBlock(_ blockId: String) async throws {
        let request = makeRequest(path: "/blocks/\(blockId)", method: "DELETE")
        _ = try await perform(request)
    }

    private func queryDatabase(databaseId: String, body: [String: Any]) async throws -> [[String: Any]] {
        var request = makeRequest(path: "/databases/\(databaseId)/query", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["results"] as? [[String: Any]] ?? []
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ArticleWriteError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "Unknown error")
        }
        return data
    }

    // MARK: - Block + value builders

    private func richText(_ text: String) -> [[String: Any]] {
        text.isEmpty ? [] : [["type": "text", "text": ["content": String(text.prefix(2000))]]]
    }

    private func pageMention(_ pageId: String) -> [String: Any] {
        ["type": "mention", "mention": ["type": "page", "page": ["id": pageId]]]
    }

    private func heading2(_ text: String) -> [String: Any] {
        ["object": "block", "type": "heading_2", "heading_2": ["rich_text": richText(text)]]
    }

    private func bulleted(_ text: String) -> [String: Any] {
        ["object": "block", "type": "bulleted_list_item", "bulleted_list_item": ["rich_text": richText(text)]]
    }

    private func callout(_ emoji: String, _ text: String, color: String = "gray_background") -> [String: Any] {
        ["object": "block", "type": "callout", "callout": [
            "rich_text": richText(text),
            "icon": ["type": "emoji", "emoji": emoji],
            "color": color
        ]]
    }

    private func divider() -> [String: Any] {
        ["object": "block", "type": "divider", "divider": [:]]
    }

    private func mentionParagraph(_ pageId: String) -> [String: Any] {
        ["object": "block", "type": "paragraph", "paragraph": ["rich_text": [pageMention(pageId)]]]
    }

    private func mentionBullet(_ pageId: String) -> [String: Any] {
        ["object": "block", "type": "bulleted_list_item", "bulleted_list_item": ["rich_text": [pageMention(pageId)]]]
    }

    private func linkParagraph(label: String, url: String) -> [String: Any] {
        ["object": "block", "type": "paragraph", "paragraph": ["rich_text": [
            ["type": "text", "text": ["content": label, "link": ["url": url]]]
        ]]]
    }

    // MARK: - Parsing helpers

    private func title(of page: [String: Any]) -> String? {
        let props = page["properties"] as? [String: Any]
        let name = (props?["Name"] as? [String: Any])?["title"]
        let text = plainText(name)
        return text.isEmpty ? nil : text
    }

    private func plainText(_ richText: Any?) -> String {
        guard let items = richText as? [[String: Any]] else { return "" }
        return items.compactMap { $0["plain_text"] as? String }.joined()
    }

    private func multiSelectValues(_ property: Any?) -> [String] {
        guard let dict = property as? [String: Any],
              let options = dict["multi_select"] as? [[String: Any]] else { return [] }
        return options.compactMap { $0["name"] as? String }
    }

    private func pageURL(for pageId: String) -> String {
        "https://www.notion.so/" + pageId.replacingOccurrences(of: "-", with: "")
    }

    private func placeholderTitle(_ url: String) -> String {
        "Fetching… (" + (URL(string: url)?.host ?? url) + ")"
    }

    private func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
