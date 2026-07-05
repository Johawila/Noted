import SwiftUI

struct NotedMenuBarView: View {
    let appDelegate: AppDelegate
    @ObservedObject private var ingest = ArticleIngestService.shared

    var body: some View {
        Button("New entry  ⌘⇧Space") {
            appDelegate.toggleCapture()
        }

        if !ingest.recent.isEmpty {
            Divider()
            Text("Recent articles")
            ForEach(ingest.recent) { article in
                Button(label(for: article)) { ingest.open(article) }
            }
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func label(for article: IngestedArticle) -> String {
        let prefix: String
        switch article.status {
        case .processing: prefix = "⏳"
        case .ready: prefix = "✓"
        case .failed: prefix = "⚠️"
        }
        let title = article.title.count > 40 ? String(article.title.prefix(40)) + "…" : article.title
        return "\(prefix)  \(title)"
    }
}
