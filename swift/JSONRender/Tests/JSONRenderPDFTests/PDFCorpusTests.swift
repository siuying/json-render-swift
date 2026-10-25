import CoreGraphics
import Foundation
import Testing
@testable import JSONRenderPDF
import JSONRenderSwiftUI

/// Renders every `*.json` spec in `$JSONRENDER_PDF_CORPUS` (e.g. a fuzz corpus) and checks
/// that each completes with finite geometry inside its pages. Opt-in.
@Suite("PDF corpus", .enabled(if: ProcessInfo.processInfo.environment["JSONRENDER_PDF_CORPUS"] != nil))
struct PDFCorpusTests {
    static let files: [URL] = {
        guard let path = ProcessInfo.processInfo.environment["JSONRENDER_PDF_CORPUS"] else { return [] }
        let directory = URL(fileURLWithPath: path)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".report.json") }.sorted()
            .map { directory.appendingPathComponent($0) }
    }()

    @Test(arguments: files)
    func corpusSpec(_ url: URL) async throws {
        let spec = Spec(json: try JSONValue(jsonData: Data(contentsOf: url)))
        let start = ContinuousClock.now
        let pdf = try await PDFTestSupport.render(spec)
        #expect(ContinuousClock.now - start < .seconds(5), "\(url.lastPathComponent) renders quickly")
        #expect(pdf.pageCount <= 500)
        for (index, page) in pdf.pages.enumerated() {
            let bounds = CGRect(origin: .zero, size: page.size).insetBy(dx: -0.5, dy: -0.5)
            for item in page.items {
                #expect(PDFDrawer.isFinite(item.rect), "\(url.lastPathComponent) p\(index + 1) \(item.kind)")
                #expect(bounds.contains(item.rect), "\(url.lastPathComponent) p\(index + 1) \(item.kind) \(item.rect)")
            }
        }
    }
}
