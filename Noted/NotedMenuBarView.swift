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
        let title = article.title.count > 40 ? String(article.title.prefix(40)) + "…" : article.title
        switch article.status {
        case .processing:
            // Menus can't host a ProgressView, so the bar is drawn with block characters.
            return "\(bar(article.fraction))  \(Int(article.fraction * 100))%  \(article.phase)"
        case .ready:
            return "✓  \(title)"
        case .failed:
            return "⚠️  \(title)"
        }
    }

    private func bar(_ fraction: Double) -> String {
        let width = 10
        let filled = Int((min(max(fraction, 0), 1) * Double(width)).rounded())
        return String(repeating: "▓", count: filled) + String(repeating: "░", count: width - filled)
    }
}
