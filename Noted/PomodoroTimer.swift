import Foundation
import Combine
import SwiftUI
import UserNotifications

/// Drives the Pomodoro from the menu bar and keeps it in sync with the Obsidian view.
///
/// A single one-second tick does both jobs: repaint the countdown, and pick up changes the
/// Obsidian side wrote to the shared file. Polling is enough — the file is a few hundred bytes
/// and only one person is ever driving it.
@MainActor
class PomodoroTimer: ObservableObject {
    static let shared = PomodoroTimer()

    @Published private(set) var state = PomodoroStore.load() ?? PomodoroState()

    /// What the menu bar shows, or nil when idle so the glyph can take the space back.
    var menuBarTitle: String? {
        guard state.isRunning || state.msLeft < state.fullLength else { return nil }
        return "\(state.phase == .focus ? "🍅" : "☕️") \(state.clock)"
    }

    func toggle() {
        if state.isRunning { state.pause() } else { state.start() }
        persist()
    }

    func reset() {
        state.reset()
        persist()
    }

    func skip() {
        state.advance(completed: false)
        persist()
    }

    func setTask(_ task: String) {
        state.task = task
        persist()
    }

    func begin() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: - Private

    private var ticker: Timer?
    private var isCompleting = false

    private func persist() {
        PomodoroStore.save(state)
        objectWillChange.send()
    }

    private func tick() {
        adoptExternalChanges()
        if state.isRunning, state.msLeft <= 0 {
            complete()
        } else {
            // The clock string changes every second even when nothing else does.
            objectWillChange.send()
        }
    }

    /// Takes on whatever the Obsidian view wrote, so the two surfaces never disagree.
    private func adoptExternalChanges() {
        guard let stored = PomodoroStore.load(), stored.updatedAt > state.updatedAt else { return }
        state = stored
    }

    private func complete() {
        guard !isCompleting else { return }
        isCompleting = true

        let wasFocus = state.phase == .focus
        let task = state.task.trimmingCharacters(in: .whitespacesAndNewlines)
        state.advance(completed: true)
        persist()

        if wasFocus {
            // Goes through the normal capture path, so #project in the task text still becomes
            // a [[link]] and the session lands under ## Notes like any other observation.
            let text = task.isEmpty ? "🍅 Focus session" : "🍅 \(task)"
            Task { try? await ObsidianBackend.shared.append(text: text, type: .note) }
        }
        notify(wasFocus ? "Focus done — take a break" : "Break over — back to it")
        isCompleting = false
    }

    private func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pomodoro"
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
