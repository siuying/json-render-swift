import CoreGraphics
import Foundation
import JSONRenderSwiftUI
import PDFKit

/// Renders json-render specs built from the `@json-render/react-pdf` catalog to PDF.
///
/// Pipeline: resolve (state, expressions, visibility, `repeat`) → load images →
/// measure/lay out (Core Text, top-left points) → paginate → draw (Core Graphics PDF
/// context). Pagination completes before drawing, so `PageNumber` knows the total.
///
/// ```swift
/// let renderer = PDFRenderer(options: .init(state: ["customer": "Ada"]))
/// let data = try await renderer.render(spec)
/// let document = try await renderer.document(for: spec)
/// ```
///
/// Partial (streaming) specs render whatever is resolvable; an empty spec yields one
/// blank A4 page. Rendering checks for task cancellation between stages and pages and
/// throws `CancellationError` when cancelled.
public struct PDFRenderer: Sendable {
    public struct Options: Sendable {
        /// Shallowly overrides `spec.state` top-level keys (react-pdf `renderToBuffer`'s `state`).
        public var state: [String: JSONValue]
        public var imageLoader: PDFImageLoader
        /// Per-image load deadline; slower images render as placeholders.
        public var imageTimeout: Duration
        /// Byte, pixel and concurrency budgets for images.
        public var imageLimits: PDFImageLimits
        /// Documents are truncated after this many pages (see ``PDFRenderResult/isTruncated``).
        public var maxPages: Int

        public init(
            state: [String: JSONValue] = [:],
            imageLoader: PDFImageLoader = .default,
            imageTimeout: Duration = .seconds(10),
            imageLimits: PDFImageLimits = PDFImageLimits(),
            maxPages: Int = 500
        ) {
            self.state = state
            self.imageLoader = imageLoader
            self.imageTimeout = imageTimeout
            self.imageLimits = imageLimits
            self.maxPages = maxPages
        }
    }

    public var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    /// PDF bytes for `spec`.
    public func render(_ spec: Spec) async throws -> Data {
        try await renderResult(spec).data
    }

    /// PDF bytes plus page count and anything that was dropped, clipped or truncated.
    public func renderResult(_ spec: Spec) async throws -> PDFRenderResult {
        let output = try await renderWithReport(spec)
        return PDFRenderResult(
            data: output.data, pageCount: output.pages.count, warnings: output.warnings, formFields: output.formFields
        )
    }

    /// The rendered PDF as a PDFKit document.
    public func document(for spec: Spec) async throws -> PDFDocument {
        let data = try await render(spec)
        guard let document = PDFDocument(data: data) else { throw PDFRenderError.contextUnavailable }
        return document
    }

    /// Component types this renderer draws (the react-pdf standard catalog).
    public static var componentTypes: Set<String> { DocumentBuilder.componentTypes }

    // MARK: Internal pipeline

    struct Output {
        var data: Data
        var pages: [DrawnPage]
        var warnings: [PDFRenderWarning]
        var formFields: [PDFFormFieldInfo] = []
    }

    func renderWithReport(_ spec: Spec) async throws -> Output {
        try Task.checkCancellation()
        var stateMembers = spec.state?.objectValue ?? [:]
        stateMembers.merge(options.state) { $1 }
        let resolver = SpecResolver(
            spec: spec, state: .object(stateMembers), knownTypes: DocumentBuilder.componentTypes
        )
        let resolved = resolver.resolveRoot()
        try Task.checkCancellation()
        let batch = await options.imageLoader.loadAll(
            resolved?.imageSources ?? [], timeout: options.imageTimeout, limits: options.imageLimits
        )
        try Task.checkCancellation()
        var output = try Self.draw(resolved, images: batch.images, maxPages: max(options.maxPages, 1))
        output.warnings = resolver.warnings
            + batch.failed.sorted().map { .imageUnavailable(source: $0) }
            + output.warnings
        return output
    }

    /// Synchronous layout + pagination + drawing (all Core Text objects stay local).
    private static func draw(_ resolved: ResolvedElement?, images: [String: LoadedImage], maxPages: Int) throws -> Output {
        let model = DocumentBuilder(images: images).document(from: resolved)
        let text = TextEngine()
        let engine = LayoutEngine(text: text)
        let hasPageNumbers = model.pages.contains { !$0.pageNumbers.isEmpty }
        var warnings: [PDFRenderWarning] = []
        var physical: [PhysicalPage] = []
        // PageNumbers are measured with a sample page/total; when the real total has more
        // digits the document is laid out again so the reserved space fits the text.
        for _ in 0..<3 {
            warnings = []
            physical = try paginate(model, engine: engine, maxPages: maxPages, warnings: &warnings)
            let needed = physical.count
            guard hasPageNumbers, String(needed).count > String(engine.pageNumberSample).count else { break }
            engine.pageNumberSample = needed
        }
        let drawer = PDFDrawer(text: text)
        var (data, report) = try drawer.draw(physical, document: model)
        var formFields: [PDFFormFieldInfo] = []
        if model.form.isEmpty {
            data = AcroFormWriter.repairingXref(data) ?? data
        } else {
            do {
                let output = try AcroFormWriter(form: model.form, placements: drawer.placements).write(into: data)
                data = output.data
                // Only fields that exist in the PDF (a field cut off by the page limit or
                // an empty radio group has no widget and is not written).
                formFields = model.form.fields.filter { output.emittedFieldIDs.contains($0.id) }.map(\.info)
            } catch {
                warnings.append(.formUnavailable)
            }
        }
        return Output(data: data, pages: report, warnings: warnings, formFields: formFields)
    }

    /// The largest share of a page's height a page-number footer may reserve.
    static let maxFooterFraction: CGFloat = 0.25

    private static func paginate(
        _ model: DocumentModel, engine: LayoutEngine, maxPages: Int, warnings: inout [PDFRenderWarning]
    ) throws -> [PhysicalPage] {
        var physical: [PhysicalPage] = []
        for page in model.pages {
            try Task.checkCancellation()
            guard physical.count < maxPages else {
                warnings.append(.pageLimitReached(limit: maxPages))
                break
            }
            var page = page
            // Reserve the footer: page numbers need their text height plus a 4 pt inset
            // above the page edge; a smaller bottom margin grows to fit (never overlapping content).
            // The reserve is capped at a quarter of the page; a taller footer is shrunk to fit.
            let width = max(page.size.width - page.margins.horizontal, 1)
            let cap = page.size.height * Self.maxFooterFraction
            func height(_ spec: PageNumberSpec) -> CGFloat {
                engine.text.lines(engine.sampleText(spec), spec.style, width: width).last.map { $0.y + $0.height } ?? 0
            }
            for index in page.pageNumbers.indices {
                let natural = height(page.pageNumbers[index])
                guard natural + 8 > cap else { continue }
                page.pageNumbers[index].style.fontSize *= max(cap - 8, 1) / natural
                if !warnings.contains(.contentClipped) { warnings.append(.contentClipped) }
            }
            let footer = page.pageNumbers.map(height).max() ?? 0
            page.footerHeight = footer > 0 ? min(footer + 8, cap) : 0
            let content = page.contentRect
            let laid = engine.layout(page.content, width: content.width, height: content.height)
            let result = try Paginator(pageHeight: content.height, maxPages: maxPages - physical.count).paginate(laid)
            physical += result.pages.map { PhysicalPage(page: page, content: $0) }
            if result.clipped, !warnings.contains(.contentClipped) { warnings.append(.contentClipped) }
            if result.truncated {
                warnings.append(.pageLimitReached(limit: maxPages))
                break
            }
        }
        return physical
    }
}
