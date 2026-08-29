import Foundation

// Decoded from the AI extraction call. Mirrors `ArticleAIService.analysisSchema`.
struct ArticleAnalysis: Decodable {
    let article: ArticleMeta
    let concepts: [ConceptExtraction]
}

struct ArticleMeta: Decodable {
    let title: String
    let source: String
    let author: String?
    let publishedDate: String?
    let readingMinutes: Int
    let tldr: String
    let keyTakeaways: [String]
    let topics: [String]
}

struct ConceptExtraction: Decodable {
    let name: String
    // The exact name of an existing concept page this maps to, or nil if it's new.
    let existingMatch: String?
    // What THIS article says about the concept (1–3 sentences).
    let contribution: String
    // Durable, self-contained facts about the concept — the skimmable layer of the page.
    let keyPoints: [String]
    // Single best-fit topic for the concept's wiki directory (e.g. "Software Architecture").
    let topic: String
    let relatedConcepts: [String]
}

// Result of merging a new contribution into an existing concept's summary, plus a
// classification of whether the new information conflicts with what's already there.
struct ConceptMerge: Decodable {
    let summary: String
    // The consolidated key-point list — existing points plus the new source's, deduped
    // semantically by the model rather than by string equality.
    let keyPoints: [String]
    let conflict: String        // none | soft | scope | hard
    let conflictNote: String?
}

// A web-discovered related article worth queueing on the Reading List.
struct RelatedSuggestion: Decodable {
    let title: String
    let url: String
    let why: String             // one short line on why it's worth reading
}

extension ArticleAnalysis {
    /// Repairs blank names before they can reach the filesystem.
    ///
    /// The model occasionally returns an empty title or an unnamed concept — a PDF with no
    /// obvious heading is enough to trigger it. Those blanks used to flow straight into
    /// filename construction and produced an article called `2026-08-29-.md` alongside a
    /// concept page named, literally, `.md`. Fixing it here means every downstream user
    /// (filenames, frontmatter, the log, notifications) sees the same repaired value.
    func normalized(url: String, markdown: String) -> ArticleAnalysis {
        let trimmedTitle = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSource = article.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URL(string: url)?.host ?? "Unknown source"

        let repaired = ArticleMeta(
            title: trimmedTitle.isEmpty ? Self.inferredTitle(markdown: markdown, host: host) : trimmedTitle,
            source: trimmedSource.isEmpty ? host : trimmedSource,
            author: article.author,
            publishedDate: article.publishedDate,
            readingMinutes: article.readingMinutes,
            tldr: article.tldr,
            keyTakeaways: article.keyTakeaways,
            topics: article.topics
        )

        // An unnamed concept has nowhere to live — drop it rather than write an empty page.
        let named = concepts.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return ArticleAnalysis(article: repaired, concepts: named)
    }

    // A document's first real line is nearly always its title, which beats any URL-derived
    // guess — a Drive download link is just "uc?export=download&id=…".
    private static func inferredTitle(markdown: String, host: String) -> String {
        let candidate = markdown
            .components(separatedBy: .newlines)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                let bare = line.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
                return bare.count >= 4 && bare.count <= 120 && bare.contains(where: { $0.isLetter })
            }
        guard let candidate else { return "Untitled — \(host)" }
        return candidate.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
    }
}
