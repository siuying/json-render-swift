import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import JSONRenderPDF
import JSONRenderSwiftUI

@Suite("PDF fixtures")
struct PDFFixtureTests {
    @Test func fixturesPresent() {
        #expect(Set(PDFFixtures.specNames).isSuperset(of: ["invoice", "letter", "report", "resume", "statement"]))
    }

    @Test("every fixture renders within page bounds", arguments: PDFFixtures.specNames)
    func rendersWithinBounds(_ name: String) async throws {
        let pdf = try await PDFTestSupport.render(try PDFFixtures.spec(name))
        #expect(pdf.pageCount >= 1)
        #expect(pdf.pages.count == pdf.pageCount)
        for (index, page) in pdf.pages.enumerated() {
            let bounds = CGRect(origin: .zero, size: page.size).insetBy(dx: -0.5, dy: -0.5)
            for item in page.items {
                #expect(bounds.contains(item.rect), "\(name) page \(index + 1): \(item.kind) \(item.key ?? "") \(item.rect)")
            }
            #expect(!page.items.isEmpty, "\(name) page \(index + 1) draws something")
        }
        #expect(!pdf.allText.isEmpty)
    }

    @Test func invoiceTextPagesAndMetadata() async throws {
        let pdf = try await PDFTestSupport.render(try PDFFixtures.spec("invoice"))
        #expect(pdf.pageCount == 1)
        let text = pdf.allText
        for expected in ["Acme Corp", "Invoice #1042", "Due: March 19, 2026", "billing@acmecorp.com", "1 / 1"] {
            #expect(text.contains(expected), "\(expected)")
        }
        let attributes = pdf.document.documentAttributes ?? [:]
        #expect(attributes[PDFDocumentAttribute.titleAttribute] as? String == "Invoice #1042")
        #expect(attributes[PDFDocumentAttribute.authorAttribute] as? String == "Acme Corp")
    }

    @Test func statementRepeatsRowsAcrossPages() async throws {
        let spec = try PDFFixtures.spec("statement")
        let pdf = try await PDFTestSupport.render(spec)
        #expect(pdf.pageCount >= 2, "multi-page flow")
        // Whitespace-insensitive: PDFKit before OS 27 inserts spaces between tightly kerned
        // glyphs when extracting text ("ST A TEMENT"); the drawn text is identical.
        let text = pdf.allText.filter { !$0.isWhitespace }
        #expect(text.contains("NorthwindBank"))
        #expect(text.contains("ACCOUNTSTATEMENT"))
        // Every transaction description from state appears once per row.
        let accounts = spec.state?["accounts"]?.arrayValue ?? []
        let descriptions = accounts.flatMap { $0["transactions"]?.arrayValue ?? [] }.compactMap { $0["description"]?.stringValue }
        #expect(descriptions.count > 20)
        for description in Set(descriptions) {
            #expect(text.contains(description.filter { !$0.isWhitespace }), "\(description)")
        }
        for page in 1...pdf.pageCount {
            #expect(pdf.text(page: page - 1).contains("Page \(page) of \(pdf.pageCount)"))
        }
        // The overdue banner is hidden by `visible` (overdue: false).
        #expect(!text.contains("past due"))
        let metadata = pdf.document.documentAttributes ?? [:]
        #expect(metadata[PDFDocumentAttribute.titleAttribute] as? String == "Statement - March 1 - March 31, 2025")
    }

    @Test func linksBecomeAnnotations() async throws {
        let spec = Spec(json: [
            "root": "doc",
            "elements": [
                "doc": ["type": "Document", "props": ["title": "Links"], "children": ["page"]],
                "page": ["type": "Page", "props": [:], "children": ["link"]],
                "link": ["type": "Link", "props": ["text": "Visit example.com", "href": "https://example.com/path"]],
            ],
        ])
        let pdf = try await PDFTestSupport.render(spec)
        let annotations = pdf.document.page(at: 0)?.annotations ?? []
        let urls = annotations.compactMap { $0.url ?? ($0.action as? PDFActionURL)?.url }
        #expect(urls.contains(URL(string: "https://example.com/path")!))
        let link = try #require(pdf.items(.link).first?.item)
        let annotation = try #require(annotations.first)
        let pageHeight = pdf.pages[0].size.height
        #expect(abs(annotation.bounds.minX - link.rect.minX) < 1)
        #expect(abs(annotation.bounds.maxY - (pageHeight - link.rect.minY)) < 1, "annotation sits on the link text")
        #expect(pdf.allText.contains("Visit example.com"))
    }
}

