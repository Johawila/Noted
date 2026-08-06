import Foundation

// A parsed concept page: YAML frontmatter (machine fields) + prose body sections.
// Tailored to the shapes the pipeline writes; unknown body sections are not preserved
// across a merge (pipeline-maintained pages only).
struct ConceptPage {
    var topics: [String] = []
    var aliases: [String] = []        // alternate names/spellings — Obsidian resolves [[alias]] here
    var sources: String = ""          // "; "-separated
    var updated: String = ""
    var published: String = ""
    var status: String = "ok"         // ok | conflict

    var title: String = ""
    var summary: String = ""
    var keyPoints: [String] = []      // raw "- ..." lines
    var fromSources: [String] = []
    var seeAlso: [String] = []
    var conflict: [String] = []

    init() {}

    init(markdown: String) {
        var lines = markdown.components(separatedBy: "\n")

        // Frontmatter
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var i = 1
            while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != "---" {
                let line = lines[i]
                if let colon = line.firstIndex(of: ":") {
                    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "topics": topics = ConceptPage.parseInlineList(value)
                    case "aliases": aliases = ConceptPage.parseInlineList(value)
                    case "sources": sources = value
                    case "updated": updated = value
                    case "published": published = value
                    case "status": status = value
                    default: break
                    }
                }
                i += 1
            }
            lines = Array(lines[min(i + 1, lines.count)...])
        }

        // Body
        var section = "summary"
        var summaryLines: [String] = []
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if section == "summary", title.isEmpty, trimmed.hasPrefix("# ") {
                title = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.hasPrefix("## ") {
                let heading = String(trimmed.dropFirst(3)).lowercased()
                if heading.contains("key point") { section = "key" }
                else if heading.contains("from the sources") { section = "from" }
                else if heading.contains("see also") { section = "see" }
                else if heading.contains("conflict") { section = "conflict" }
                else { section = "other" }
                continue
            }
            switch section {
            case "summary": summaryLines.append(raw)
            case "key": if !trimmed.isEmpty { keyPoints.append(raw) }
            case "from": if !trimmed.isEmpty { fromSources.append(raw) }
            case "see": if !trimmed.isEmpty { seeAlso.append(raw) }
            case "conflict": if !trimmed.isEmpty { conflict.append(raw) }
            default: break
            }
        }
        summary = ConceptPage.trimmedBlock(summaryLines)
    }

    static func new(topic: String, sourceLabel: String, updated: String, published: String,
                    title: String, summary: String, keyPoints: [String],
                    fromSources: [String], seeAlso: [String]) -> ConceptPage {
        var page = ConceptPage()
        page.topics = [topic]
        page.sources = sourceLabel
        page.updated = updated
        page.published = published
        page.status = "ok"
        page.title = title
        page.summary = summary
        page.setKeyPoints(keyPoints)
        page.fromSources = fromSources
        page.seeAlso = seeAlso
        return page
    }

    // MARK: - Mutation

    mutating func addSourceBullet(_ bullet: String) {
        if !fromSources.contains(bullet) { fromSources.append(bullet) }
    }

    mutating func addSeeAlso(_ links: [String]) {
        for link in links where !seeAlso.contains(link) { seeAlso.append(link) }
    }

    mutating func mergeTopics(_ newTopics: [String]) {
        for topic in newTopics where !topic.isEmpty && !topics.contains(topic) { topics.append(topic) }
    }

    // keyPoints is stored as raw markdown bullet lines (that's how it's parsed back),
    // so plain sentences from the model get their "- " here rather than at every call site.
    mutating func setKeyPoints(_ points: [String]) {
        keyPoints = points
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? $0 : "- \($0)" }
    }

    // The plain sentences, for handing back to the merge model.
    var keyPointTexts: [String] {
        keyPoints.map {
            $0.trimmingCharacters(in: .whitespaces)
              .replacingOccurrences(of: #"^[-*]\s+"#, with: "", options: .regularExpression)
        }
    }

    mutating func addAlias(_ alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != title, !aliases.contains(trimmed) else { return }
        aliases.append(trimmed)
    }

    mutating func addSourceLabel(_ label: String) {
        if sources.isEmpty { sources = label }
        else if !sources.contains(label) { sources += "; \(label)" }
    }

    // MARK: - Render

    func render() -> String {
        var out = "---\n"
        out += "topics: [\(topics.joined(separator: ", "))]\n"
        if !aliases.isEmpty {
            out += "aliases: [\(aliases.map { "\"\($0)\"" }.joined(separator: ", "))]\n"
        }
        out += "sources: \"\(sources.replacingOccurrences(of: "\"", with: "'"))\"\n"
        out += "updated: \(updated)\n"
        out += "published: \(published)\n"
        out += "status: \(status)\n"
        out += "---\n\n"
        out += "# \(title)\n\n"
        out += summary + "\n"
        if !keyPoints.isEmpty { out += "\n## Key points\n" + keyPoints.joined(separator: "\n") + "\n" }
        if !fromSources.isEmpty { out += "\n## From the sources\n" + fromSources.joined(separator: "\n") + "\n" }
        if !seeAlso.isEmpty { out += "\n## See also\n" + seeAlso.joined(separator: "\n") + "\n" }
        if !conflict.isEmpty { out += "\n## ⚠️ Conflict\n" + conflict.joined(separator: "\n") + "\n" }
        return out
    }

    // First sentence of the summary, for the index (capped).
    var indexBlurb: String {
        let flat = summary.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if let dot = flat.range(of: ". ") { return String(flat[..<dot.lowerBound]) + "." }
        return flat.count > 140 ? String(flat.prefix(140)) + "…" : flat
    }

    // MARK: - Private

    private static func parseInlineList(_ value: String) -> [String] {
        var v = value
        if v.hasPrefix("[") { v.removeFirst() }
        if v.hasSuffix("]") { v.removeLast() }
        return v.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    private static func trimmedBlock(_ lines: [String]) -> String {
        var result = lines
        while let first = result.first, first.trimmingCharacters(in: .whitespaces).isEmpty { result.removeFirst() }
        while let last = result.last, last.trimmingCharacters(in: .whitespaces).isEmpty { result.removeLast() }
        return result.joined(separator: "\n")
    }
}
