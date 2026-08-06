import Foundation

// A token in a captured line: plain text, or a tag pointing at a project/person.
enum TagToken: Equatable {
    case text(String)       // literal text, raw (spacing preserved)
    case project(String)    // #tag → project name (cleaned)
    case person(String)     // @tag → person name (cleaned)
}

struct ParsedEntry {
    let text: String
    let projects: [String]
    let people: [String]

    // Convenience for callers that only care about the first tag of each kind.
    var projectTag: String? { projects.first }
    var personTag: String? { people.first }
}

// Parses #project / @person tags out of a captured line.
//
// A tag is either a single bare word (`@ada`, `#api`) or an explicitly quoted phrase
// (`@"Ada Lovelace"`, `#"Project X"`). There is no surname guessing: a bare tag stops at
// the first space, so "@Ada Monday we sync" yields the person "Ada", never "Ada Monday".
// Multiple people and projects per line are all captured.
struct TagParser {
    // Tokenize once; every consumer (tag extraction, wikilink rendering) builds on this,
    // so the tag-detection rules live in exactly one place.
    static func tokenize(_ input: String) -> [TagToken] {
        var tokens: [TagToken] = []
        var literal = ""
        let chars = Array(input)
        var i = 0

        func flush() {
            if !literal.isEmpty { tokens.append(.text(literal)); literal = "" }
        }

        while i < chars.count {
            let c = chars[i]
            let atBoundary = i == 0 || isBoundary(chars[i - 1])
            guard (c == "@" || c == "#"), atBoundary, i + 1 < chars.count else {
                literal.append(c); i += 1; continue
            }

            var j = i + 1
            var name: String
            if chars[j] == "\"" {
                // Quoted: everything up to the closing quote is the name.
                j += 1
                var raw = ""
                while j < chars.count, chars[j] != "\"" { raw.append(chars[j]); j += 1 }
                if j < chars.count { j += 1 }   // consume closing quote
                name = normalize(raw)
            } else {
                // Bare: a single whitespace-delimited word.
                var raw = ""
                while j < chars.count, !isBoundary(chars[j]) { raw.append(chars[j]); j += 1 }
                name = stripTrailingPunctuation(normalize(raw))
            }

            if name.isEmpty {
                literal.append(c); i += 1; continue   // lone "@" / "#" is just text
            }
            flush()
            tokens.append(c == "#" ? .project(name) : .person(name))
            i = j
        }
        flush()
        return tokens
    }

    static func parse(_ input: String) -> ParsedEntry {
        var projects: [String] = []
        var people: [String] = []
        var text = ""
        for token in tokenize(input) {
            switch token {
            case .text(let t): text += t
            case .project(let n): if !projects.contains(n) { projects.append(n) }; text += n
            case .person(let n): if !people.contains(n) { people.append(n) }; text += n
            }
        }
        return ParsedEntry(
            text: text.trimmingCharacters(in: .whitespaces),
            projects: projects,
            people: people
        )
    }

    // The tag currently being typed at the end of the text (drives autocomplete).
    // Active while inside an open quote (`@"Ada Lov`) or a bare word with no trailing space.
    static func activeTag(in text: String) -> (prefix: String, partial: String)? {
        let chars = Array(text)
        var sigil: Int? = nil
        for k in stride(from: chars.count - 1, through: 0, by: -1) where chars[k] == "@" || chars[k] == "#" {
            if k == 0 || isBoundary(chars[k - 1]) { sigil = k; break }
        }
        guard let s = sigil else { return nil }
        let prefix = String(chars[s])
        let rest = String(chars[(s + 1)...])

        if rest.hasPrefix("\"") {
            let body = String(rest.dropFirst())
            if body.contains("\"") { return nil }          // quote closed → tag complete
            return (prefix, normalize(body))
        }
        if rest.contains(" ") || rest.contains("\n") { return nil }  // bare tag ended at space
        return (prefix, stripTrailingPunctuation(normalize(rest)))
    }

    static func stripTrailingPunctuation(_ text: String) -> String {
        var result = text
        let punctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]
        while let last = result.last, punctuation.contains(last) {
            result.removeLast()
        }
        return result
    }

    // MARK: - Private

    private static func isBoundary(_ c: Character) -> Bool {
        c == " " || c == "\n" || c == "\u{00A0}"
    }

    private static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
