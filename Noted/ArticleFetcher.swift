import Foundation

enum ArticleFetchError: Error, LocalizedError {
    case invalidURL
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That doesn't look like a valid URL."
        case .empty: return "Couldn't extract any readable text from that page."
        }
    }
}

struct FetchedArticle {
    let url: String
    let markdown: String
}

// Fetches clean article text. Primary path is Jina Reader (r.jina.ai), which renders
// JS and returns markdown; falls back to a raw fetch + crude HTML strip.
class ArticleFetcher {
    static let shared = ArticleFetcher()
    private init() {}

    func fetch(urlString: String) async throws -> FetchedArticle {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = URL(string: trimmed), target.scheme?.hasPrefix("http") == true else {
            throw ArticleFetchError.invalidURL
        }

        if let markdown = try? await fetchViaJina(trimmed), markdown.count > 200 {
            return FetchedArticle(url: trimmed, markdown: markdown)
        }

        let raw = try await fetchRaw(target)
        let stripped = ArticleFetcher.stripHTML(raw)
        guard !stripped.isEmpty else { throw ArticleFetchError.empty }
        return FetchedArticle(url: trimmed, markdown: stripped)
    }

    // MARK: - Private

    private func fetchViaJina(_ urlString: String) async throws -> String {
        guard let jina = URL(string: "https://r.jina.ai/\(urlString)") else { return "" }
        var request = URLRequest(url: jina)
        request.timeoutInterval = 60
        request.setValue("text/markdown", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return "" }
        return ArticleFetcher.stripJinaPreamble(String(data: data, encoding: .utf8) ?? "")
    }

    // Jina prepends "Title:", "URL Source:", "Published Time:" and a "Markdown Content:"
    // marker before the article body — metadata we already keep in frontmatter. Drop it.
    private static func stripJinaPreamble(_ markdown: String) -> String {
        if let range = markdown.range(of: "Markdown Content:") {
            return String(markdown[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines = markdown.components(separatedBy: "\n")
        let preamblePrefixes = ["Title:", "URL Source:", "Published Time:", "Warning:"]
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty
                || preamblePrefixes.contains(where: { first.hasPrefix($0) }) {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fetchRaw(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Mozilla/5.0 (Macintosh) Noted", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Rough HTML→text fallback. Jina is the primary path; this only runs if it fails.
    private static func stripHTML(_ html: String) -> String {
        var text = html
        for tag in ["script", "style", "head", "nav", "footer", "noscript"] {
            text = text.replacingOccurrences(
                of: "<\(tag)[^>]*>.*?</\(tag)>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&#39;", with: "'")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(\\s*\\n\\s*){2,}", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
