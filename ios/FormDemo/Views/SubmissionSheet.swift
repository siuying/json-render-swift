import JSONRenderPDF
import JSONRenderSwiftUI
import SwiftUI
import UIKit

/// Shows the data the form's `submit` action delivered to the app, and a PDF summary of
/// it that can be exported.
struct SubmissionSheet: View {
    enum Tab: String, CaseIterable, Identifiable {
        case data, pdf, fillable

        var id: Self { self }
        var title: String {
            switch self {
            case .data: "Data"
            case .pdf: "PDF"
            case .fillable: "Fillable PDF"
            }
        }
    }

    let submission: Submission
    @State private var tab: Tab
    /// The fillable export's preview; owned here so edits survive tab switches and are exported.
    @State private var fillablePreview = PDFPreviewModel()
    @Environment(\.dismiss) private var dismiss

    init(submission: Submission, tab: Tab = .data) {
        self.submission = submission
        _tab = State(initialValue: submission.summary == nil ? .data : tab)
    }

    private var tabs: [Tab] {
        [.data] + (submission.summary == nil ? [] : [.pdf]) + (submission.fillable == nil ? [] : [.fillable])
    }

    var body: some View {
        NavigationStack {
            content
                .background(Color(.systemGroupedBackground))
                .safeAreaBar(edge: .top) {
                    if tabs.count > 1 {
                        Picker("View", selection: $tab) {
                            ForEach(tabs) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }
                }
                .navigationTitle("Submitted")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = submission.prettyJSON
                        }
                    }
                    if submission.summary != nil || submission.fillable != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                if let summary = submission.summary {
                                    shareLink(PDFExport(spec: summary), title: "Export as PDF", systemImage: "doc.richtext")
                                }
                                if let fillable = submission.fillable {
                                    shareLink(
                                        fillablePreview.export(for: fillable, fileSuffix: " (fillable)"),
                                        title: "Export as fillable PDF", systemImage: "pencil.and.list.clipboard"
                                    )
                                }
                            } label: {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .data:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    status
                    Text(submission.prettyJSON)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
                }
                .padding()
            }
        case .pdf:
            JSONRenderPDFView(spec: submission.summary)
        case .fillable:
            FillableSubmissionPreview(spec: submission.fillable, model: fillablePreview)
        }
    }

    private func shareLink(_ export: PDFExport, title: String, systemImage: String) -> some View {
        ShareLink(item: export, preview: SharePreview(export.fileName, image: Image(systemName: systemImage))) {
            Label(title, systemImage: systemImage)
        }
    }

    @ViewBuilder
    private var status: some View {
        if submission.validated {
            Label("All checks passed. This is what the submit action sent to the app.", systemImage: "checkmark.seal.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Label("Current form data. The submit action and its validation did not run.", systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// The fillable form export, editable in place; "Export as fillable PDF" shares what it shows.
private struct FillableSubmissionPreview: View {
    let spec: Spec?
    let model: PDFPreviewModel

    var body: some View {
        FillablePDFView(document: model.document)
            .task(id: spec) { await model.show(spec, isStreaming: false) }
    }
}
