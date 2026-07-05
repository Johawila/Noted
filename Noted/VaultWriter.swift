import Foundation

enum VaultWriteError: Error, LocalizedError {
    case noVaultPath
    var errorDescription: String? {
        switch self {
        case .noVaultPath: return "No Obsidian vault selected. Choose a vault in Noted settings."
        }
    }
}

struct VaultWriteResult {
    let primaryConceptPath: String?
    let conceptCount: Int
    let conflictCount: Int
}

// Writes an analyzed article into an Obsidian vault as a Karpathy-style wiki:
// raw/ source files + wiki/<topic>/<Concept>.md pages, merging into existing concepts
// and flagging hard contradictions. Pure local file I/O (plus the merge AI call).
class VaultWriter {
    static let shared = VaultWriter()
    private init() {}

    private let fm = FileManager.default

    private var vaultURL: URL? {
        let path = UserDefaults.standard.string(forKey: "vaultPath") ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    // Vault layout: Articles/ (sources), Concepts/ (wiki pages), Meta/ (Index/Log/Conflicts
    // + templates). CLAUDE.md stays at the root so Claude Code auto-loads it.
    private func conceptsDir(_ vault: URL) -> URL { vault.appendingPathComponent("Concepts") }
    private func articlesDir(_ vault: URL) -> URL { vault.appendingPathComponent("Articles") }
    private func metaDir(_ vault: URL) -> URL { vault.appendingPathComponent("Meta") }
    private func indexFile(_ vault: URL) -> URL { metaDir(vault).appendingPathComponent("Index.md") }
    private func logFile(_ vault: URL) -> URL { metaDir(vault).appendingPathComponent("Log.md") }
    // Conflicts lives at the root — it's the actionable review queue, not background metadata.
    private func conflictsFile(_ vault: URL) -> URL { vault.appendingPathComponent("Conflicts.md") }

    // Concept page names already in the wiki — passed to the AI so it reuses them. Each entry
    // carries its known aliases so the model can match alternate spellings to the right page
    // (it still returns existingMatch as the canonical title).
    func existingConceptNames() -> [String] {
        existingConcepts().map { concept in
            concept.aliases.isEmpty
                ? concept.title
                : "\(concept.title) (also: \(concept.aliases.joined(separator: ", ")))"
        }
    }

    // (canonical title, aliases) for every concept page in the wiki.
    private func existingConcepts() -> [(title: String, aliases: [String])] {
        guard let vault = vaultURL,
              let walker = fm.enumerator(at: conceptsDir(vault), includingPropertiesForKeys: nil) else { return [] }
        var result: [(String, [String])] = []
        for case let url as URL in walker where url.pathExtension == "md" {
            let stem = url.deletingPathExtension().lastPathComponent
            if isMeta(stem) { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let page = ConceptPage(markdown: text)
                result.append((page.title.isEmpty ? stem : page.title, page.aliases))
            } else {
                result.append((stem, []))
            }
        }
        return result
    }

    private func isMeta(_ stem: String) -> Bool {
        ["index", "log", "conflicts"].contains(stem.lowercased())
    }

    func write(analysis: ArticleAnalysis, url: String, rawMarkdown: String) async throws -> VaultWriteResult {
        guard let vault = vaultURL else { throw VaultWriteError.noVaultPath }
        try ensureScaffold(vault)

        let articleTopicDir = topicFolder(analysis.article.topics.first ?? "Uncategorised")
        let rawFileName = try writeRaw(vault: vault, topicDir: articleTopicDir, url: url, meta: analysis.article, rawMarkdown: rawMarkdown)
        let rawLink = "../../Articles/\(encodePathComponent(articleTopicDir))/\(encodePathComponent(rawFileName))"
        let sourceLabel = sourceLabel(for: analysis.article)

        // Concepts that exist (or will after this ingest) — See-also links are filtered to these.
        // Titles and aliases both count, so a related-concept link to an alternate spelling resolves.
        let knownNames = Set(existingConcepts().flatMap { [$0.title] + $0.aliases }.map { fileSafe($0) })
            .union(analysis.concepts.map { fileSafe($0.name) })

        var primaryPath: String?
        var conflictCount = 0
        var updatedTitles: [String] = []

        for (index, concept) in analysis.concepts.enumerated() {
            let topicDir = topicFolder(concept.topic.isEmpty ? "Uncategorised" : concept.topic)
            let result = try await upsertConcept(
                vault: vault, concept: concept, topicDir: topicDir,
                meta: analysis.article, sourceLabel: sourceLabel, rawLink: rawLink,
                knownNames: knownNames
            )
            if result.wasConflict { conflictCount += 1 }
            if !result.wasNew { updatedTitles.append(concept.name) }
            if index == 0 { primaryPath = result.path }
        }

        try rebuildIndex(vault)
        try rebuildConflicts(vault)
        try appendLog(vault, primary: analysis.concepts.first?.name ?? analysis.article.title,
                      updated: updatedTitles, conflicts: conflictCount)

        return VaultWriteResult(primaryConceptPath: primaryPath, conceptCount: analysis.concepts.count, conflictCount: conflictCount)
    }

    // MARK: - Concept upsert

    private struct UpsertResult {
        let path: String
        let wasNew: Bool
        let wasConflict: Bool
    }

    private func upsertConcept(vault: URL, concept: ConceptExtraction, topicDir: String,
                               meta: ArticleMeta, sourceLabel: String, rawLink: String,
                               knownNames: Set<String>) async throws -> UpsertResult {
        let canonical = fileSafe(concept.name)  // slash-free name used as title, filename, and in links
        let sourceBullet = "- [\(meta.title)](\(rawLink)) — \(concept.contribution)"
        // Only link related concepts that actually have (or will have) a page — no dead-end links.
        let seeAlsoLinks = concept.relatedConcepts
            .map { fileSafe($0) }
            .filter { $0 != canonical && knownNames.contains($0) }
            .map { "- [[\($0)]]" }

        if let existing = findConceptFile(vault: vault, name: concept.name, existingMatch: concept.existingMatch) {
            var page = ConceptPage(markdown: (try? String(contentsOf: existing, encoding: .utf8)) ?? "")
            var wasConflict = false

            // If this article named the concept differently than the page's title, keep that
            // spelling as an alias so the next ingest matches straight to this page.
            if fileSafe(page.title) != canonical { page.addAlias(concept.name) }

            if let merge = try? await ArticleAIService.shared.mergeConcept(
                concept: concept.name, existingSummary: page.summary, newContribution: concept.contribution
            ) {
                if merge.conflict == "hard" {
                    wasConflict = true
                    page.status = "conflict"
                    page.conflict.append("- **Existing:** \(page.summary)")
                    page.conflict.append("- **New (\(sourceLabel)):** \(concept.contribution)")
                    if let note = merge.conflictNote { page.conflict.append("- _\(note)_") }
                    // Keep the existing summary — don't let a hard conflict overwrite it.
                } else {
                    page.summary = merge.summary
                    if merge.conflict == "soft" || merge.conflict == "scope", let note = merge.conflictNote {
                        page.summary += "\n\n> Tension: \(note)"
                    }
                }
            }

            page.addSourceBullet(sourceBullet)
            page.addSeeAlso(seeAlsoLinks)
            page.mergeTopics([concept.topic])
            page.addSourceLabel(sourceLabel)
            page.updated = today()
            try page.render().write(to: existing, atomically: true, encoding: .utf8)
            return UpsertResult(path: existing.path, wasNew: false, wasConflict: wasConflict)
        }

        let page = ConceptPage.new(
            topic: concept.topic, sourceLabel: sourceLabel, updated: today(),
            published: meta.publishedDate ?? "Unknown", title: canonical,
            summary: concept.contribution, fromSources: [sourceBullet], seeAlso: seeAlsoLinks
        )
        let fileURL = conceptsDir(vault).appendingPathComponent("\(topicDir)/\(canonical).md")
        try ensureDir(fileURL.deletingLastPathComponent())
        try page.render().write(to: fileURL, atomically: true, encoding: .utf8)
        return UpsertResult(path: fileURL.path, wasNew: true, wasConflict: false)
    }

    // Locate an existing concept page by the AI's existingMatch (preferred), the extracted name,
    // or any alias of a page — so alternate spellings merge into one page instead of forking.
    private func findConceptFile(vault: URL, name: String, existingMatch: String?) -> URL? {
        guard let walker = fm.enumerator(at: conceptsDir(vault), includingPropertiesForKeys: nil) else { return nil }
        let targets = Set([existingMatch, name].compactMap { $0 }.map { fileSafe($0) })
        guard !targets.isEmpty else { return nil }
        for case let url as URL in walker where url.pathExtension == "md" {
            let stem = url.deletingPathExtension().lastPathComponent
            if isMeta(stem) { continue }
            if targets.contains(stem) { return url }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let page = ConceptPage(markdown: text)
                let pageNames = Set(([page.title] + page.aliases).map { fileSafe($0) })
                if !pageNames.isDisjoint(with: targets) { return url }
            }
        }
        return nil
    }

