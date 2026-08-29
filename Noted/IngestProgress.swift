import Foundation

// A transient placeholder note at the vault root showing a progress bar while an article is
// ingested, then deleting itself on success (or staying, with the error, on failure).
// Obsidian live-reloads the file as it changes on disk, so an open note actually animates.
actor IngestProgress {
    private let fileURL: URL
    private let urlString: String
    private var phase: String = "Starting…"
    private var fraction: Double = 0
    private static let barWidth = 24
    private static let notePrefix = "Ingesting — "

    private static var vaultURL: URL? {
        let path = UserDefaults.standard.string(forKey: "vaultPath") ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    // Returns nil if no vault is configured (caller just proceeds without a placeholder).
    static func start(urlString: String) -> IngestProgress? {
        guard let vault = vaultURL else { return nil }
        let host = URL(string: urlString)?.host ?? "article"
        let progress = IngestProgress(
            fileURL: vault.appendingPathComponent("\(notePrefix)\(host).md"), urlString: urlString
        )
        Task { await progress.render() }
        return progress
    }

    // Quitting mid-ingest leaves the placeholder behind — it can only be cleaned up by whoever
    // starts next, since no ingest can be in flight at launch.
    static func clearStale() {
        guard let vault = vaultURL,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: vault.path) else { return }
        for name in entries where name.hasPrefix(notePrefix) && name.hasSuffix(".md") {
            try? FileManager.default.removeItem(at: vault.appendingPathComponent(name))
        }
    }

    private init(fileURL: URL, urlString: String) {
        self.fileURL = fileURL
        self.urlString = urlString
    }

    func update(_ phase: String, fraction: Double) {
        self.phase = phase
        self.fraction = min(max(fraction, 0), 1)
        render()
    }

    func finish() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func fail(_ message: String) {
        let body = """
        # ⚠️ Ingestion failed

        \(urlString)

        \(message)

        _Delete this note once you've seen it._
        """
        try? body.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Private

    // The bar's geometry is written as inline styles so the note renders correctly in any
    // vault, with or without the noted-progress.css snippet installed — a note that depends on
    // a stylesheet it can't guarantee just shows nothing. The snippet layers the animation on
    // top (sheen, easing, the pulsing dots); the class names exist purely as its hooks.
    private func render() {
        let percent = Int(fraction * 100)
        let filled = Int((fraction * Double(Self.barWidth)).rounded())
        let asciiBar = String(repeating: "█", count: filled)
            + String(repeating: "░", count: Self.barWidth - filled)

        let accent = "var(--sb-acc1, #514b82)"
        let track = "position:relative;height:22px;border-radius:20px;border:2px solid;"
            + "color:\(accent);overflow:hidden;background:var(--background-modifier-border)"
        let fill = "position:absolute;margin:2px;inset:0 \(100 - percent)% 0 0;"
            + "border-radius:20px;background:currentColor"
        let meta = "display:flex;justify-content:space-between;margin-top:.6em;"
            + "font-size:.85em;color:var(--text-muted)"

        let body = """
        # Ingesting… \(percent)%

        <div class="noted-ingest" style="--pct:\(percent)">
        <div class="noted-ingest-track" style="\(track)"><div class="noted-ingest-fill" style="\(fill)"></div></div>
        <div class="noted-ingest-meta" style="\(meta)"><span class="noted-ingest-phase">\(phase)</span><span class="noted-ingest-pct">\(percent)%</span></div>
        </div>

        > [!info]- Plain text version
        > `\(asciiBar)` \(phase)

        \(urlString)

        _This note disappears when the wiki finishes._
        """
        try? body.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