@Suite("PDF layout")
struct PDFLayoutTests {
    static func document(_ elements: [String: JSONValue], page: [String: JSONValue] = [:], state: JSONValue? = nil) -> Spec {
        var pageProps = page
        pageProps["size"] = pageProps["size"] ?? "A4"
        var all: [String: JSONValue] = [
            "doc": ["type": "Document", "props": [:], "children": ["page"]],
            "page": ["type": "Page", "props": .object(pageProps), "children": .array(elements.keys.filter { !$0.contains(".") }.sorted().map(JSONValue.string))],
        ]
        for (key, value) in elements { all[key.replacingOccurrences(of: ".", with: "")] = value }
        var json: [String: JSONValue] = ["root": "doc", "elements": .object(all)]
        if let state { json["state"] = state }
        return Spec(json: .object(json))
    }

    @Test func pageNumbersAndPagination() async throws {
        let paragraph = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 40)
        var elements: [String: JSONValue] = ["zz-number": ["type": "PageNumber", "props": [:]]]
        for index in 0..<8 {
            elements["p\(index)"] = ["type": "Text", "props": ["text": .string("Paragraph \(index). " + paragraph)]]
        }
        let pdf = try await PDFTestSupport.render(Self.document(elements))
        #expect(pdf.pageCount >= 3)
        let numbers = pdf.items(.pageNumber)
        #expect(numbers.count == pdf.pageCount)
        for (page, item) in numbers {
            let size = pdf.pages[page].size
            #expect(item.text == "\(page + 1) / \(pdf.pageCount)")
            // A footer: inside the 40 pt bottom margin, centred on the content area.
            #expect(item.rect.minY >= size.height - 40 && item.rect.maxY <= size.height)
            #expect(abs(item.rect.midX - size.width / 2) < 0.5)
        }
        // Paragraphs split at line boundaries: text continues on the next page.
        let pageTexts = (0..<pdf.pageCount).map { pdf.text(page: $0) }
        #expect(pageTexts.allSatisfy { !$0.isEmpty })
        // No text line crosses the bottom margin.
        for (index, page) in pdf.pages.enumerated() {
            for item in page.items where item.kind == .text {
                #expect(item.rect.maxY <= page.size.height - 40 + 0.5, "page \(index + 1) \(item.rect)")
            }
        }
    }

    @Test("page number alignment", arguments: ["left", "center", "right"])
    func pageNumberAlignment(_ align: String) async throws {
        let spec = Self.document([
            "a-number": ["type": "PageNumber", "props": ["align": .string(align), "format": "Page {pageNumber}"]],
            "b-text": ["type": "Text", "props": ["text": "Body"]],
        ])
        let pdf = try await PDFTestSupport.render(spec)
        let number = try #require(pdf.items(.pageNumber).first?.item)
        let size = pdf.pages[0].size
        #expect(number.text == "Page 1")
        #expect(number.rect.minY >= size.height - 40, "in the bottom margin, not at its tree position")
        switch align {
        case "left": #expect(abs(number.rect.minX - 40) < 0.5)
        case "right": #expect(abs(number.rect.maxX - (size.width - 40)) < 0.5)
        default: #expect(abs(number.rect.midX - size.width / 2) < 0.5)
        }
        let body = try #require(pdf.items(.text).first { $0.item.text == "Body" }?.item)
        #expect(abs(body.rect.minY - 40) < 0.5, "the page number takes no flow space")
    }

    @Test func smallBottomMarginGrowsTheFooterInsteadOfOverlapping() async throws {
        var elements: [String: JSONValue] = ["zz-number": ["type": "PageNumber", "props": ["fontSize": 12]]]
        let paragraph = String(repeating: "Lorem ipsum dolor sit amet. ", count: 200)
        for index in 0..<4 { elements["p\(index)"] = ["type": "Text", "props": ["text": .string(paragraph)]] }
        let pdf = try await PDFTestSupport.render(Self.document(elements, page: ["marginBottom": 2]))
        for (index, page) in pdf.pages.enumerated() {
            let number = try #require(page.items.first { $0.kind == .pageNumber })
            #expect(number.rect.maxY <= page.size.height - 3.9, "at least a 4 pt inset from the edge")
            let lowestText = page.items.filter { $0.kind == .text }.map(\.rect.maxY).max() ?? 0
            #expect(lowestText <= number.rect.minY + 0.5, "page \(index + 1): content stays above the footer")
        }
    }

    @Test func tableHeaderRepeatsOnContinuationPages() async throws {
        let rows: [JSONValue] = (1...120).map { .array([.string("Item \($0)"), .string("\($0)"), .string("$\($0).00")]) }
        let spec = Self.document([
            "table": ["type": "Table", "props": [
                "columns": [["header": "Description", "width": "60%"], ["header": "Qty", "width": "15%", "align": "right"],
                            ["header": "Amount", "width": "25%", "align": "right"]],
                "rows": .array(rows), "striped": true,
            ]],
        ])
        let pdf = try await PDFTestSupport.render(spec)
        #expect(pdf.pageCount >= 3)
        for page in 0..<pdf.pageCount {
            let text = pdf.text(page: page)
            #expect(text.contains("Description") && text.contains("Amount"), "header on page \(page + 1)")
        }
        let all = pdf.allText
        for index in [1, 60, 120] { #expect(all.contains("Item \(index)")) }
        // Rows never split: every row's cells sit on one page (row boxes stay within content).
        for (index, page) in pdf.pages.enumerated() {
            for item in page.items where item.kind == .box && item.key?.contains("#row") == true {
                #expect(item.rect.maxY <= page.size.height - 40 + 0.5, "row on page \(index + 1)")
            }
        }
    }

    @Test func repeatDrivesRowsFromState() async throws {
        let spec = Self.document([
            "list": ["type": "Column", "props": ["gap": 4], "repeat": ["statePath": "/people", "key": "id"], "children": ["name"]],
            ".name": ["type": "Text", "props": ["text": ["$template": "${name} #${/company}"],
                                                "fontWeight": ["$cond": ["$index": true, "eq": 0], "$then": "bold", "$else": "normal"]]],
        ], state: ["company": "Acme", "people": [["id": "1", "name": "Ada"], ["id": "2", "name": "Grace"], ["id": "3", "name": "Linus"]]])
        let pdf = try await PDFTestSupport.render(spec, state: ["company": "Initech"])
        let lines = pdf.items(.text).compactMap(\.item.text)
        #expect(lines == ["Ada #Initech", "Grace #Initech", "Linus #Initech"], "options.state overrides spec.state")
    }

    @Test func rowFlexAndJustify() async throws {
        let spec = Self.document([
            "row": ["type": "Row", "props": ["gap": 10, "justifyContent": "space-between"], "children": ["left", "right"]],
            ".left": ["type": "Text", "props": ["text": "Left"]],
            ".right": ["type": "Text", "props": ["text": "Right"]],
            "flex": ["type": "Row", "props": ["gap": 20], "children": ["a", "b"]],
            ".a": ["type": "View", "props": ["flex": 1, "backgroundColor": "#eeeeee"], "children": ["at"]],
            ".b": ["type": "View", "props": ["flex": 3, "backgroundColor": "#dddddd"], "children": ["bt"]],
            ".at": ["type": "Text", "props": ["text": "A"]],
            ".bt": ["type": "Text", "props": ["text": "B"]],
        ])
        let pdf = try await PDFTestSupport.render(spec)
        let page = pdf.pages[0]
        let content = CGRect(x: 40, y: 40, width: page.size.width - 80, height: page.size.height - 80)
        let texts = Dictionary(page.items.filter { $0.kind == .text }.map { ($0.text ?? "", $0.rect) }) { first, _ in first }
        #expect(abs(texts["Left"]!.minX - content.minX) < 0.5)
        #expect(abs(texts["Right"]!.maxX - content.maxX) < 0.5, "space-between pushes the last child to the end")
        let boxes = page.items.filter { $0.kind == .box }.map(\.rect).sorted { $0.minX < $1.minX }
        #expect(boxes.count == 2)
        #expect(abs(boxes[0].width * 3 - boxes[1].width) < 0.5, "flex 1 : 3")
        #expect(abs(boxes[0].width + boxes[1].width + 20 - content.width) < 0.5)
    }

    @Test func imagesLoadOrFallBackToPlaceholders() async throws {
        let png = PDFTestSupport.samplePNG
        let spec = Self.document([
            "a-ok": ["type": "Image", "props": ["src": "https://images.example/ok.png", "width": 80]],
            "b-broken": ["type": "Image", "props": ["src": "https://images.example/missing.png", "width": 120, "height": 60]],
            "c-data": ["type": "Image", "props": ["src": .string("data:image/png;base64," + png.base64EncodedString()), "height": 30]],
        ])
        let loader = PDFImageLoader { source in
            if source.hasSuffix("ok.png") { return png }
            if let data = PDFImageLoader.dataURL(source) { return data }
            throw URLError(.fileDoesNotExist)
        }
        let pdf = try await PDFTestSupport.render(spec, loader: loader)
        let images = pdf.items(.image).map(\.item)
        let placeholders = pdf.items(.imagePlaceholder).map(\.item)
        #expect(images.count == 2)
        #expect(placeholders.count == 1)
        #expect(placeholders.first?.rect.size == CGSize(width: 120, height: 60))
        let ok = try #require(images.first { $0.text?.hasSuffix("ok.png") == true })
        #expect(ok.rect.size == CGSize(width: 80, height: 40), "height from the 2:1 aspect ratio")
        let dataImage = try #require(images.first { $0.text?.hasPrefix("data:") == true })
        #expect(dataImage.rect.size == CGSize(width: 60, height: 30))
    }

    @Test func partialAndMalformedSpecsRender() async throws {
        let partials: [JSONValue] = [
            [:],
            ["root": "doc"],
            ["root": "doc", "elements": ["doc": ["type": "Document", "children": ["page"]]]],
            ["root": "doc", "elements": ["doc": ["type": "Document", "children": ["page"]], "page": ["type": "Page", "props": ["size": "B9"], "children": ["t", "missing"]], "t": ["type": "Text"]]],
            ["root": "loop", "elements": ["loop": ["type": "Column", "children": ["loop"]]]],
            ["root": "doc", "elements": ["doc": ["type": "Text", "props": ["text": 42]]]],
            ["root": "t", "elements": ["t": ["type": "Table", "props": ["columns": "nope", "rows": [[1, nil], "x"]]]]],
            ["root": "i", "elements": ["i": ["type": "Image", "props": ["src": nil, "width": -5]]]],
        ]
        for json in partials {
            let pdf = try await PDFTestSupport.render(Spec(json: json))
            #expect(pdf.pageCount >= 1, "\(json)")
        }
    }

    @Test func streamingPrefixesRender() async throws {
        let bridge = try #require(PDFFixtures.bridge)
        let compiler = try await bridge.makeStreamCompiler()
        let text = try String(contentsOf: PDFFixtures.url("pdf/statement.jsonl"), encoding: .utf8)
        var lastPageCount = 0
        for (index, line) in text.split(separator: "\n").enumerated() {
            let update = try await compiler.push(line + "\n")
            if index % 3 == 0 {
                lastPageCount = try await PDFTestSupport.render(update.spec).pageCount
                #expect(lastPageCount >= 1)
            }
        }
        let final = try await compiler.finish()
        #expect(final == (try PDFFixtures.spec("statement")))
        _ = lastPageCount
    }
}
