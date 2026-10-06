import Foundation

/// The timer's state, shared with the Obsidian view through `Meta/pomodoro/state.json` in the
/// vault. Both sides read and write that one file, so starting a session in Obsidian shows up
/// in the menu bar and vice versa.
///
/// Times are absolute epoch milliseconds rather than a ticking counter: neither side has to be
/// running — or awake — for the countdown to stay correct.
struct PomodoroState: Codable, Equatable {
    enum Phase: String, Codable {
        case focus, short, long

        var minutes: Double {
            switch self {
            case .focus: return 25
            case .short: return 5
            case .long: return 15
            }
        }

        var label: String {
            switch self {
            case .focus: return "Focus"
            case .short: return "Short break"
            case .long: return "Long break"
            }
        }
    }

    var phase: Phase = .focus
    /// Set while running, nil while paused. `remaining` is authoritative when paused.
    var endsAt: Double?
    var remaining: Double = Phase.focus.minutes * 60_000
    var done = 0
    var task = ""
    var updatedAt = Date().timeIntervalSince1970 * 1000

    var isRunning: Bool { endsAt != nil }

    var msLeft: Double {
        guard let endsAt else { return remaining }
        return max(0, endsAt - Date().timeIntervalSince1970 * 1000)
    }

    var fullLength: Double { phase.minutes * 60_000 }

    /// "24:13" — what the menu bar shows.
    var clock: String {
        let total = Int((msLeft / 1000).rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    mutating func start() {
        endsAt = Date().timeIntervalSince1970 * 1000 + remaining
        touch()
    }

    mutating func pause() {
        remaining = msLeft
        endsAt = nil
        touch()
    }

    mutating func reset() {
        endsAt = nil
        remaining = fullLength
        touch()
    }

    /// Breaks never auto-start — stopping is the point of a break.
    mutating func advance(completed: Bool) {
        if completed, phase == .focus { done += 1 }
        if phase == .focus {
            phase = done % Self.longBreakEvery == 0 ? .long : .short
        } else {
            phase = .focus
        }
        reset()
    }

    // MARK: - Private

    private static let longBreakEvery = 4

    private mutating func touch() { updatedAt = Date().timeIntervalSince1970 * 1000 }
}

/// Reads and writes the shared state file. Kept separate from the timer so the file format is
/// the contract between Swift and the Obsidian view, in one place.
enum PomodoroStore {
    static var fileURL: URL? {
        let path = ObsidianBackend.shared.vaultPath
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
            .appendingPathComponent("Meta/pomodoro/state.json")
    }

    static func load() -> PomodoroState? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PomodoroState.self, from: data)
    }

    static func save(_ state: PomodoroState) {
        guard let fileURL else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
