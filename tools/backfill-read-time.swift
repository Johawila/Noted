// Adds read_time to Articles/ pages that predate the field.
//
// Compiled against the app's own ReadingTime.swift so the backfilled values are produced by
// exactly the same logic as new imports — a reimplementation here would drift.
//
//   swiftc tools/backfill-read-time.swift Noted/ReadingTime.swift -o /tmp/backfill
//   /tmp/backfill <vault-path>          # dry run
//   /tmp/backfill <vault-path> --apply
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { fatalError("usage: backfill <vault-path> [--apply]") }
let vault = URL(fileURLWithPath: args[1])
let apply = args.contains("--apply")

let articles = vault.appendingPathComponent("Articles")
let files = FileManager.default.enumerator(at: articles, includingPropertiesForKeys: nil)?
    .compactMap { $0 as? URL }
    .filter { $0.pathExtension == "md" }
    .sorted { $0.path < $1.path } ?? []

var updated = 0, skipped = 0, stated = 0

for file in files {
    guard let text = try? String(contentsOf: file, encoding: .utf8),
          text.hasPrefix("---\n") else { skipped += 1; continue }
    let afterOpen = text.index(text.startIndex, offsetBy: 4)
    guard let closeRange = text.range(of: "\n---\n", range: afterOpen..<text.endIndex) else {
        skipped += 1; continue
    }
    let frontmatter = String(text[afterOpen..<closeRange.lowerBound])
    if frontmatter.contains("read_time:") { skipped += 1; continue }

    let body = String(text[closeRange.upperBound...])
    let value = ReadingTime.describe(markdown: body)

    // Sits after `published:` to keep the collected/published/read_time block together.
    var lines = frontmatter.components(separatedBy: "\n")
    let insertAt = (lines.lastIndex { $0.hasPrefix("published:") }).map { $0 + 1 } ?? lines.count
    lines.insert("read_time: \(value)", at: insertAt)

    let rebuilt = "---\n" + lines.joined(separator: "\n") + "\n---\n" + body
    if body.prefix(1200).range(of: #"min(ute)?s? read"#, options: [.regularExpression, .caseInsensitive]) != nil {
        stated += 1
    }
    print("\(value.padding(toLength: 12, withPad: " ", startingAt: 0))  \(file.lastPathComponent.prefix(58))")
    if apply { try? rebuilt.write(to: file, atomically: true, encoding: .utf8) }
    updated += 1
}

print("\n\(updated) article\(updated == 1 ? "" : "s") \(apply ? "updated" : "would be updated"), \(skipped) skipped")
print("\(stated) took a figure stated by the source; \(updated - stated) estimated from word count")
