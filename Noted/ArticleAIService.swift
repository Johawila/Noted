import Foundation

enum ArticleAIError: Error, LocalizedError {
    case noApiKey
    case apiError(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noApiKey: return "No Anthropic API key. Set it in Noted settings (or run Hivemind setup)."
        case .apiError(let status, let message): return "Claude API error (\(status)): \(message)"
        case .badResponse: return "Claude returned an unexpected response."
        }
    }
}

// Talks to the Anthropic Messages API (raw HTTP — no Swift SDK exists).
// Extraction uses Opus for quality; per-concept re-synthesis uses Haiku for cost/speed.
class ArticleAIService {
    static let shared = ArticleAIService()
    private init() {}

    private let endpoint = "https://api.anthropic.com/v1/messages"
    private let extractionModel = "claude-opus-4-8"
    private let synthesisModel = "claude-haiku-4-5"
    private let maxArticleChars = 120_000

    private var apiKey: String { UserDefaults.shared.string(forKey: "hivemind.anthropicApiKey") ?? "" }

    // Phase 1 — extract article metadata + the concepts it covers, resolving each
    // against the existing concept pages so we expand rather than duplicate.
    func analyze(markdown: String, url: String, existingConcepts: [String]) async throws -> ArticleAnalysis {
        guard !apiKey.isEmpty else { throw ArticleAIError.noApiKey }

        let trimmed = String(markdown.prefix(maxArticleChars))
        let existingList = existingConcepts.isEmpty
            ? "(none yet — this is a fresh knowledge base)"
            : existingConcepts.map { "- \($0)" }.joined(separator: "\n")

        let userMessage = """
        Source URL: \(url)

        Existing concept pages (reuse the exact name and set existingMatch when the article \
        covers the same idea; otherwise set existingMatch to null):
        \(existingList)

        Article content:
        \(trimmed)
        """

        let body: [String: Any] = [
            "model": extractionModel,
            "max_tokens": 8000,
            "system": Self.extractionSystemPrompt,
            "output_config": ["format": ["type": "json_schema", "schema": Self.analysisSchema]],
            "messages": [["role": "user", "content": userMessage]]
        ]

        let data = try await post(body)
        let text = try Self.firstText(in: data)
        guard let parsed = try? JSONDecoder().decode(ArticleAnalysis.self, from: Data(text.utf8)) else {
            throw ArticleAIError.badResponse
        }
        return parsed
    }

    // Phase 2 — fold a new article's contribution into a concept's running summary.
    func resynthesize(concept: String, existingSummary: String, newContribution: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ArticleAIError.noApiKey }

        let userMessage = """
        Concept: \(concept)

        Current summary:
        \(existingSummary)

        New information from another article:
        \(newContribution)
        """

        let body: [String: Any] = [
            "model": synthesisModel,
            "max_tokens": 600,
            "system": Self.synthesisSystemPrompt,
            "messages": [["role": "user", "content": userMessage]]
        ]

        let data = try await post(body)
        return try Self.firstText(in: data).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Phase 2b — merge a new contribution into an existing concept's summary AND classify
    // whether it conflicts with the current understanding (none/soft/scope/hard).
    func mergeConcept(concept: String, existingSummary: String, newContribution: String) async throws -> ConceptMerge {
        guard !apiKey.isEmpty else { throw ArticleAIError.noApiKey }

        let userMessage = """
        Concept: \(concept)

        Current summary:
        \(existingSummary)

        New information from another source:
        \(newContribution)
        """

        let body: [String: Any] = [
            "model": synthesisModel,
            "max_tokens": 800,
            "system": Self.mergeSystemPrompt,
            "output_config": ["format": ["type": "json_schema", "schema": Self.mergeSchema]],
            "messages": [["role": "user", "content": userMessage]]
        ]

        let data = try await post(body)
        let text = try Self.firstText(in: data)
        guard let parsed = try? JSONDecoder().decode(ConceptMerge.self, from: Data(text.utf8)) else {
            throw ArticleAIError.badResponse
        }
        return parsed
    }

    // MARK: - Private

