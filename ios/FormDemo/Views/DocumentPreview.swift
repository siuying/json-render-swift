import JSONRenderSwiftUI
import PDFKit
import SwiftUI

/// Live, fillable PDF preview of the current document spec.
///
/// The document lives in ``PDFPreviewModel``, which re-renders only when the spec or document
/// revision changes (throttled while streaming), so form fields the user fills in survive the
/// end of the stream and tab switches.
struct DocumentPreview: View {
    let spec: Spec?
    let revision: Int
    let isStreaming: Bool
    let model: PDFPreviewModel

    /// Owns every render, including the final one when streaming ends.
    private struct RenderKey: Hashable {
        var spec: Spec?
        var revision: Int
        var isStreaming: Bool
    }

    var body: some View {
        FillablePDFView(document: model.document)
            .overlay(alignment: .top) {
                if let renderError = model.renderError {
                    Label(renderError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular.tint(Color.orange.opacity(0.15)), in: .capsule)
                        .padding(.top, 8)
                }
            }
            .task(id: RenderKey(spec: spec, revision: revision, isStreaming: isStreaming)) {
                await model.show(spec, revision: revision, isStreaming: isStreaming)
            }
    }
}

/// PDFKit's `PDFView`, which lets the user fill in form widgets.
struct FillablePDFView: UIViewRepresentable {
    let document: PDFDocument?

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard view.document !== document else { return }
        let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
        view.document = document
        if let document, pageIndex > 0, let page = document.page(at: min(pageIndex, document.pageCount - 1)) {
            view.go(to: page)
        }
    }
}
