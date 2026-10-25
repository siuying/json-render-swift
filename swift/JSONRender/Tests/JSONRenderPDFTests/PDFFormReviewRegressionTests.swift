import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import JSONRenderPDF
import JSONRenderSwiftUI

/// Regressions from the fillable-forms review (docs/reviews/pdf-forms-review.md).
@Suite("PDF forms review regressions")
struct PDFFormReviewRegressionTests {
    static func spec(_ children: [String: JSONValue], order: [String], pageProps: JSONValue = [:]) -> Spec {
        var elements: [String: JSONValue] = [
            "doc": ["type": "Document", "children": ["page"]],
            "page": ["type": "Page", "props": pageProps, "children": .array(order.map(JSONValue.string))],
        ]
        elements.merge(children) { $1 }
        return Spec(json: ["root": "doc", "elements": .object(elements)])
    }

    // MARK: Host checks

    /// `qpdf --check` output on macOS (`nil` when qpdf is not installed or on iOS). iOS
    /// outputs are also written to `JSONRENDER_PDF_OUTPUT` for a host-side qpdf pass.
    static func qpdfCheck(_ data: Data, name: String) throws -> (status: Int32, output: String)? {
        if let directory = ProcessInfo.processInfo.environment["JSONRENDER_PDF_OUTPUT"] {
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).pdf"))
        }
        #if os(macOS)
        guard let qpdf = ["/opt/homebrew/bin/qpdf", "/usr/local/bin/qpdf", "/usr/bin/qpdf"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdf)
        process.arguments = ["--check", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        #else
        return nil
        #endif
    }

    static func expectClean(_ data: Data, name: String) throws {
        let structure = try PDFFileStructure(data: data)
        #expect(!structure.offsets.values.contains(0), "\(name): an object is in use at offset 0")
        if let (status, output) = try qpdfCheck(data, name: name) {
            #expect(status == 0 && !output.contains("WARNING"), "\(name): \(output)")
        }
    }

    /// A classic-xref PDF from object bodies (object `n` is `objects[n - 1]`); `zeroOffset`
    /// objects get an in-use xref entry at offset 0 and are not written.
    static func handcraftedPDF(_ objects: [String], zeroOffset: Set<Int> = []) -> Data {
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(out.utf8.count)
            if !zeroOffset.contains(index + 1) { out += "\(index + 1) 0 obj\n\(body)\nendobj\n" }
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for (index, offset) in offsets.enumerated() {
            out += String(format: "%010d 00000 n \n", zeroOffset.contains(index + 1) ? 0 : offset)
        }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(out.utf8)
    }

    // MARK: #1 reserved Off state

    @Test func offExportValuesRoundTrip() async throws {
        let spec = Self.spec([
            "r": ["type": "RadioGroup", "props": ["name": "r", "value": "Off",
                  "options": [["label": "Off", "value": "Off"], ["label": "On", "value": "On"]]]],
            "c": ["type": "Checkbox", "props": ["name": "c", "label": "Off?", "exportValue": "Off", "checked": true]],
        ], order: ["r", "c"])
        let result = try await PDFFormTests.render(spec)
        let (_, fields, _, document) = try PDFFormTests.fieldTree(result.data)
        defer { withExtendedLifetime(document) {} }
        let kids = try #require(fields["r"]?.array("Kids"))
        let states = (0..<kids.count).compactMap { kids.dict(at: $0)?.name("AS") }
        #expect(states == ["Off_1", "Off"], "the selected kid uses a mapped, non-reserved state")
        #expect(fields["r"]?.name("V") == "Off_1")
        #expect(fields["c"]?.name("V") == "Off_1" && fields["c"]?.name("AS") == "Off_1")

        let reader = try PDFFormReader(data: result.data)
        #expect(reader.values(for: result.formFields) == ["r": "Off", "c": true])

        // Choose "On" like a tap, save, read back.
        let pdf = try #require(PDFDocument(data: result.data))
        let widgets = pdf.page(at: 0)?.annotations.filter { $0.fieldName == "r" } ?? []
        try #require(widgets.first { $0.buttonWidgetStateString == "On" }).buttonWidgetState = .onState
        let saved = try #require(pdf.dataRepresentation())
        #expect(try PDFFormReader(data: saved).values(for: result.formFields)["r"] == "On")
        try Self.expectClean(result.data, name: "off-states")
    }