    private func post(_ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        // Non-streaming: the connection sits idle while the model generates, so this is
        // effectively the max generation time. Generous on purpose (low-volume tool).
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ArticleAIError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "Unknown error")
        }
        return data
    }

    private static func firstText(in data: Data) throws -> String {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]] else { throw ArticleAIError.badResponse }
        for block in content where block["type"] as? String == "text" {
            if let text = block["text"] as? String { return text }
        }
        throw ArticleAIError.badResponse
    }

    private static let extractionSystemPrompt = """
    You are a knowledge-base builder. You receive a single article and the names of concept \
    pages that already exist in the user's second brain. Extract:

    1. Article-level metadata: a clean title, the publication/source name, author (or null), \
    published date as ISO yyyy-MM-dd (or null), an integer reading-time estimate in minutes, \
    a 2–4 sentence TL;DR, 3–7 key takeaways, and a few short topic tags.

    2. The distinct concepts the article meaningfully covers. A concept is a reusable idea, \
    pattern, or technique — not a passing mention. For each concept:
       - name: a clean canonical name.
       - existingMatch: if the article discusses the same idea as one of the existing concept \
    pages, set this to that page's EXACT canonical name (the part before any "(also: …)"); \
    otherwise null. Match on meaning, not spelling, and treat the names listed after "(also: …)" \
    as alternate spellings of that same page (e.g. "Event-sourcing" matches an existing \
    "Event Sourcing").
       - contribution: 1–3 sentences capturing specifically what THIS article says about the \
    concept — its angle, claims, or examples. Not a generic definition.
       - topic: the single best-fit subject area for the concept, used as its wiki folder \
    (e.g. "Software Architecture", "Engineering Leadership", "AI & LLMs"). Reuse a consistent \
    set of broad topics rather than inventing a new one per concept.
       - relatedConcepts: names of other concepts (from this article or the existing list) that \
    are conceptually connected.

    Prefer a handful of substantial concepts over many shallow ones.
    """

    private static let synthesisSystemPrompt = """
    You maintain the running summary of a single concept in a personal knowledge base. \
    You receive the current summary and a new contribution drawn from another article. \
    Rewrite the summary so it incorporates the new information: keep what still holds, fold in \
    genuinely new angles, and stay tight (2–4 sentences). Write a clean definition-style summary \
    of the concept itself — do not mention "the article" or attribution. Respond with ONLY the \
    updated summary text, no preamble.
    """

    private static let mergeSystemPrompt = """
    You maintain one concept's summary in a personal knowledge base. You receive the current \
    summary and a new contribution from another source. Do two things:

    1. summary: rewrite the concept's summary (2–4 sentences) to incorporate genuinely new angles \
    while keeping what still holds. Clean definition-style prose; don't mention "the article".
    2. conflict: classify how the new information relates to the current summary:
       - "none": no tension; it just adds or refines.
       - "soft": minor tension or differing emphasis, reconcilable.
       - "scope": both true but in different contexts/conditions.
       - "hard": a direct factual contradiction — they cannot both be true as stated.
    3. conflictNote: if conflict is not "none", one sentence naming the disagreement; otherwise null.

    For a hard conflict, still return your best merged summary, but the caller will preserve both \
    claims rather than overwrite. Respond with ONLY the JSON.
    """

    private static let mergeSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "summary": ["type": "string"],
            "conflict": ["type": "string", "enum": ["none", "soft", "scope", "hard"]],
            "conflictNote": ["type": ["string", "null"]]
        ],
        "required": ["summary", "conflict", "conflictNote"]
    ]

    // Structured-output schema for the extraction call. All fields are required and
    // additionalProperties is false, as the structured-outputs API requires.
    private static let analysisSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "properties": [
            "article": [
                "type": "object",
                "additionalProperties": false,
                "properties": [
                    "title": ["type": "string"],
                    "source": ["type": "string"],
                    "author": ["type": ["string", "null"]],
                    "publishedDate": ["type": ["string", "null"]],
                    "readingMinutes": ["type": "integer"],
                    "tldr": ["type": "string"],
                    "keyTakeaways": ["type": "array", "items": ["type": "string"]],
                    "topics": ["type": "array", "items": ["type": "string"]]
                ],
                "required": ["title", "source", "author", "publishedDate", "readingMinutes", "tldr", "keyTakeaways", "topics"]
            ],
            "concepts": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "name": ["type": "string"],
                        "existingMatch": ["type": ["string", "null"]],
                        "contribution": ["type": "string"],
                        "topic": ["type": "string"],
                        "relatedConcepts": ["type": "array", "items": ["type": "string"]]
                    ],
                    "required": ["name", "existingMatch", "contribution", "topic", "relatedConcepts"]
                ]
            ]
        ],
        "required": ["article", "concepts"]
    ]
}
