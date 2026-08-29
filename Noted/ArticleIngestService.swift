import Foundation
import AppKit
import Combine
import UserNotifications

// A single article ingestion, surfaced in the menu bar's "Recent articles" list.
struct IngestedArticle: Identifiable {
    let id = UUID()
    var title: String
    var url: String
    var status: Status
    var pageURL: String?
    // 0…1 while processing, so the menu bar can show a real figure instead of a shrug.
    var fraction: Double = 0
    var phase: String = "Queued"

    enum Status: Equatable {
        case processing
        case ready
        case failed(String)
    }
}

// Orchestrates fetch → analyze → write, off the main thread, and tracks progress
// so the menu bar can show what's in flight and link to finished pages.
@MainActor
class ArticleIngestService: ObservableObject {
    static let shared = ArticleIngestService()
    private init() {}

    @Published private(set) var recent: [IngestedArticle] = []

    // Stage boundaries as fractions of the whole job. The analyze call is the slowest leg by
    // far, and writing concepts is the only stage that can report genuine sub-progress.
    private enum Stage {
        static let fetched = 0.20
        static let analyzed = 0.55
        static let written = 0.85
        static let related = 0.97
    }

    // Percentage for the menu bar title, or nil when nothing is in flight.
    var activePercent: Int? {
        guard let article = recent.first(where: { $0.status == .processing }) else { return nil }
        return Int(article.fraction * 100)
    }

    func ingest(urlString: String) {
        let item = IngestedArticle(title: hostLabel(urlString), url: urlString, status: .processing)
        recent.insert(item, at: 0)
        if recent.count > 8 { recent.removeLast(recent.count - 8) }
        let id = item.id

        Task.detached {
            await self.runVaultIngest(id: id, urlString: urlString)
        }
    }

    // Open the finished wiki page if we have one, else the original article URL.
    func open(_ article: IngestedArticle) {
        let target = article.pageURL ?? article.url
        if let url = URL(string: target) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Obsidian vault pipeline (markdown wiki)

    nonisolated private func runVaultIngest(id: UUID, urlString: String) async {
        let writer = VaultWriter.shared
        let progress = IngestProgress.start(urlString: urlString)

        // Both the in-vault note and the menu bar read from the same call, so they can't drift.
        @Sendable func report(_ phase: String, _ fraction: Double) async {
            await progress?.update(phase, fraction: fraction)
            await self.setProgress(id: id, phase: phase, fraction: fraction)
        }

        do {
            await report("Fetching source…", 0.05)
            let fetched = try await ArticleFetcher.shared.fetch(urlString: urlString)

            await report("Reading & extracting concepts…", Stage.fetched)
            let existing = writer.existingConceptNames()
            let raw = try await ArticleAIService.shared.analyze(
                markdown: fetched.markdown, url: fetched.url, existingConcepts: existing
            )
            // Blank titles/concept names become blank filenames — repair before writing.
            let analysis = raw.normalized(url: fetched.url, markdown: fetched.markdown)

            await report("Writing concept pages…", Stage.analyzed)
            let span = Stage.written - Stage.analyzed
            let result = try await writer.write(
                analysis: analysis, url: fetched.url, rawMarkdown: fetched.markdown
            ) { done, total in
                guard total > 0 else { return }
                let fraction = Stage.analyzed + span * (Double(done) / Double(total))
                Task { await report("Writing concept \(done) of \(total)…", fraction) }
            }

            // Best-effort: web-search for related reading and queue it. Never fails the ingest.
            await report("Scouting related reading…", Stage.written)
            var related = 0
            if let suggestions = try? await ArticleAIService.shared.suggestRelated(
                meta: analysis.article,
                knownTitles: writer.knownReadingTitles() + [analysis.article.title]
            ), !suggestions.isEmpty {
                related = (try? writer.appendReadingSuggestions(
                    suggestions, viaTitle: analysis.article.title, viaRef: result.rawArticleRef
                )) ?? 0
                // the article's own record of what it spawned — the other half of the link
                try? writer.appendSuggestedReading(suggestions, toArticleRef: result.rawArticleRef)
            }

            await report("Finishing…", Stage.related)
            await progress?.finish()

            let pageURL = result.primaryConceptPath.map { URL(fileURLWithPath: $0).absoluteString }
            await finish(id: id, title: analysis.article.title, status: .ready, pageURL: pageURL)

            let conflictSuffix = result.conflictCount > 0
                ? " · \(result.conflictCount) conflict\(result.conflictCount == 1 ? "" : "s") to review"
                : ""
            let readingSuffix = related > 0
                ? " · \(related) reading suggestion\(related == 1 ? "" : "s")"
                : ""
            await notify(
                title: "Added to wiki",
                body: "\(analysis.article.title) — \(result.conceptCount) concept\(result.conceptCount == 1 ? "" : "s")\(conflictSuffix)\(readingSuffix)"
            )
        } catch {
            await progress?.fail(error.localizedDescription)
            await finish(id: id, title: nil, status: .failed(error.localizedDescription), pageURL: nil)
            await notify(title: "Article ingestion failed", body: error.localizedDescription)
        }
    }

    // MARK: - Private

    private func setProgress(id: UUID, phase: String, fraction: Double) {
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return }
        recent[index].phase = phase
        recent[index].fraction = fraction
    }

    private func finish(id: UUID, title: String?, status: IngestedArticle.Status, pageURL: String?) {
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return }
        if let title { recent[index].title = title }
        recent[index].status = status
        recent[index].pageURL = pageURL
        if status == .ready { recent[index].fraction = 1 }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func hostLabel(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? "Article"
    }
}
