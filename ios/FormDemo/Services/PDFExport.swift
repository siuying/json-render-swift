import CoreTransferable
import Foundation
import JSONRenderPDF
import JSONRenderSwiftUI
import PDFKit
import UniformTypeIdentifiers

/// A spec shared as a PDF file named after its `Document` title.
///
/// When a fillable preview of the spec is on screen, the file is a snapshot of that
/// document, so it contains what the user typed into its fields. Otherwise the spec is
/// rendered when the share sheet asks for the file.
struct PDFExport: Transferable {
    let spec: Spec
    /// Appended to the title in the file name (e.g. " (fillable)").
    var fileSuffix = ""
    /// The on-screen (possibly edited) document to snapshot instead of rendering.
    var live: LivePDFDocument?

    /// The resolved `Document.title` (may be a `$template`), or "Document".
    var title: String {
        let state = spec.state ?? .object([:])
        let title = spec.rootElement.flatMap { Expressions.resolve($0.props["title"], state: state)?.stringValue }
        return title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? "Document"
    }

    /// `title` made safe for a file name, with a `.pdf` extension.
    var fileName: String {
        let unsafe = CharacterSet(charactersIn: #"/\:?%*|"<>"#).union(.newlines).union(.controlCharacters)
        let cleaned = title.components(separatedBy: unsafe).joined(separator: "-")
        return String((cleaned + fileSuffix).prefix(120)) + ".pdf"
    }

    func render() async throws -> URL {
        let data: Data
        if let live, let snapshot = await live.snapshot() {
            data = snapshot
        } else {
            data = try await PDFRenderer().render(spec)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: fileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { export in
            SentTransferredFile(try await export.render())
        }
    }
}

/// A previewed `PDFDocument`, read on the main actor when exporting.
final class LivePDFDocument: @unchecked Sendable {
    // Only touched on the main actor (see `snapshot()`).
    private let document: PDFDocument

    init(_ document: PDFDocument) {
        self.document = document
    }

    func snapshot() async -> Data? {
        await MainActor.run { document.dataRepresentation() }
    }
}
