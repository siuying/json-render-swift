import Foundation
import JSONRenderPDF
import JSONRenderSwiftUI
import Observation
import PDFKit

/// The rendered document of a workspace. Holds the `PDFDocument` the preview shows, so the
/// user's edits to form fields survive tab switches and can be read back.
///
/// Renders only when the spec or the document revision changes; while a stream runs, at most
/// every ``throttle`` (trailing edge), so partial documents appear without rendering every
/// patch. Every request supersedes earlier ones: a slow, older render never replaces a newer
/// document (or the user's edits to it).
@MainActor
@Observable
final class PDFPreviewModel {
    static let throttle: Duration = .milliseconds(500)

    /// What a "Read filled values" pass found.
    struct FilledValues: Equatable {
        /// Validated values by field name.
        var values: [String: JSONValue]
        /// `(pointer, value)` for fields bound to state.
        var updates: [StateUpdate]
        /// Filled-in fields (non-empty text, checked boxes, selections) with no state binding.
        var unboundFields: [String]

        var json: JSONValue { .object(values) }
    }

    struct StateUpdate: Equatable {
        var pointer: String
        var value: JSONValue
    }

    private(set) var document: PDFDocument?
    /// The spec ``document`` was rendered from.
    private(set) var renderedSpec: Spec?
    /// The document revision ``document`` was rendered for (see ``GenerationController/revision``).
    private(set) var renderedRevision: Int?
    /// Fillable fields of ``document`` (empty when it has none).
    private(set) var formFields: [PDFFormFieldInfo] = []
    private(set) var renderError: String?

    @ObservationIgnored private var lastRender: ContinuousClock.Instant?
    /// Incremented by every request; a render publishes only if it is still the latest.
    @ObservationIgnored private var latestRequest = 0
    @ObservationIgnored private let options: PDFRenderer.Options

    init(options: PDFRenderer.Options = PDFRenderer.Options()) {
        self.options = options
    }

    var hasForm: Bool { !formFields.isEmpty }

    /// Whether the preview currently shows exactly this spec and revision.
    func isShowing(_ spec: Spec?, revision: Int) -> Bool {
        document != nil && spec == renderedSpec && revision == renderedRevision
    }

    /// Renders `spec` unless it is already shown for `revision` (which keeps the user's edits).
    /// Call from a `.task(id:)` keyed by spec, revision and streaming state.
    func show(_ spec: Spec?, revision: Int = 0, isStreaming: Bool) async {
        latestRequest += 1
        let request = latestRequest
        if spec == renderedSpec, revision == renderedRevision { return }
        guard let spec else {
            clearDocument()
            return
        }
        if isStreaming, let lastRender {
            let wait = Self.throttle - (ContinuousClock.now - lastRender)
            if wait > .zero {
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
            }
        }
        do {
            let result = try await PDFRenderer(options: options).renderResult(spec)
            try Task.checkCancellation()
            guard let rendered = PDFDocument(data: result.data) else { throw PreviewError.unreadable }
            // A newer request (another spec, a reset, or this spec already shown) wins.
            guard request == latestRequest else { return }
            document = rendered
            formFields = result.formFields
            renderedSpec = spec
            renderedRevision = revision
            renderError = nil
            lastRender = .now
        } catch is CancellationError {
            return
        } catch {
            if request == latestRequest { renderError = error.localizedDescription }
        }
    }

    /// Drops the document (and its edits) and invalidates pending renders.
    func reset() {
        latestRequest += 1
        clearDocument()
    }

    private func clearDocument() {
        document = nil
        renderedSpec = nil
        renderedRevision = nil
        formFields = []
        renderError = nil
    }

    /// The export for `spec`: a snapshot of the shown document (with the user's edits) when it
    /// is current and fillable, otherwise a fresh render of the spec.
    func export(for spec: Spec, revision: Int = 0, fileSuffix: String = "") -> PDFExport {
        var export = PDFExport(spec: spec, fileSuffix: fileSuffix)
        if hasForm, isShowing(spec, revision: revision), let document {
            export.live = LivePDFDocument(document)
        }
        return export
    }

    /// Reads the current (possibly edited) values of the document's fields.
    func filledValues() throws -> FilledValues {
        guard let data = document?.dataRepresentation() else { throw PreviewError.noDocument }
        let reader = try PDFFormReader(data: data)
        let values = reader.values(for: formFields)
        let updates = PDFFormReader.stateUpdates(values, fields: formFields).map { StateUpdate(pointer: $0.pointer, value: $0.value) }
        let bound = Set(formFields.filter { $0.pointer != nil }.map(\.name))
        let unbound = values.filter { !bound.contains($0.key) && Self.isFilled($0.value) }.keys.sorted()
        return FilledValues(values: values, updates: updates, unboundFields: unbound)
    }

    private static func isFilled(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let text): !text.isEmpty
        case .bool(let isOn): isOn
        case .array(let items): !items.isEmpty
        case .null: false
        default: true
        }
    }

    /// Sets text widgets by field name, as if the user typed (screenshots and tests).
    func fill(_ values: [String: String]) {
        guard let document else { return }
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.widgetFieldType == .text {
                let name = annotation.fieldName ?? ""
                if let value = values.first(where: { name == $0.key || $0.key.hasSuffix(".\(name)") || name.hasSuffix(".\($0.key)") })?.value {
                    annotation.widgetStringValue = value
                }
            }
        }
    }

    enum PreviewError: LocalizedError {
        case unreadable, noDocument

        var errorDescription: String? {
            switch self {
            case .unreadable: "The rendered PDF could not be opened."
            case .noDocument: "There is no document to read."
            }
        }
    }
}
