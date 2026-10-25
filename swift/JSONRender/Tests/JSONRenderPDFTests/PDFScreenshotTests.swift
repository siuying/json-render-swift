import Foundation
import Testing
@testable import JSONRenderPDF
import JSONRenderSwiftUI

/// Writes PNGs of each fixture's first page (and first continuation page) to
/// `docs/screenshots/pdf/` for visual comparison with `fixtures/pdf/reference/*.png`.
/// Opt-in: `JSONRENDER_PDF_SCREENSHOTS=1 xcrun swift test --filter PDFScreenshots`.
@Suite("PDF screenshots", .enabled(if: ProcessInfo.processInfo.environment["JSONRENDER_PDF_SCREENSHOTS"] != nil))
struct PDFScreenshotTests {
    @Test(arguments: PDFFixtures.specNames)
    func screenshot(_ name: String) async throws {
        let directory = PDFFixtures.repositoryRoot.appendingPathComponent("docs/screenshots/pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pdf = try await PDFTestSupport.render(try PDFFixtures.spec(name))
        for page in 0..<min(pdf.pageCount, 2) {
            let png = try #require(PDFTestSupport.png(pdf.data, page: page))
            try png.write(to: directory.appendingPathComponent("\(name)-page\(page + 1).png"))
        }
        let pdfDirectory = ProcessInfo.processInfo.environment["JSONRENDER_PDF_OUTPUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try pdf.data.write(to: pdfDirectory.appendingPathComponent("jsonrender-\(name).pdf"))
    }
}
