import Foundation

// A transient placeholder note at the vault root showing a progress bar while an article is
// ingested, then deleting itself on success (or staying, with the error, on failure).
// Obsidian live-reloads the file as it changes on disk, so an open note actually animates.
actor IngestProgress {
    private let fileURL: URL
    private let urlString: String
    private var phase: String = "Starting…"
    private var fraction: Double = 0
    private var frame = 0
    private var ticker: Task<Void, Never>?

    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
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
        Task { await progress.begin() }
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
        ticker?.cancel()
        try? FileManager.default.removeItem(at: fileURL)
    }

    func fail(_ message: String) {
        ticker?.cancel()
        let body = """
        # ⚠️ Ingestion failed

        \(urlString)

        \(message)

        _Delete this note once you've seen it._
        """
        try? body.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Private

    private func begin() {
        render()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                await self?.tick()
            }
        }
    }

    private func tick() {
        frame = (frame + 1) % Self.frames.count
        render()
    }

    private func render() {
        let filled = Int((fraction * Double(Self.barWidth)).rounded())
        let bar = String(repeating: "█", count: filled)
            + String(repeating: "░", count: Self.barWidth - filled)
        let body = """
        # \(Self.frames[frame]) Ingesting… \(Int(fraction * 100))%

        `\(bar)`

        **\(phase)**

        \(urlString)

        _This note disappears when the wiki finishes. Open it to watch progress._
        """
        try? body.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
