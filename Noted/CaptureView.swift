import SwiftUI

enum CaptureType: String, CaseIterable {
    case task = "Task"
    case note = "Note"
}

struct CaptureView: View {
    let onDismiss: () -> Void

    @State private var text = ""
    @State private var type: CaptureType = .task
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $type) {
                ForEach(CaptureType.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField(type == .task ? "New task…" : "Quick note…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isFocused)
                .onSubmit(submit)
                .onExitCommand(perform: onDismiss)
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear {
            text = ""
            isFocused = true
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            onDismiss()
            return
        }
        JournalWriter.shared.append(text: trimmed, type: type)
        text = ""
        onDismiss()
    }
}
