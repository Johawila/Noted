import Foundation

/// Reading time for an article: the figure the source publishes if it has one (Medium and
/// friends put it in the byline), otherwise an estimate from word count.
///
/// Deliberately computed locally rather than trusting `ArticleMeta.readingMinutes` from the
/// model — the model guesses, whereas a stated figure is a fact and a word count is arithmetic.
enum ReadingTime {
    /// The frontmatter value, e.g. "17 min read".
    static func describe(markdown: String, fallbackMinutes: Int? = nil) -> String {
        "\(minutes(markdown: markdown, fallbackMinutes: fallbackMinutes)) min read"
    }

    static func minutes(markdown: String, fallbackMinutes: Int? = nil) -> Int {
        if let stated = stated(in: markdown) { return stated }
        let words = wordCount(markdown)
        // Only reachable if extraction produced no body at all; the model's guess beats "1 min".
        if words == 0, let fallback = fallbackMinutes, fallback > 0 { return fallback }
        return max(1, Int((Double(words) / wordsPerMinute).rounded()))
    }

    // MARK: - Private

    // Mid-range for technical prose: most calculators use 200–250, Medium ~265.
    private static let wordsPerMinute = 225.0

    // Publishers put the figure in the byline, inside the first paragraph or so. Scanning the
    // whole body would match prose like "worth a 5 minute read" and prefer it over the truth.
    private static let statedSearchLimit = 1200

    private static func stated(in markdown: String) -> Int? {
        let head = String(markdown.prefix(statedSearchLimit))
        let patterns = [
            #"(\d{1,3})\s*[-–]?\s*min(?:ute)?s?\s+read"#,
            #"read(?:ing)?\s*time\s*[:–-]\s*(\d{1,3})"#,
        ]
        for pattern in patterns {
            guard let match = head.range(
                of: pattern, options: [.regularExpression, .caseInsensitive]
            ) else { continue }
            let digits = head[match].filter(\.isNumber)
            // Guards against a stray year or a typo'd "600 min read".
            if let value = Int(digits), (1...240).contains(value) { return value }
        }
        return nil
    }

    private static func wordCount(_ markdown: String) -> Int {
        var text = markdown
        // Images contribute alt text and a URL but nothing to read.
        text = text.replacingOccurrences(
            of: #"!\[[^\]]*\]\([^)]*\)"#, with: " ", options: .regularExpression
        )
        // Links keep their label, drop their target.
        text = text.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"https?://\S+"#, with: " ", options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"[#>*_`|~]"#, with: " ", options: .regularExpression
        )
        return text
            .split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }
}
