import Foundation
import PDFKit

enum ArticleFetchError: Error, LocalizedError {
    case invalidURL
    case empty
    case notReadable(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "That doesn't look like a valid URL."
        case .empty: return "Couldn't extract any readable text from that page."
        case .notReadable(let host):
            return "\(host) returned a viewer page rather than the document text. "
                + "If it's a file share, try a direct link to the file itself."
        }
    }
}

struct FetchedArticle {
    let url: String
    let markdown: String
}

// Fetches clean article text. Documents (PDFs, Google Drive shares) are read directly with
// PDFKit; everything else goes through Jina Reader (r.jina.ai), which renders JS and returns
// markdown, with a crude HTML strip as the last resort.
class ArticleFetcher {
    static let shared = ArticleFetcher()
    private init() {}

    func fetch(urlString: String) async throws -> FetchedArticle {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let original = URL(string: trimmed), original.scheme?.hasPrefix("http") == true else {
            throw ArticleFetchError.invalidURL
        }

        // A Drive/Dropbox share or a .pdf link is a document, not a web page. Jina would render
        // the *viewer* — menus, zoom controls and page thumbnails — and happily return that as
        // an article, which is exactly how a 51-page PDF once became 52 image links.
        if let document = Self.documentURL(for: original) {
            if let text = try? await fetchPDFText(document), Self.isProse(text) {
                return FetchedArticle(url: trimmed, markdown: Self.stripImages(text))
            }
            throw ArticleFetchError.notReadable(original.host ?? "That host")
        }

        if let markdown = try? await fetchViaJina(trimmed), Self.isProse(markdown) {
            return FetchedArticle(url: trimmed, markdown: Self.stripImages(markdown))
        }

        // Jina failed or gave us chrome. The page may itself be a PDF served without a .pdf path.
        let (data, _) = try await fetchData(original)
        if Self.isPDF(data), let text = Self.pdfText(data), Self.isProse(text) {
            return FetchedArticle(url: trimmed, markdown: Self.stripImages(text))
        }

        let stripped = Self.stripHTML(String(data: data, encoding: .utf8) ?? "")
        guard !stripped.isEmpty else { throw ArticleFetchError.empty }
        guard Self.isProse(stripped) else { throw ArticleFetchError.notReadable(original.host ?? "That host") }
        return FetchedArticle(url: trimmed, markdown: Self.stripImages(stripped))
    }

    // MARK: - Documents

    // Maps a share link to something that returns actual bytes, or nil if this isn't a document.
    static func documentURL(for url: URL) -> URL? {
        let host = url.host ?? ""

        if host.contains("drive.google.com") {
            // .../file/d/<id>/view  and  ...?id=<id>  both become a direct download.
            var id: String?
            let parts = url.pathComponents
            if let d = parts.firstIndex(of: "d"), parts.indices.contains(d + 1) { id = parts[d + 1] }
            if id == nil {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "id" })?.value
            }
            if let id { return URL(string: "https://drive.google.com/uc?export=download&id=\(id)") }
        }

        if url.pathExtension.lowercased() == "pdf" { return url }

        // Dropbox previews need the raw flag to return the file itself.
        if host.contains("dropbox.com") {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            var items = (components?.queryItems ?? []).filter { $0.name != "dl" }
            items.append(URLQueryItem(name: "raw", value: "1"))
            components?.queryItems = items
            return components?.url
        }

        return nil
    }

    private func fetchPDFText(_ url: URL) async throws -> String {
        let (data, _) = try await fetchData(url)
        guard Self.isPDF(data), let text = Self.pdfText(data) else { throw ArticleFetchError.empty }
        return text
    }

    private static func isPDF(_ data: Data) -> Bool { data.prefix(4) == Data("%PDF".utf8) }

    private static func pdfText(_ data: Data) -> String? {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
        // A scanned PDF has pages but no text layer; the caller's prose check catches that.
        return document.string
    }

    // MARK: - Quality gate

    // Real articles have paragraphs. Viewer chrome, cookie walls and nav dumps are short
    // fragments ("Download Ctrl+D", "75%"), so counting substantial lines separates them.
    //
    // Links and images are stripped FIRST, and that ordering is the whole trick: a Google Drive
    // viewer lists one image per page, and those lines look long only because the image URLs are
    // enormous. Counting raw whitespace tokens scores that page as 57 paragraphs; counting real
    // words after stripping scores it 1, against 562 for the actual document.
    static func isProse(_ text: String) -> Bool {
        var cleaned = text
            .replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)

        let proseLines = cleaned.components(separatedBy: .newlines).filter { line in
            line.split(separator: " ")
                .filter { $0.count > 2 && $0.contains(where: { $0.isLetter }) }
                .count >= 8
        }
        return proseLines.count >= 5
    }

    // Remote image links are noise in a text wiki — and a PDF viewer page is *nothing but*
    // page-thumbnail images. The source URL stays in frontmatter for the original.
    static func stripImages(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(\\s*\\n\\s*){3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private func fetchData(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        request.setValue("Mozilla/5.0 (Macintosh) Noted", forHTTPHeaderField: "User-Agent")
        return try await URLSession.shared.data(for: request)
    }

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
