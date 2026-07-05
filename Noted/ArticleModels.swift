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
    // Single best-fit topic for the concept's wiki directory (e.g. "Software Architecture").
    let topic: String
    let relatedConcepts: [String]
}

// Result of merging a new contribution into an existing concept's summary, plus a
// classification of whether the new information conflicts with what's already there.
struct ConceptMerge: Decodable {
    let summary: String
    let conflict: String        // none | soft | scope | hard
    let conflictNote: String?
}
