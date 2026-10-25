import SwiftUI

/// Floating Liquid Glass prompt field with a send / stop button.
struct PromptBar: View {
    @Binding var text: String
    let placeholder: String
    let isStreaming: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
                .focused($isFocused)
                .submitLabel(.send)
                .padding(.leading, 18)
                .padding(.vertical, 14)
                .onChange(of: text) { _, newValue in
                    // A vertical TextField inserts the return key as a newline: treat it as send.
                    guard newValue.hasSuffix("\n") else { return }
                    text = String(newValue.dropLast())
                    submit()
                }

            Button(action: isStreaming ? onStop : submit) {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.body.weight(.bold))
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(isStreaming ? .red : .accentColor)
            .disabled(!isStreaming && !canSend)
            .accessibilityLabel(isStreaming ? "Stop" : "Send")
            .padding(6)
        }
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
    }

    private func submit() {
        guard canSend else { return }
        isFocused = false
        onSend()
    }
}

/// "Generating…" capsule shown above the prompt bar while a stream runs.
struct StreamingStatus: View {
    let activity: GenerationController.Activity
    let patchCount: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(title)
                .font(.footnote.weight(.medium))
            Text("\(patchCount) patches")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .animation(.snappy, value: patchCount)
    }

    private var title: String {
        switch activity {
        case .replaying: "Replaying stream"
        case .generating, .idle: "Generating"
        }
    }
}
