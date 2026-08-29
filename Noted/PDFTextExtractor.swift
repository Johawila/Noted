import PDFKit
import AppKit
import Foundation

/// Turns a PDF into readable markdown.
///
/// `PDFDocument.string` returns one line per *visual* line with essentially no blank lines, so
/// pasting it into a note renders as an unbroken wall of text — 1046 lines with a single
/// paragraph break, in the case that prompted this. Three things have to be rebuilt:
/// paragraphs (from sentence endings and hyphenation), headings (from font size, which plain
/// text throws away), and the removal of running headers and page numbers.
enum PDFTextExtractor {
    static func markdown(from document: PDFDocument) -> String {
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        guard !pages.isEmpty else { return "" }

        let pageLines = pages.map { lines(in: $0) }
        let noise = runningHeaders(in: pageLines, pageCount: pages.count)
        let body = bodyFontSize(in: pageLines)

        let kept = pageLines
            .flatMap { $0 }
            .filter { !noise.contains($0.text) && !isPageFurniture($0.text) }

        return assemble(kept, bodySize: body)
    }

    // MARK: - Line extraction

    private struct Line {
        let text: String
        let size: CGFloat
    }

    // Walks the page's attributed string so each line carries the largest font size used in it —
    // that size is what distinguishes a heading from a sentence once the layout is gone.
    private static func lines(in page: PDFPage) -> [Line] {
        guard let attributed = page.attributedString else {
            return (page.string ?? "").components(separatedBy: .newlines)
                .map { Line(text: $0.trimmingCharacters(in: .whitespaces), size: 0) }
        }

        var result: [Line] = []
        var current = ""
        var maxSize: CGFloat = 0

        func endLine() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append(Line(text: trimmed, size: maxSize)) }
            current = ""
            maxSize = 0
        }

        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let size = (value as? NSFont)?.pointSize ?? 0
            let text = (attributed.string as NSString).substring(with: range)
            let pieces = text.components(separatedBy: "\n")
            for (index, piece) in pieces.enumerated() {
                if index > 0 { endLine() }
                current += piece
                if piece.contains(where: { $0.isLetter }) { maxSize = max(maxSize, size) }
            }
        }
        endLine()
        return result
    }

    // MARK: - Noise

    // A running header or footer is the same text near the top or bottom of many pages.
    private static func runningHeaders(in pageLines: [[Line]], pageCount: Int) -> Set<String> {
        var counts: [String: Int] = [:]
        for lines in pageLines {
            let edges = lines.prefix(2).map(\.text) + lines.suffix(2).map(\.text)
            for text in Set(edges) { counts[text, default: 0] += 1 }
        }
        let threshold = max(3, pageCount / 4)
        return Set(counts.filter { $0.value >= threshold }.keys)
    }

    // Bare page numbers, and the "May 2026  43" style footer that carries a date alongside one.
    private static func isPageFurniture(_ text: String) -> Bool {
        let patterns = [
            "^(page\\s*)?\\d{1,4}$",
            "^[A-Z][a-z]+ \\d{4}\\s+\\d{1,4}$",
        ]
        return patterns.contains { text.range(of: $0, options: [.regularExpression]) != nil }
    }

    // The most-used size, weighted by how much text is set in it, is the body.
    private static func bodyFontSize(in pageLines: [[Line]]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for line in pageLines.flatMap({ $0 }) where line.size > 0 {
            weights[line.size.rounded(), default: 0] += line.text.count
        }
        return weights.max(by: { $0.value < $1.value })?.key ?? 0
    }

    // MARK: - Assembly

    private static func assemble(_ lines: [Line], bodySize: CGFloat) -> String {
        var blocks: [String] = []
        var paragraph = ""
        var heading: (level: Int, text: String)?

        func flushParagraph() {
            let trimmed = paragraph.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { blocks.append(trimmed) }
            paragraph = ""
        }

        func flushHeading() {
            guard let pending = heading else { return }
            heading = nil
            let text = pending.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }

            // Not everything set large is a heading — pull quotes are display text and read as
            // sentences. Length plus terminal punctuation tells them apart.
            let endsSentence = text.range(of: "[.!?]$", options: .regularExpression) != nil
            if text.count > 120 || (text.count > 60 && endsSentence) {
                blocks.append("> " + text)
                return
            }
            let line = String(repeating: "#", count: pending.level) + " " + text
            // A heading repeated on consecutive pages (a section banner) collapses to one.
            if blocks.last != line { blocks.append(line) }
        }

        for line in lines {
            if let level = headingLevel(for: line, bodySize: bodySize) {
                flushParagraph()
                // A wrapped title arrives as several lines at the same size — one heading.
                if let pending = heading, pending.level == level {
                    heading = (level, pending.text + " " + line.text)
                } else {
                    flushHeading()
                    heading = (level, line.text)
                }
                continue
            }
            flushHeading()

            if let bullet = bulletBody(of: line.text) {
                flushParagraph()
                blocks.append("- " + bullet)
                continue
            }

            if paragraph.hasSuffix("-") && !paragraph.hasSuffix("--") {
                paragraph = String(paragraph.dropLast()) + line.text   // word split across lines
            } else {
                paragraph = paragraph.isEmpty ? line.text : paragraph + " " + line.text
            }

            // A line ending in sentence punctuation ends the paragraph; mid-sentence wraps don't.
            if line.text.range(of: "[.!?:][\"”’)]?$", options: .regularExpression) != nil { flushParagraph() }
        }
        flushHeading()
        flushParagraph()
        return blocks.joined(separator: "\n\n")
    }

    private static func headingLevel(for line: Line, bodySize: CGFloat) -> Int? {
        guard bodySize > 0, line.size > 0, line.text.count <= 120 else { return nil }
        let ratio = line.size / bodySize
        if ratio >= 2.0 { return 1 }
        if ratio >= 1.5 { return 2 }
        if ratio >= 1.2 { return 3 }
        return nil
    }

    private static func bulletBody(of text: String) -> String? {
        let pattern = "^\\s*([•·▪–-]|\\*|\\d{1,2}[.)])\\s+"
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range.upperBound...])
    }
}
