import JSONRenderSwiftUI
import PDFKit
import SwiftUI

/// A PDFKit preview of a spec rendered with ``PDFRenderer``. Re-renders whenever `spec`
/// changes, keeping the last good document (and the reader's page) on screen meanwhile.
///
/// ```swift
/// JSONRenderPDFView(spec: spec)
///     .onPDFRender { result in lastPDF = try? result.get() }
/// ```
///
/// While a spec streams in, debounce updates (e.g. render every second or so); each
/// change cancels the previous render. The view re-renders when `spec`, `options.state`,
/// the timeout, limits or page cap change; pass `id` to force a re-render for changes it
/// cannot compare (such as a different image loader).
public struct JSONRenderPDFView: View {
    private let spec: Spec?
    private let options: PDFRenderer.Options
    private let id: AnyHashable?
    private var onRender: (@MainActor (Result<Data, Error>) -> Void)?

    @State private var document: PDFDocument?

    public init(spec: Spec?, options: PDFRenderer.Options = PDFRenderer.Options(), id: AnyHashable? = nil) {
        self.spec = spec
        self.options = options
        self.id = id
    }

    /// Everything that changes the rendered output and can be compared.
    private struct RenderKey: Hashable {
        var spec: Spec?
        var state: [String: JSONValue]
        var timeout: Duration
        var limits: PDFImageLimits
        var maxPages: Int
        var id: AnyHashable?
    }

    private var renderKey: RenderKey {
        RenderKey(
            spec: spec, state: options.state, timeout: options.imageTimeout,
            limits: options.imageLimits, maxPages: options.maxPages, id: id
        )
    }

    /// Called on the main actor after every render attempt with the PDF bytes or the error.
    public func onPDFRender(_ action: @escaping @MainActor (Result<Data, Error>) -> Void) -> JSONRenderPDFView {
        var copy = self
        copy.onRender = action
        return copy
    }

    public var body: some View {
        PDFKitRepresentable(document: document)
            .task(id: renderKey) {
                guard let spec else {
                    document = nil
                    return
                }
                guard let result = await Self.render(spec, options: options) else { return }
                if case .success(let data) = result, let rendered = PDFDocument(data: data) { document = rendered }
                onRender?(result)
            }
    }

    /// One render pass; `nil` when cancelled (a newer spec superseded it).
    static func render(_ spec: Spec, options: PDFRenderer.Options) async -> Result<Data, Error>? {
        do {
            let data = try await PDFRenderer(options: options).render(spec)
            try Task.checkCancellation()
            return .success(data)
        } catch is CancellationError {
            return nil
        } catch {
            return .failure(error)
        }
    }
}

#if os(iOS)
private struct PDFKitRepresentable: UIViewRepresentable {
    let document: PDFDocument?

    func makeUIView(context: Context) -> PDFView {
        PDFKitRepresentable.configure(PDFView())
    }

    func updateUIView(_ view: PDFView, context: Context) {
        PDFKitRepresentable.update(view, with: document)
    }
}
#else
private struct PDFKitRepresentable: NSViewRepresentable {
    let document: PDFDocument?

    func makeNSView(context: Context) -> PDFView {
        PDFKitRepresentable.configure(PDFView())
    }

    func updateNSView(_ view: PDFView, context: Context) {
        PDFKitRepresentable.update(view, with: document)
    }
}
#endif

extension PDFKitRepresentable {
    static func configure(_ view: PDFView) -> PDFView {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        return view
    }

    /// Swaps documents while staying on the same page index.
    static func update(_ view: PDFView, with document: PDFDocument?) {
        guard view.document !== document else { return }
        let pageIndex = view.currentPage.flatMap { view.document?.index(for: $0) } ?? 0
        view.document = document
        if let document, pageIndex > 0, let page = document.page(at: min(pageIndex, document.pageCount - 1)) {
            view.go(to: page)
        }
    }
}
