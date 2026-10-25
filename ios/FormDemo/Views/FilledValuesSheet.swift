import JSONRenderSwiftUI
import SwiftUI
import UIKit

extension PDFPreviewModel.FilledValues: Identifiable {
    var id: String { json.jsonString() }
}

/// Values read back from the (edited) fillable PDF, with "Apply to state".
struct FilledValuesSheet: View {
    let values: PDFPreviewModel.FilledValues
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label(summary, systemImage: "doc.text.magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(values.json.jsonString(prettyPrinted: true))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                    if !values.unboundFields.isEmpty {
                        Text("Not bound to state, so not applied: \(values.unboundFields.joined(separator: ", ")).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                Button {
                    onApply()
                    dismiss()
                } label: {
                    Label("Apply to state", systemImage: "arrow.down.doc")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(values.updates.isEmpty)
                .padding()
            }
            .navigationTitle("Filled values")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = values.json.jsonString(prettyPrinted: true)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var summary: String {
        let count = values.values.count
        let fields = count == 1 ? "1 field" : "\(count) fields"
        return "Read from the PDF as it is now, including your edits: \(fields). \(values.updates.count) map to the document's state."
    }
}