    @Test func buttonStateNamesAreUniqueAndNeverOff() {
        #expect(ButtonStates.names(for: ["a", "Off", "", "On", "Off_1"]) == ["a", "Off_1", "On", "On_1", "Off_1_1"])
        #expect(ButtonStates.checkboxOn(nil) == "Yes")
        #expect(ButtonStates.checkboxOn("Off") == "Off_1")
    }

    // MARK: #2 off appearances after a PDFKit save

    @Test func offAppearancesSurvivePDFKitSave() async throws {
        let result = try await PDFFormTests.applicationForm()
        let (_, fields, _, document) = try PDFFormTests.fieldTree(result.data)
        defer { withExtendedLifetime(document) {} }
        let normal = try #require(fields["declaration.creditCheck"]?.dict("AP")?.dict("N"))
        var stream: CGPDFStreamRef?
        #expect(CGPDFDictionaryGetStream(normal.ref, "Off", &stream))
        var format = CGPDFDataFormat.raw
        let content = try #require(stream.flatMap { CGPDFStreamCopyData($0, &format) }) as Data
        #expect(!content.isEmpty, "off appearance streams are not empty")

        let saved = try #require(PDFDocument(data: result.data)?.dataRepresentation())
        if let (status, output) = try Self.qpdfCheck(saved, name: "application-form-saved") {
            #expect(status == 0 && !output.contains("WARNING"), "\(output)")
        }
    }

    // MARK: #3 FieldSet vs terminal names

    @Test func fieldSetAndTerminalNamesNeverCollide() async throws {
        for order in [["a", "set"], ["set", "a"]] {
            let spec = Self.spec([
                "a": ["type": "TextInput", "props": ["name": "a", "value": "terminal"]],
                "set": ["type": "FieldSet", "props": ["name": "a"], "children": ["b"]],
                "b": ["type": "TextInput", "props": ["name": "b", "value": "nested"]],
            ], order: order)
            let result = try await PDFFormTests.render(spec)
            let names = result.formFields.map(\.name)
            #expect(Set(names).count == 2 && names.contains { $0.hasSuffix(".b") }, "\(order): \(names)")
            let (_, fields, _, document) = try PDFFormTests.fieldTree(result.data)
            #expect(Set(fields.keys) == Set(names), "\(order)")
            withExtendedLifetime(document) {}
            let values = try PDFFormReader(data: result.data).values(for: result.formFields)
            #expect(Set(values.values) == ["terminal", "nested"], "\(order)")
        }
    }

    // MARK: #4 unexpected value types

