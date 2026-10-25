import SwiftUI

struct CodeBlock: Identifiable {
    var title: String
    var text: String
    var placeholder: String?

    var id: String { title }
}

/// Monospaced, selectable code cards with a copy button (JSON and JSONL tabs).
struct CodeView: View {
    let blocks: [CodeBlock]
    let onCopy: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(blocks) { block in
                    card(block)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func card(_ block: CodeBlock) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(block.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") { onCopy(block.text) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .disabled(block.text.isEmpty)
            }
            if block.text.isEmpty, let placeholder = block.placeholder {
                Text(placeholder)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text(block.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.background, in: .rect(cornerRadius: 20))
    }
}
