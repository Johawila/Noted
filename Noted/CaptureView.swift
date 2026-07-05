import SwiftUI

extension Notification.Name {
    static let captureWillShow = Notification.Name("captureWillShow")
}

private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct CaptureView: View {
    let onDismiss: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @State private var text = ""
    @AppStorage("lastUsedType") private var lastUsedTypeRaw = CaptureType.task.rawValue
    @AppStorage("backendType") private var backendTypeRaw = BackendType.notion.rawValue
    @State private var type: CaptureType = .task
    @State private var savedType: CaptureType? = nil
    @FocusState private var isFocused: Bool
    @ObservedObject private var tagManager = TagManager.shared
    @State private var selectedSuggestionIndex = 0
    @Namespace private var typeToggleNS

    private var activeSuggestions: [TagInfo] {
        guard let (prefix, partial) = TagParser.activeTag(in: text) else { return [] }
        return tagManager.suggestions(for: prefix, partial: partial)
    }

    // Non-nil when the input is a single bare URL — switches Return to "ingest article".
    private var detectedArticleURL: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), !trimmed.contains("\n"),
              trimmed.lowercased().hasPrefix("http"),
              let url = URL(string: trimmed), url.host != nil else { return nil }
        return trimmed
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Main input row ────────────────────────────────────────────────
            HStack(spacing: 14) {
                Image(systemName: type == .task ? "checkmark.circle" : "note.text")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .animation(.easeInOut(duration: 0.15), value: type)

                TextField(type == .task ? "New task… #project @person" : "Quick note… #project @person", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19))
                    .lineLimit(1...4)
                    .tint(Color(white: 0.9))
                    .focused($isFocused)
                    .onExitCommand(perform: onDismiss)
                    .onKeyPress(.tab) {
                        if !activeSuggestions.isEmpty {
                            moveSuggestionDown()
                            return .handled
                        }
                        type = type == .task ? .note : .task
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard !activeSuggestions.isEmpty else { return .ignored }
                        moveSuggestionUp()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard !activeSuggestions.isEmpty else { return .ignored }
                        moveSuggestionDown()
                        return .handled
                    }
                    .onKeyPress(keys: [.return]) { press in
                        if !activeSuggestions.isEmpty {
                            completeTag(with: activeSuggestions[selectedSuggestionIndex].name)
                            return .handled
                        }
                        if let url = detectedArticleURL, !press.modifiers.contains(.option) {
                            ArticleIngestService.shared.ingest(urlString: url)
                            onDismiss()
                            return .handled
                        }
                        if press.modifiers.contains(.shift) {
                            submit()
                        } else {
                            submitAndClose()
                        }
                        return .handled
                    }
                    .onChange(of: activeSuggestions) { _ in selectedSuggestionIndex = 0 }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, activeSuggestions.isEmpty ? 18 : 10)

            // ── Tag suggestions ───────────────────────────────────────────────
            if !activeSuggestions.isEmpty {
                Divider().opacity(0.3)
                suggestionList()
            }

            Divider()
                .opacity(0.5)

            // ── Footer: type toggle + hint ────────────────────────────────────
            HStack(spacing: 4) {
                HStack(spacing: 0) {
                    ForEach(CaptureType.allCases, id: \.self) { t in
                        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { type = t } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: t == .task ? "checkmark.circle" : "note.text")
                                    .font(.system(size: 11))
                                Text(t.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .foregroundStyle(type == t ? Color.white : Color.secondary)
                            .background {
                                if type == t {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.white.opacity(0.15))
                                        .matchedGeometryEffect(id: "typeIndicator", in: typeToggleNS)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
                Text("→ \(BackendType(rawValue: backendTypeRaw)?.displayName ?? "Notion")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Spacer()

                ZStack {
                    if let saved = savedType {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                            Text("\(saved.rawValue) saved")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.green)
                        .transition(.opacity)
                    } else if detectedArticleURL != nil {
                        Text("↵ ingest article  ·  ⌥↵ save link  ·  esc cancel")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.55))
                            .transition(.opacity)
                    } else {
                        Text("↵ save  ·  ⇧↵ keep open  ·  esc cancel")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: savedType != nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .preferredColorScheme(.dark)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        }
        .overlay(
            GeometryReader { geo in
                Color.clear.preference(key: HeightPreferenceKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(HeightPreferenceKey.self) { onHeightChange($0) }
        .onChange(of: type) { lastUsedTypeRaw = type.rawValue }
        .onReceive(NotificationCenter.default.publisher(for: .captureWillShow)) { _ in
            text = ""
            type = CaptureType(rawValue: lastUsedTypeRaw) ?? .task
            DispatchQueue.main.async { isFocused = true }
            Task { await TagManager.shared.fetchAll() }
        }
    }

    // MARK: - Private

    @ViewBuilder
    private func suggestionList() -> some View {
        let tagPrefix = TagParser.activeTag(in: text)?.prefix == "#" ? "#" : "@"
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(activeSuggestions.enumerated()), id: \.offset) { index, suggestion in
                        Button { completeTag(with: suggestion.name) } label: {
                            HStack(spacing: 8) {
                                if !suggestion.color.isEmpty {
                                    Circle()
                                        .fill(suggestion.swiftUIColor)
                                        .frame(width: 8, height: 8)
                                }
                                Text(tagPrefix).foregroundStyle(.tertiary)
                                Text(suggestion.name).foregroundStyle(.primary)
                            }
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 7)
                            .background(index == selectedSuggestionIndex ? Color.white.opacity(0.1) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
            }
            .frame(height: min(CGFloat(activeSuggestions.count) * 31, 155))
            .onChange(of: selectedSuggestionIndex) { newIndex in
                withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
            }
        }
        .padding(.bottom, 6)
    }

    private func moveSuggestionDown() {
        let count = activeSuggestions.count
        guard count > 0 else { return }
        selectedSuggestionIndex = (selectedSuggestionIndex + 1) % count
    }

    private func moveSuggestionUp() {
        let count = activeSuggestions.count
        guard count > 0 else { return }
        selectedSuggestionIndex = (selectedSuggestionIndex - 1 + count) % count
    }

    private func completeTag(with name: String) {
        guard let (prefix, _) = TagParser.activeTag(in: text),
              let sigil = text.range(of: prefix, options: .backwards) else { return }
        // Quote multi-word names so the parser keeps them as one tag; single words stay bare.
        let tag = name.contains(" ") ? "\(prefix)\"\(name)\"" : "\(prefix)\(name)"
        text = String(text[..<sigil.lowerBound]) + tag + " "
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        JournalWriter.shared.append(text: trimmed, type: type)
        text = ""
        withAnimation { savedType = type }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { savedType = nil }
        }
    }

    private func submitAndClose() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { onDismiss(); return }
        JournalWriter.shared.append(text: trimmed, type: type)
        onDismiss()
    }
}