    static func formPDF(_ fields: [String]) -> Data {
        let first = 4
        let refs = fields.indices.map { "\(first + $0) 0 R" }.joined(separator: " ")
        return handcraftedPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [\(refs)] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>",
        ] + fields)
    }

    @Test func readerRejectsUnexpectedValueTypes() throws {
        let data = Self.formPDF([
            "<< /T (text) /FT /Tx /V 42 >>",
            "<< /T (consent) /FT /Btn /V /Unrecognized /AS /Unrecognized >>",
            "<< /T (list) /FT /Ch /Ff 2097152 /V 7 >>",
            "<< /T (choice) /FT /Ch /V (zz) >>",
            "<< /T (ok) /FT /Btn /V /Yes >>",
        ])
        let fields = [
            PDFFormFieldInfo(name: "text", type: .textInput, pointer: "/user/text"),
            PDFFormFieldInfo(name: "consent", type: .checkbox, pointer: "/user/consent", exportValue: "Yes"),
            PDFFormFieldInfo(name: "list", type: .listBox, pointer: "/user/list", options: [.init(label: "A", value: "a")],
                             allowsMultipleSelection: true),
            PDFFormFieldInfo(name: "choice", type: .select, pointer: "/user/choice", options: [.init(label: "A", value: "a")]),
            PDFFormFieldInfo(name: "ok", type: .checkbox, pointer: "/user/ok", exportValue: "Yes"),
        ]
        let reader = try PDFFormReader(data: data)
        let values = reader.values(for: fields)
        #expect(values == ["ok": true], "\(values) raw: \(reader.entries)")
        let updates = PDFFormReader.stateUpdates(values, fields: fields)
        #expect(updates.map(\.pointer) == ["/user/ok"])
    }

    // MARK: #5 bounded traversal

    @Test func readerTraversalIsBounded() throws {
        // 1,000 parents share one 10,000-entry kids array (10M inspections unbounded).
        let parents = 1_000
        let kidsObject = 4 + parents, child = 5 + parents
        let kids = "[" + String(repeating: "\(child) 0 R ", count: 10_000) + "]"
        let refs = (0..<parents).map { "\(4 + $0) 0 R" }.joined(separator: " ")
        let data = Self.handcraftedPDF([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [\(refs)] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>",
        ] + (0..<parents).map { "<< /T (p\($0)) /Kids \(kidsObject) 0 R >>" } + [kids, "<< /T (c) >>"])
        #expect(kidsObject == 1_004 && data.count < 200_000)
        let clock = ContinuousClock()
        var values: [String: JSONValue] = ["unread": true]
        let elapsed = try clock.measure { values = try PDFFormReader(data: data).values() }
        #expect(values.isEmpty)
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    // MARK: #6 formFields lists written fields only

    @Test func formFieldsListOnlyWrittenFields() async throws {
        var children: [String: JSONValue] = [:]
        var order: [String] = []
        for index in 0..<200 {
            children["t\(index)"] = ["type": "TextInput", "props": ["name": .string("t\(index)")]]
            order.append("t\(index)")
        }
        children["empty"] = ["type": "RadioGroup", "props": ["name": "empty", "options": []]]
        order.insert("empty", at: 0)
        let renderer = PDFRenderer(options: .init(imageLoader: .placeholders, maxPages: 1))
        let result = try await renderer.renderResult(Self.spec(children, order: order))
        #expect(result.isTruncated)
        let (_, fields, _, document) = try PDFFormTests.fieldTree(result.data)
        defer { withExtendedLifetime(document) {} }
        #expect(!result.formFields.isEmpty && result.formFields.count < 200)
        #expect(Set(result.formFields.map(\.name)) == Set(fields.keys))
        #expect(!result.formFields.contains { $0.name == "empty" })
    }

    // MARK: #7 oversized footer

    @Test func oversizedFooterKeepsContent() async throws {
        let spec = Self.spec([
            "field": ["type": "TextInput", "props": ["name": "field", "label": "Name"]],
            "pn": ["type": "PageNumber", "props": ["fontSize": 500, "format": .string(String(repeating: "Footer ", count: 30))]],
        ], order: ["field", "pn"])
        let output = try await PDFRenderer(options: .init(imageLoader: .placeholders)).renderWithReport(spec)
        #expect(output.pages.count == 1)
        #expect(output.warnings.contains(.contentClipped))
        #expect(output.formFields.map(\.name) == ["field"])
        let (_, fields, _, document) = try PDFFormTests.fieldTree(output.data)
        #expect(fields.keys.sorted() == ["field"])
        withExtendedLifetime(document) {}
        let page = try #require(output.pages.first)
        let footer = try #require(page.items.first { $0.kind == .pageNumber })
        let widget = try #require(page.items.first { $0.kind == .formWidget })
        #expect(footer.rect.minY >= 0 && footer.rect.maxY <= page.size.height, "\(footer.rect)")
        #expect(footer.rect.minY >= page.size.height * 0.75 - 0.5, "reserve capped at a quarter page: \(footer.rect)")
        #expect(widget.rect.maxY <= footer.rect.minY)
    }

    // MARK: Core Graphics xref repair

    @Test func zeroOffsetXrefSlotsAreFreed() throws {
        // Object 4 is in use at offset 0 and unreferenced (as iOS CG writes with CJK text);
        // object 5 is at offset 0 too but referenced, so it must stay.
        let base = Self.handcraftedPDF([
            "<< /Type /Catalog /Pages 2 0 R /Extra 5 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>",
            "<< >>",
            "<< >>",
        ], zeroOffset: [4, 5])
        #expect(try PDFFileStructure(data: base).unreferencedZeroOffsetObjects() == [4])
        let repaired = try #require(AcroFormWriter.repairingXref(base))
        #expect(repaired.prefix(base.count) == base, "an incremental update")
        let structure = try PDFFileStructure(data: repaired)
        #expect(structure.offsets[4] == nil && structure.offsets[5] == 0)
        #expect(String(decoding: repaired.suffix(from: base.count), as: UTF8.self).contains("0 1\n0000000004 65535 f \n4 1\n0000000000 00001 f \n"))
        #expect(CGPDFDocument(CGDataProvider(data: repaired as CFData)!)?.numberOfPages == 1)
        #expect(AcroFormWriter.repairingXref(Self.handcraftedPDF(["<< /Type /Catalog /Pages 2 0 R >>",
                                                                  "<< /Type /Pages /Kids [] /Count 0 >>"])) == nil,
                "nothing to repair: no update")
    }

    @Test func cjkDocumentsHaveCleanXref() async throws {
        let plain = Self.spec(["t": ["type": "Text", "props": ["text": "漢字 かな 한글"]]], order: ["t"])
        try Self.expectClean(try await PDFFormTests.render(plain).data, name: "cjk-static")
        let form = Self.spec([
            "t": ["type": "Text", "props": ["text": "申込書"]],
            "f": ["type": "TextInput", "props": ["name": "名前", "label": "氏名", "value": "山田"]],
        ], order: ["t", "f"])
        let result = try await PDFFormTests.render(form)
        #expect(result.formFields.count == 1)
        try Self.expectClean(result.data, name: "cjk-form")
    }

    // MARK: Option labels

    @Test func optionLabelsKeepTheirNaturalWidth() async throws {
        let spec = Self.spec([
            "r": ["type": "RadioGroup", "props": ["name": "r", "direction": "horizontal",
                  "options": [["label": "Yes", "value": "y"], ["label": "No", "value": "n"], ["label": "Maybe", "value": "m"]]]],
            "c": ["type": "Checkbox", "props": ["name": "c", "label": "Yes"]],
        ], order: ["r", "c"])
        let rendered = try await PDFTestSupport.render(spec)
        let texts = rendered.items(.text).compactMap(\.item.text)
        #expect(texts.filter { $0 == "Yes" }.count == 2, "\(texts)")
        #expect(texts.contains("No") && texts.contains("Maybe"))
        #expect(!texts.contains { $0.hasSuffix("-") }, "\(texts)")
    }

    @Test func multiSelectListWritesEverySelection() async throws {
        let spec = Self.spec([
            "l": ["type": "ListBox", "props": ["name": "l", "multiSelect": true, "value": ["a", "c"],
                  "options": [["label": "A", "value": "a"], ["label": "B", "value": "b"], ["label": "C", "value": "c"]]]],
        ], order: ["l"])
        let result = try await PDFFormTests.render(spec)
        let (_, fields, _, document) = try PDFFormTests.fieldTree(result.data)
        defer { withExtendedLifetime(document) {} }
        let list = try #require(fields["l"])
        #expect(list.array("V")?.count == 2 && list.array("I")?.count == 2)
        var stream: CGPDFStreamRef?
        #expect(CGPDFDictionaryGetStream(try #require(list.dict("AP")).ref, "N", &stream))
        var format = CGPDFDataFormat.raw
        let content = String(decoding: try #require(stream.flatMap { CGPDFStreamCopyData($0, &format) }) as Data, as: UTF8.self)
        #expect(content.components(separatedBy: "0.6 0.75 0.85 rg").count - 1 == 2, "two highlighted rows")
        #expect(try PDFFormReader(data: result.data).values(for: result.formFields)["l"] == ["a", "c"])
    }
}