    // MARK: - Raw

    private func writeRaw(vault: URL, topicDir: String, url: String, meta: ArticleMeta, rawMarkdown: String) throws -> String {
        let dir = articlesDir(vault).appendingPathComponent(topicDir)
        try ensureDir(dir)
        let datePrefix = (meta.publishedDate?.isEmpty == false ? meta.publishedDate! : today())
        let base = "\(datePrefix)-\(slug(meta.title))"
        var fileName = "\(base).md"
        var n = 2
        while fm.fileExists(atPath: dir.appendingPathComponent(fileName).path) {
            fileName = "\(base)-\(n).md"; n += 1
        }
        let content = """
        ---
        title: \(yaml(meta.title))
        source_url: \(url)
        collected: \(today())
        published: \(meta.publishedDate ?? "Unknown")
        ---

        \(rawMarkdown)
        """
        try content.write(to: dir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        return fileName
    }

    // MARK: - Index / conflicts / log

    private func rebuildIndex(_ vault: URL) throws {
        let pages = allConceptPages(vault)
        var byTopic: [String: [(title: String, blurb: String, updated: String)]] = [:]
        for page in pages {
            for topic in (page.topics.isEmpty ? ["Uncategorised"] : page.topics) {
                byTopic[topic, default: []].append((page.title, page.indexBlurb, page.updated))
            }
        }
        var out = "# Knowledge Base Index\n"
        for topic in byTopic.keys.sorted() {
            out += "\n## \(topic)\n"
            for entry in byTopic[topic]!.sorted(by: { $0.title < $1.title }) {
                out += "- [[\(entry.title)]] — \(entry.blurb) (Updated: \(entry.updated))\n"
            }
        }
        try out.write(to: indexFile(vault), atomically: true, encoding: .utf8)
    }

    private func rebuildConflicts(_ vault: URL) throws {
        let conflicted = allConceptPages(vault).filter { $0.status == "conflict" }
        var out = "# Conflicts to review\n"
        if conflicted.isEmpty {
            out += "\n_None. 🎉_\n"
        } else {
            for page in conflicted.sorted(by: { $0.title < $1.title }) {
                out += "- [[\(page.title)]]\n"
            }
        }
        try out.write(to: conflictsFile(vault), atomically: true, encoding: .utf8)
    }

    private func appendLog(_ vault: URL, primary: String, updated: [String], conflicts: Int) throws {
        let logURL = logFile(vault)
        var content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "# Wiki Log\n"
        content += "\n## [\(today())] ingest | \(primary)\n"
        for title in updated { content += "- Updated: \(title)\n" }
        if conflicts > 0 { content += "- ⚠️ \(conflicts) conflict\(conflicts == 1 ? "" : "s") flagged\n" }
        try content.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func allConceptPages(_ vault: URL) -> [ConceptPage] {
        guard let walker = fm.enumerator(at: conceptsDir(vault), includingPropertiesForKeys: nil) else { return [] }
        var pages: [ConceptPage] = []
        for case let url as URL in walker where url.pathExtension == "md" {
            if isMeta(url.deletingPathExtension().lastPathComponent) { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8) { pages.append(ConceptPage(markdown: text)) }
        }
        return pages
    }

    // MARK: - Helpers

    private func ensureScaffold(_ vault: URL) throws {
        try ensureDir(articlesDir(vault))
        try ensureDir(conceptsDir(vault))
        try ensureDir(metaDir(vault))
        if !fm.fileExists(atPath: indexFile(vault).path) {
            try "# Knowledge Base Index\n".write(to: indexFile(vault), atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: logFile(vault).path) {
            try "# Wiki Log\n".write(to: logFile(vault), atomically: true, encoding: .utf8)
        }
    }

    private func ensureDir(_ url: URL) throws {
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func sourceLabel(for meta: ArticleMeta) -> String {
        var label = meta.source
        if let author = meta.author, !author.isEmpty { label += " — \(author)" }
        if let published = meta.publishedDate, !published.isEmpty { label += ", \(published)" }
        return label
    }

    // Readable folder name for a topic (keeps case/spaces/&); only strips path-illegal chars.
    private func topicFolder(_ topic: String) -> String {
        fileSafe(topic)
    }

    // Filesystem-safe version of a concept/topic name: replaces characters Obsidian/macOS
    // disallow in a single path component (notably "/") so names like "LTV/CAC Ratio" don't
    // become nested folders. Readability (spaces, case, &) is preserved.
    private func fileSafe(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    // Quote a string as a safe single-line YAML scalar (handles colons, slashes, newlines).
    private func yaml(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        return "\"\(cleaned)\""
    }

    // Percent-encode the parts of a relative markdown link that would otherwise break it.
    private func encodePathComponent(_ s: String) -> String {
        s.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "&", with: "%26")
    }

    private func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        let allowed = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        var slug = String(allowed)
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(slug.prefix(60))
    }

    private func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
