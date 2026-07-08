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

    func ingest(urlString: String) {
        let item = IngestedArticle(title: hostLabel(urlString), url: urlString, status: .processing)
        recent.insert(item, at: 0)
        if recent.count > 8 { recent.removeLast(recent.count - 8) }
        let id = item.id

        let backend = UserDefaults.standard.string(forKey: "backendType") ?? BackendType.notion.rawValue
        let useVault = backend == BackendType.obsidian.rawValue
        Task.detached {
            if useVault {
                await self.runVaultIngest(id: id, urlString: urlString)
            } else {
                await self.runNotionIngest(id: id, urlString: urlString)
            }
        }
    }

    // MARK: - Obsidian vault pipeline (markdown wiki)

    nonisolated private func runVaultIngest(id: UUID, urlString: String) async {
        let writer = VaultWriter.shared
        let progress = IngestProgress.start(urlString: urlString)
        do {
            await progress?.update("Fetching source…")
            let fetched = try await ArticleFetcher.shared.fetch(urlString: urlString)

            await progress?.update("Reading & extracting concepts…")
            let existing = writer.existingConceptNames()
            let analysis = try await ArticleAIService.shared.analyze(
                markdown: fetched.markdown, url: fetched.url, existingConcepts: existing
            )

            await progress?.update("Writing concept pages…")
            let result = try await writer.write(analysis: analysis, url: fetched.url, rawMarkdown: fetched.markdown)

            // Best-effort: web-search for related reading and queue it. Never fails the ingest.
            await progress?.update("Scouting related reading…")
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

    // MARK: - Notion pipeline (legacy; used when the Notion backend is selected)

    nonisolated private func runNotionIngest(id: UUID, urlString: String) async {
        let writer = NotionArticleWriter.shared
        var placeholder: ArticlePlaceholder?
        do {
            let created = try await writer.createPlaceholder(url: urlString)
            placeholder = created
            await setPageURL(id: id, pageURL: created.articleURL)

            await writer.updateProgress(created, emoji: "⏳", "Fetching article…", fraction: 0.15)
            let fetched = try await ArticleFetcher.shared.fetch(urlString: urlString)

            await writer.updateProgress(created, emoji: "🧠", "Summarising with Claude…", fraction: 0.45)
            let existing = try await writer.existingConceptNames()
            let analysis = try await ArticleAIService.shared.analyze(
                markdown: fetched.markdown, url: fetched.url, existingConcepts: existing
            )

            await writer.updateProgress(created, emoji: "🔗", "Building concept pages…", fraction: 0.8)
            let result = try await writer.finalize(created, analysis: analysis, url: fetched.url)

            await finish(id: id, title: analysis.article.title, status: .ready, pageURL: result.articlePageURL)
            await notify(
                title: "Article saved",
                body: "\(analysis.article.title) — \(result.conceptCount) concept\(result.conceptCount == 1 ? "" : "s")"
            )
        } catch {
            if let placeholder { await writer.markFailed(placeholder, message: error.localizedDescription) }
            await finish(id: id, title: nil, status: .failed(error.localizedDescription), pageURL: placeholder?.articleURL)
            await notify(title: "Article ingestion failed", body: error.localizedDescription)
        }
    }

    func open(_ article: IngestedArticle) {
        let target = article.pageURL ?? article.url
        if let url = URL(string: target) { NSWorkspace.shared.open(url) }
    }

    // MARK: - Private

    private func setPageURL(id: UUID, pageURL: String) {
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return }
        recent[index].pageURL = pageURL
    }

    private func finish(id: UUID, title: String?, status: IngestedArticle.Status, pageURL: String?) {
        guard let index = recent.firstIndex(where: { $0.id == id }) else { return }
        if let title { recent[index].title = title }
        recent[index].status = status
        recent[index].pageURL = pageURL
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
