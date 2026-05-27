# Noted

A macOS menu bar app for system-wide quick capture. One hotkey from any app — type a task or note, hit Return, done.

Writes to Notion (via [Hivemind](../Hivemind/)) or directly to an Obsidian vault.

---

## Capture flow

**Cmd+Shift+Space** from anywhere opens a floating dark panel. Type your entry, pick Task or Note, and submit.

- **Return** — submit and close
- **Shift+Return** — submit and keep the panel open (good for capturing several things in a row)
- **Esc** — dismiss without saving

---

## Tagging

Tags route your entry to the right place in Notion:

- `#ProjectName` — links to that project; task lands in the Tasks DB and gets a synced reference on the project page
- `@FirstName` or `@First Surname` — links to that person; note lands in the Notes DB and gets a synced reference on their page

Autocomplete kicks in as you type `#` or `@`, pulling live suggestions from Notion with color indicators. Tab or arrow keys to navigate, Return to accept.

No tags: entry goes directly to today's daily page (tasks section or notes section).

---

## Backends

### Notion
Reads all configuration (API key, database IDs, today's page ID) from the shared App Group with Hivemind. No setup needed in Noted beyond running workspace setup in Hivemind first. After saving a note, fires a notification that triggers Hivemind's AI linking engine.

### Obsidian
Writes to `{vault}/Journal/YYYY-MM-DD.md`. Creates the file from a daily template if it doesn't exist. Tasks go under `## Tasks`, notes under `### Notes`.

---

## Setup

1. Build and run in Xcode (macOS 14+, no App Store — sandbox off, required for the global hotkey).
2. For Notion backend: set up Hivemind first — Noted picks up the config automatically.
3. For Obsidian backend: choose your vault folder in Settings.

---

## Integration with Hivemind

Noted and [Hivemind](../Hivemind/) share an App Group (`group.johanwilander.hivemind`). Hivemind writes Notion credentials and IDs to shared UserDefaults; Noted reads them. After every Notion note write, Noted fires `com.hivemind.noteAdded` — Hivemind responds by scanning the new note for connections to existing knowledge.

---

## Tech

- Swift / SwiftUI + AppKit
- Carbon `RegisterEventHotKey` for the global hotkey
- Notion API (REST) — synced blocks, task DB entries, note DB entries
- File-based Obsidian backend
- No third-party dependencies
