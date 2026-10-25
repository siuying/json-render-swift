import Foundation

/// Something the renderer had to drop or limit. Rendering still succeeds.
public enum PDFRenderWarning: Sendable, Hashable, CustomStringConvertible {
    /// Elements nested deeper than `limit` levels were dropped.
    case nestingTooDeep(limit: Int)
    /// Elements beyond `limit` (after repeat expansion) were dropped.
    case tooManyElements(limit: Int)
    /// The document was cut off after `limit` pages.
    case pageLimitReached(limit: Int)
    /// Content too large for any page (e.g. an oversized empty box) was clipped, or a
    /// page-number footer taller than a quarter of the page was shrunk to fit.
    case contentClipped
    /// An image could not be loaded, decoded or exceeded a budget; a placeholder was drawn.
    case imageUnavailable(source: String)
    /// The fillable form could not be added; the PDF has the static field frames only.
    case formUnavailable

    public var description: String {
        switch self {
        case .nestingTooDeep(let limit): "Elements nested deeper than \(limit) levels were dropped."
        case .tooManyElements(let limit): "Elements beyond the first \(limit) were dropped."
        case .pageLimitReached(let limit): "The document was truncated after \(limit) pages."
        case .contentClipped: "Content taller than a page was clipped, or an oversized footer was shrunk."
        case .imageUnavailable(let source): "Image \"\(source.prefix(80))\" could not be loaded; drew a placeholder."
        case .formUnavailable: "The fillable form could not be written; fields are drawn but not interactive."
        }
    }
}

/// The output of ``PDFRenderer/renderResult(_:)``: PDF bytes plus what was limited.
public struct PDFRenderResult: Sendable {
    public var data: Data
    public var pageCount: Int
    public var warnings: [PDFRenderWarning]
    /// Fillable fields, in document order (empty when the spec has none).
    public var formFields: [PDFFormFieldInfo] = []

    /// The page limit cut the document short.
    public var isTruncated: Bool {
        warnings.contains { if case .pageLimitReached = $0 { true } else { false } }
    }
}
