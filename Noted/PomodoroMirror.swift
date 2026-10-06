import Foundation
import Combine

/// Shows the Obsidian Pomodoro plugin's countdown in the macOS menu bar, so a session stays
/// visible from any app rather than only inside Obsidian.
///
/// Strictly read-only. The plugin owns the timer, the phase changes and the journal logging;
/// this reads its `data.json` and renders. One writer means the two can never disagree, which
/// an earlier two-way version could.
@MainActor
class PomodoroMirror: ObservableObject {
    static let shared = PomodoroMirror()

    /// "🍅 24:13" while running, "⏸ 12:30" when paused mid-session, nil when idle so the
    /// glyph gets its space back.
    var menuBarTitle: String? {
        guard let data else { return nil }
        let left = msLeft(data)
        let running = data.state.endsAt != nil
        guard running || left < fullLength(data) else { return nil }
        let icon = running ? (data.state.phase == "focus" ? "🍅" : "☕️") : "⏸"
        return "\(icon) \(clock(left))"
    }

    func begin() {
        guard ticker == nil else { return }
        reload()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Private

    private struct PluginData: Decodable {
        struct State: Decodable {
            let phase: String
            let endsAt: Double?
            let remaining: Double
        }
        let focus: Double
        let short: Double
        let long: Double
        let state: State
    }

    private var data: PluginData?
    private var ticker: Timer?
    private var lastModified: Date?

    private var fileURL: URL? {
        let path = ObsidianBackend.shared.vaultPath
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
            .appendingPathComponent(".obsidian/plugins/sb-pomodoro/data.json")
    }

    private func tick() {
        reload()
        // The clock string changes every second even when the file hasn't.
        objectWillChange.send()
    }

    /// Re-reads only when the file actually changed — the plugin writes on phase changes, not
    /// on every tick, and the countdown is derived from an absolute timestamp anyway.
    private func reload() {
        guard let fileURL else { return }
        let modified = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        if let modified, modified == lastModified { return }
        lastModified = modified ?? nil
        guard let bytes = try? Data(contentsOf: fileURL) else { data = nil; return }
        data = try? JSONDecoder().decode(PluginData.self, from: bytes)
    }

    private func msLeft(_ data: PluginData) -> Double {
        guard let endsAt = data.state.endsAt else { return data.state.remaining }
        return max(0, endsAt - Date().timeIntervalSince1970 * 1000)
    }

    private func fullLength(_ data: PluginData) -> Double {
        switch data.state.phase {
        case "short": return data.short * 60_000
        case "long": return data.long * 60_000
        default: return data.focus * 60_000
        }
    }

    private func clock(_ ms: Double) -> String {
        let total = Int((ms / 1000).rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
