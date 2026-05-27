import Foundation

struct ParsedEntry {
    let text: String
    let projectTag: String?
    let personTag: String?
}

struct TagParser {
    // Detect if text ends with an active tag being typed (e.g. "#auth" or "@ann")
    static func activeTag(in text: String) -> (prefix: String, partial: String)? {
        let words = text.components(separatedBy: " ")
        guard let last = words.last, !last.isEmpty else { return nil }
        let partial = stripTrailingPunctuation(
            String(last.dropFirst()).replacingOccurrences(of: "\u{00A0}", with: " ")
        )
        if last.hasPrefix("#") { return ("#", partial) }
        if last.hasPrefix("@") { return ("@", partial) }
        return nil
    }

    // Parse complete tags out of submitted text, return cleaned text + tags.
    // Strips trailing punctuation from tags (e.g. #ICA. → "ICA").
    // For @ tags, optionally consumes the next word as a surname if it starts with an uppercase letter.
    static func parse(_ input: String) -> ParsedEntry {
        let words = input.components(separatedBy: " ")
        var projectTag: String? = nil
        var personTag: String? = nil
        var remaining: [String] = []
        var i = 0

        while i < words.count {
            let word = words[i]
            if word.hasPrefix("#"), word.count > 1, projectTag == nil {
                projectTag = stripTrailingPunctuation(
                    String(word.dropFirst()).replacingOccurrences(of: "\u{00A0}", with: " ")
                )
                i += 1
            } else if word.hasPrefix("@"), word.count > 1, personTag == nil {
                let firstName = stripTrailingPunctuation(
                    String(word.dropFirst()).replacingOccurrences(of: "\u{00A0}", with: " ")
                )
                // Consume the next word as a surname if it starts with an uppercase letter
                if i + 1 < words.count {
                    let next = words[i + 1]
                    if !next.hasPrefix("#"), !next.hasPrefix("@"),
                       let firstChar = next.first, firstChar.isUppercase {
                        let surname = stripTrailingPunctuation(
                            next.replacingOccurrences(of: "\u{00A0}", with: " ")
                        )
                        if !surname.isEmpty {
                            personTag = firstName + " " + surname
                            i += 2
                            continue
                        }
                    }
                }
                personTag = firstName
                i += 1
            } else {
                remaining.append(word)
                i += 1
            }
        }

        return ParsedEntry(
            text: remaining.joined(separator: " ").trimmingCharacters(in: .whitespaces),
            projectTag: projectTag,
            personTag: personTag
        )
    }

    static func stripTrailingPunctuation(_ text: String) -> String {
        var result = text
        let punctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]
        while let last = result.last, punctuation.contains(last) {
            result.removeLast()
        }
        return result
    }
}
