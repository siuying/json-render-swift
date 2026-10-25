import CoreGraphics
import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import JSONRenderPDF
import JSONRenderSwiftUI

/// Regression tests for docs/reviews/pdf-review.md findings 1–14 and 16.
@Suite("PDF review regressions")
struct PDFReviewRegressionTests {
    /// A Document with one A4 Page whose children are `pageChildren`; `extra` adds elements.
    static func spec(_ pageChildren: [String], page: [String: JSONValue] = [:], _ extra: [String: JSONValue]) -> Spec {
        var elements = extra
        elements["doc"] = ["type": "Document", "props": [:], "children": ["page"]]
        elements["page"] = ["type": "Page", "props": .object(page), "children": .array(pageChildren.map(JSONValue.string))]
        return Spec(json: ["root": "doc", "elements": .object(elements)])
    }

    static func text(_ string: String, _ props: [String: JSONValue] = [:]) -> JSONValue {
        var all = props
        all["text"] = .string(string)
        return ["type": "Text", "props": .object(all), "children": []]
    }

    /// Every drawn item is finite and inside its page.
    static func expectInBounds(_ pdf: RenderedPDF, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for (index, page) in pdf.pages.enumerated() {
            let bounds = CGRect(origin: .zero, size: page.size).insetBy(dx: -0.5, dy: -0.5)
            for item in page.items {
                #expect(PDFDrawer.isFinite(item.rect) && bounds.contains(item.rect),
                        "\(label) p\(index + 1): \(item.kind) \(item.rect)", sourceLocation: sourceLocation)
            }
        }
    }

    // 1
    @Test func deepNestingIsBoundedNotFatal() async throws {
        var elements: [String: JSONValue] = ["leaf": Self.text("Deep")]
        for level in 0..<1_000 {
            elements["c\(level)"] = ["type": "Column", "props": [:], "children": [.string(level == 999 ? "leaf" : "c\(level + 1)")]]
        }
        let spec = Self.spec(["c0"], elements)
        let result = try await PDFRenderer(options: .init(imageLoader: .placeholders)).renderResult(spec)
        #expect(result.pageCount == 1)
        #expect(result.warnings.contains(.nestingTooDeep(limit: SpecResolver.maxDepth)))
        let shallow = Self.spec(["c990"], elements) // 10 levels deep: renders fully
        #expect(try await PDFTestSupport.render(shallow).allText.contains("Deep"))
    }

    // 2
    @Test func oversizedEmptyBoxMakesProgress() async throws {
        let spec = Self.spec(["v"], ["v": ["type": "View", "props": ["padding": 1_000, "backgroundColor": "#ff0000"], "children": []]])
        let result = try await PDFRenderer(options: .init(imageLoader: .placeholders)).renderResult(spec)
        #expect(result.pageCount == 1)
        #expect(result.warnings.contains(.contentClipped))
        Self.expectInBounds(try await PDFTestSupport.render(spec), "oversized view")
    }

    @Test func pageLimitTruncatesWithWarning() async throws {
        let paragraph = String(repeating: "Lorem ipsum dolor sit amet. ", count: 400)
        var elements: [String: JSONValue] = [:]
        for index in 0..<10 { elements["t\(index)"] = Self.text(paragraph) }
        let spec = Self.spec((0..<10).map { "t\($0)" }, elements)
        let result = try await PDFRenderer(options: .init(imageLoader: .placeholders, maxPages: 3)).renderResult(spec)
        #expect(result.pageCount == 3)
        #expect(result.isTruncated)
    }

    // 3
    @Test func wrappedRowsPaginateByLine() async throws {
        var elements: [String: JSONValue] = [:]
        let cards = (0..<100).map { "v\($0)" }
        for card in cards {
            elements[card] = ["type": "View", "props": ["padding": 30, "borderWidth": 1], "children": [.string(card + "t")]]
            elements[card + "t"] = Self.text("Card \(card)")
        }
        elements["r"] = ["type": "Row", "props": ["wrap": true, "gap": 8], "children": .array(cards.map(JSONValue.string))]
        let pdf = try await PDFTestSupport.render(Self.spec(["r"], elements))
        #expect(pdf.pageCount >= 3, "25 visual lines of 83 pt break across pages")
        Self.expectInBounds(pdf, "wrapped row")
        let text = pdf.allText
        for card in ["Card v0", "Card v50", "Card v99"] { #expect(text.contains(card)) }
    }

    // 4
    @Test func defaultLoaderNeverReadsLocalFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jsonrender-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("red.png")
        try PDFTestSupport.samplePNG.write(to: file)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("jsonrender-outside-\(UUID().uuidString).png")
        try PDFTestSupport.samplePNG.write(to: outside)
        let spec = Self.spec(["a", "b"], [
            "a": ["type": "Image", "props": ["src": .string(file.absoluteString), "width": 40]],
            "b": ["type": "Image", "props": ["src": .string(outside.absoluteString), "width": 40]],
        ])
        let byDefault = try await PDFTestSupport.render(spec, loader: .default)
        #expect(byDefault.items(.image).isEmpty)
        #expect(byDefault.items(.imagePlaceholder).count == 2)
        let optedIn = try await PDFTestSupport.render(spec, loader: .files(in: directory))
        #expect(optedIn.items(.image).map(\.item.text) == [file.absoluteString], "only files inside the directory")
    }

    // 5
    @Test func lonelyGiantImageIsScaledToThePage() async throws {
        let png = PDFTestSupport.samplePNG
        let spec = Self.spec(["i"], ["i": ["type": "Image", "props": [
            "src": .string("data:image/png;base64," + png.base64EncodedString()), "width": 400, "height": 2_000,
        ]]])
        let pdf = try await PDFTestSupport.render(spec, loader: .default)
        #expect(pdf.pageCount == 1)
        let image = try #require(pdf.items(.image).first?.item)
        #expect(image.rect.height <= pdf.pages[0].size.height - 80 + 0.5)
        Self.expectInBounds(pdf, "giant image")
    }

    // 6
    @Test func tableRowTallerThanAPageSplitsUnderRepeatedHeader() async throws {
        let long = String(repeating: "word ", count: 2_000)
        let spec = Self.spec(["t"], ["t": ["type": "Table", "props": [
            "columns": [["header": "Header", "width": "100%"]], "rows": [[.string(long)], ["after"]],
        ]]])
        let pdf = try await PDFTestSupport.render(spec)
        #expect(pdf.pageCount >= 2)
        Self.expectInBounds(pdf, "giant row")
        for page in 0..<pdf.pageCount { #expect(pdf.text(page: page).contains("Header")) }
        #expect(pdf.allText.contains("after"))
    }

    // 7
    @Test func columnFlexAndJustifyUseTheDefiniteHeight() async throws {
        let spec = Self.spec(["v"], [
            "v": ["type": "Column", "props": ["flex": 1, "justifyContent": "space-between"], "children": ["a", "b"]],
            "a": Self.text("Top"), "b": Self.text("Bottom"),
        ])
        let pdf = try await PDFTestSupport.render(spec)
        let lines = Dictionary(pdf.items(.text).map { ($0.item.text ?? "", $0.item.rect) }) { first, _ in first }
        let contentBottom = pdf.pages[0].size.height - 40
        #expect(abs(try #require(lines["Top"]).minY - 40) < 0.5)
        #expect(abs(try #require(lines["Bottom"]).maxY - contentBottom) < 0.5)
    }

    // 8
    @Test func pageNumbersAreMeasuredWithTheRealTotal() async throws {
        let paragraph = String(repeating: "Lorem ipsum ", count: 300)
        var elements: [String: JSONValue] = [
            "r": ["type": "Row", "props": [:], "children": ["n"]],
            "n": ["type": "PageNumber", "props": [:]],
        ]
        var children: [String] = []
        for index in 0..<24 {
            elements["t\(index)"] = Self.text(paragraph)
            children.append("t\(index)")
        }
        let pdf = try await PDFTestSupport.render(Self.spec(children + ["r"], page: ["marginBottom": 0], elements))
        #expect(pdf.pageCount >= 10)
        let numbers = pdf.items(.pageNumber)
        #expect(numbers.count == pdf.pageCount, "one line per page")
        for (page, item) in numbers { #expect(item.text == "\(page + 1) / \(pdf.pageCount)") }
        Self.expectInBounds(pdf, "page numbers")
    }

    // 9
    @Test func zeroWidthColumnsDoNotPaintOverNeighbours() async throws {
        let spec = Self.spec(["t"], ["t": ["type": "Table", "props": [
            "columns": [["header": "WideHeader", "width": "0%"], ["header": "B", "width": "100%"]], "rows": [["Cell", "B"]],
        ]]])
        let pdf = try await PDFTestSupport.render(spec)
        let texts = pdf.items(.text).map(\.item)
        #expect(!texts.contains { $0.text?.contains("Wide") == true })
        for (index, a) in texts.enumerated() {
            for b in texts[(index + 1)...] { #expect(!a.rect.intersects(b.rect), "\(a.text ?? "") vs \(b.text ?? "")") }
        }
    }

    // 10
    @Test func extremeNumbersStayFiniteAndOnThePage() async throws {
        let cases: [Spec] = [
            Self.spec(["t"], ["t": Self.text("Huge", ["fontSize": 1e308])]),
            Self.spec(["v"], ["v": ["type": "View", "props": ["padding": 1e308, "margin": -1e308], "children": ["t"]], "t": Self.text("Padded")]),
            Self.spec(["t"], page: ["marginTop": -500, "marginLeft": -500, "marginBottom": 1e308], ["t": Self.text("Margins")]),
            Self.spec(["t"], ["t": ["type": "Table", "props": [
                "columns": [["header": "A", "width": "1e308%"], ["header": "B", "width": "NaN"]], "rows": [["x", "y"]],
            ]]]),
            Self.spec(["r"], ["r": ["type": "Row", "props": ["gap": 1e300, "flex": 1e300], "children": ["a", "b"]], "a": Self.text("a"), "b": Self.text("b")]),
        ]
        for (index, spec) in cases.enumerated() {
            Self.expectInBounds(try await PDFTestSupport.render(spec), "case \(index)")
        }
    }

    // 11
    @Test func imageDeadlineDoesNotWaitForUncooperativeLoaders() async throws {
        let loader = PDFImageLoader { _ in
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.resume() }
            }
            return PDFTestSupport.samplePNG
        }
        let start = ContinuousClock.now
        let batch = await loader.loadAll(["slow"], timeout: .milliseconds(50), limits: PDFImageLimits())
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(batch.failed == ["slow"])
    }

    // 12
    @Test func cancelledRendersStopEarly() async throws {
        let paragraph = String(repeating: "Lorem ipsum dolor sit amet. ", count: 4_000)
        let spec = Self.spec(["t"], ["t": Self.text(paragraph)])
        let task = Task { try await PDFRenderer(options: .init(imageLoader: .placeholders)).render(spec) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // 14
    @Test func imageBudgetsFallBackToPlaceholders() async throws {
        let png = PDFTestSupport.samplePNG
        let dataURL = "data:image/png;base64," + png.base64EncodedString()
        #expect(PDFImageLoader.dataURL(dataURL, maxBytes: 10) == nil, "oversized data: payloads are refused before decoding")
        #expect(PDFImageLoader.dataURL(dataURL) == png)

        let inFlight = Counter(), peak = Counter()
        let loader = PDFImageLoader { _ in
            let now = inFlight.increment()
            peak.raise(to: now)
            try await Task.sleep(for: .milliseconds(20))
            inFlight.decrement()
            return png
        }
        let sources = Set((0..<12).map { "img\($0)" })
        let limits = PDFImageLimits(maxBytesPerImage: png.count, maxTotalBytes: png.count * 5, maxPixelsPerImage: 800, maxConcurrentLoads: 3)
        let batch = await loader.loadAll(sources, timeout: .seconds(5), limits: limits)
        #expect(peak.value <= 3)
        #expect(batch.images.count == 5, "total byte budget")
        let pixels = await loader.loadAll(["one"], timeout: .seconds(5), limits: PDFImageLimits(maxPixelsPerImage: 100))
        #expect(pixels.failed == ["one"], "40×20 px exceeds a 100 px budget")
        let bytes = await loader.loadAll(["one"], timeout: .seconds(5), limits: PDFImageLimits(maxBytesPerImage: 10))
        #expect(bytes.failed == ["one"])
    }

    @Test func customLoadersCanFallBack() async throws {
        let png = PDFTestSupport.samplePNG
        let bundled = PDFImageLoader { source in
            guard source == "logo" else { throw URLError(.fileDoesNotExist) }
            return png
        }
        let loader = bundled.fallback(.default)
        let dataURL = "data:image/png;base64," + png.base64EncodedString()
        let batch = await loader.loadAll(["logo", dataURL, "ftp://example.com/x.png"], timeout: .seconds(5), limits: PDFImageLimits())
        #expect(batch.images.keys.sorted() == [dataURL, "logo"].sorted())
        #expect(batch.failed == ["ftp://example.com/x.png"])
    }

    // 16
    @Test func smallViewsMoveWholeLargeOnesFlow() async throws {
        let small = Self.spec(["s", "v"], [
            "s": ["type": "Spacer", "props": ["height": 740]],
            "v": ["type": "View", "props": ["backgroundColor": "#eeeeee"], "children": ["a", "b"]],
            "a": Self.text("Card heading"), "b": Self.text("Card body"),
        ])
        let pdf = try await PDFTestSupport.render(small)
        #expect(pdf.pageCount == 2)
        #expect(pdf.text(page: 1).contains("Card heading") && pdf.text(page: 1).contains("Card body"))

        var elements: [String: JSONValue] = ["s": ["type": "Spacer", "props": ["height": 600]]]
        var rows: [JSONValue] = []
        for index in 0..<40 {
            elements["l\(index)"] = Self.text("Line \(index)")
            rows.append(.string("l\(index)"))
        }
        elements["v"] = ["type": "View", "props": [:], "children": .array(rows)]
        let large = try await PDFTestSupport.render(Self.spec(["s", "v"], elements))
        #expect(large.text(page: 0).contains("Line 0"), "a View taller than a third of the page flows")
    }
}

/// Thread-safe counter for loader concurrency probes.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func increment() -> Int { lock.withLock { count += 1; return count } }
    func decrement() { lock.withLock { count -= 1 } }
    func raise(to candidate: Int) { lock.withLock { count = max(count, candidate) } }
}

// 13
@Suite("PDF preview invalidation")
@MainActor
struct PDFPreviewInvalidationTests {
    #if os(macOS)
    @Test func changingStateOptionsReRenders() async throws {
        let spec = PDFReviewRegressionTests.spec(["t"], ["t": ["type": "Text", "props": ["text": ["$state": "/name"]]]])
        let rendered = Recorder<String>()
        func view(_ name: String) -> some View {
            JSONRenderPDFView(spec: spec, options: .init(state: ["name": .string(name)], imageLoader: .placeholders))
                .onPDFRender { result in
                    if let data = try? result.get() { rendered.values.append(PDFDocument(data: data)?.string ?? "") }
                }
        }
        let host = NSHostingView(rootView: AnyView(view("FIRST")))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<200 where rendered.values.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        host.rootView = AnyView(view("SECOND"))
        host.layoutSubtreeIfNeeded()
        for _ in 0..<200 where rendered.values.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(rendered.values.first?.contains("FIRST") == true)
        #expect(rendered.values.last?.contains("SECOND") == true)
    }
    #endif
}
