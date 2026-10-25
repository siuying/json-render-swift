import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import JSONRenderPDF
import JSONRenderSwiftUI

@Suite("PDF forms")
struct PDFFormTests {
    static func render(_ spec: Spec) async throws -> PDFRenderResult {
        try await PDFRenderer(options: .init(imageLoader: .placeholders)).renderResult(spec)
    }

    static func applicationForm() async throws -> PDFRenderResult {
        try await render(try PDFFixtures.spec("application-form"))
    }

    // MARK: formFields parity

    static let parityCases: [JSONValue] = (try? PDFFixtures.json("parity/pdf-form-fields.json"))?["cases"]?.arrayValue ?? []

    @Test("formFields parity", arguments: parityCases.indices)
    func formFieldsParity(_ index: Int) async throws {
        let testCase = Self.parityCases[index]
        let result = try await Self.render(Spec(json: try #require(testCase["spec"])))
        let expected = testCase["expected"]?.arrayValue ?? []
        #expect(result.formFields.count == expected.count, "\(testCase["name"]?.stringValue ?? "")")
        for (field, want) in zip(result.formFields, expected) {
            #expect(field.name == want["name"]?.stringValue)
            #expect(field.type.rawValue == want["type"]?.stringValue)
            #expect((field.value ?? .null) == (want["value"] ?? .null), "\(field.name) value")
            #expect(field.pointer == want["pointer"]?.stringValue, "\(field.name) pointer")
            #expect(field.isRequired == (want["required"] == .bool(true)))
            #expect(field.isReadOnly == (want["readOnly"] == .bool(true)))
            if let options = want["options"]?.arrayValue {
                #expect(field.options.map { [$0.label, $0.value] } == options.map { [$0["label"]?.stringValue ?? "", $0["value"]?.javaScriptString ?? ""] })
            }
            if let multi = want["multiSelect"] { #expect(field.allowsMultipleSelection == (multi == .bool(true))) }
        }
    }

    // MARK: PDF dictionaries

    /// Fully qualified name → terminal field dictionary, from the catalog's field tree.
    /// Keeps the document alive while its dictionaries are used.
    static func fieldTree(_ data: Data) throws -> (acroForm: PDFDict, fields: [String: PDFDict], topLevel: Int, document: CGPDFDocument) {
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        let acroForm = try #require(PDFDict(document.catalog)?.dict("AcroForm"))
        let top = try #require(acroForm.array("Fields"))
        var fields: [String: PDFDict] = [:]
        func visit(_ node: PDFDict, prefix: String?) {
            let name = [prefix, node.text("T")].compactMap { $0 }.joined(separator: ".")
            var fieldKids: [PDFDict] = []
            if let kids = node.array("Kids") {
                for index in 0..<kids.count { if let kid = kids.dict(at: index), kid.text("T") != nil { fieldKids.append(kid) } }
            }
            if fieldKids.isEmpty { fields[name] = node } else { fieldKids.forEach { visit($0, prefix: name) } }
        }
        for index in 0..<top.count { if let field = top.dict(at: index) { visit(field, prefix: nil) } }
        return (acroForm, fields, top.count, document)
    }

    @Test func acroFormDictionaries() async throws {
        let result = try await Self.applicationForm()
        let (acroForm, fields, topLevel, document) = try Self.fieldTree(result.data)
        defer { withExtendedLifetime(document) {} }
        #expect(topLevel == 6, "six top-level FieldSets")
        #expect(fields.count == result.formFields.count)
        #expect(Set(fields.keys) == Set(result.formFields.map(\.name)))
        var needAppearances: CGPDFBoolean = 0
        #expect(CGPDFDictionaryGetBoolean(acroForm.ref, "NeedAppearances", &needAppearances) && needAppearances != 0)
        #expect(acroForm.dict("DR")?.dict("Font")?.dict("Helv")?.name("BaseFont") == "Helvetica")
        #expect(acroForm.dict("DR")?.dict("Font")?.dict("ZaDb")?.name("BaseFont") == "ZapfDingbats")
        #expect(acroForm.text("DA") == "/Helv 0 Tf 0 g")

        let first = try #require(fields["applicant.firstName"])
        #expect(first.name("FT") == "Tx" && first.text("V") == "Jane" && first.int("Ff") == 2)
        #expect(first.name("Subtype") == "Widget" && first.int("F") == 4 && first.dict("P") != nil)
        #expect(first.text("DA")?.hasPrefix("/Helv") == true)
        #expect(first.dict("AP")?.dict("N") != nil || first.dict("AP") != nil)
        let ssn = try #require(fields["applicant.ssnLast4"])
        #expect(ssn.int("Ff") == 8192 && ssn.int("MaxLen") == 4)
        #expect(fields["household.petDetails"]?.int("Ff") == 4096)
        #expect(fields["employment.monthlyIncome"]?.int("Q") == 2)

        let state = try #require(fields["applicant.address.state"])
        #expect(state.name("FT") == "Ch" && state.int("Ff") == (131_072 | 2) && state.text("V") == "OR")
        let options = try #require(state.array("Opt"))
        var pair: CGPDFArrayRef?
        #expect(CGPDFArrayGetArray(options.ref, 1, &pair))
        var export: CGPDFStringRef?, label: CGPDFStringRef?
        #expect(CGPDFArrayGetString(pair!, 0, &export) && CGPDFArrayGetString(pair!, 1, &label))
        #expect(CGPDFStringCopyTextString(export!) as String? == "OR" && CGPDFStringCopyTextString(label!) as String? == "Oregon")
        #expect(fields["employment.incomeSources"]?.int("Ff") == 2_097_152)
        #expect(fields["employment.incomeSources"]?.array("V")?.count == 2)

        // Radio: one parent field with a widget kid per option.
        let residence = try #require(fields["applicant.address.residence"])
        #expect(residence.name("FT") == "Btn" && residence.name("V") == "rent")
        #expect(residence.int("Ff") == (32_768 | 16_384 | 2))
        let kids = try #require(residence.array("Kids"))
        #expect(kids.count == 4)
        let states = (0..<kids.count).compactMap { kids.dict(at: $0)?.name("AS") }
        #expect(states == ["rent", "Off", "Off", "Off"])
        #expect(kids.dict(at: 1)?.dict("AP")?.dict("N")?.dict("own") == nil) // streams, not dicts
        var stream: CGPDFStreamRef?
        #expect(CGPDFDictionaryGetStream(try #require(kids.dict(at: 1)?.dict("AP")?.dict("N")).ref, "own", &stream))

        // Checkboxes: on/off appearance states named after the export value.
        let credit = try #require(fields["declaration.creditCheck"])
        #expect(credit.name("V") == "Off" && credit.name("AS") == "Off" && credit.int("Ff") == 2)
        let normal = try #require(credit.dict("AP")?.dict("N"))
        #expect(CGPDFDictionaryGetStream(normal.ref, "Authorized", &stream) && CGPDFDictionaryGetStream(normal.ref, "Off", &stream))
        #expect(fields["household.hasPets"]?.name("V") == "Yes")
    }

    @Test func qpdfCheckPasses() async throws {
        #if os(macOS)
        guard let qpdf = ["/opt/homebrew/bin/qpdf", "/usr/local/bin/qpdf", "/usr/bin/qpdf"]
            .first(where: FileManager.default.isExecutableFile(atPath:)) else { return }
        let result = try await Self.applicationForm()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("form-\(UUID().uuidString).pdf")
        try result.data.write(to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qpdf)
        process.arguments = ["--check", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(output)")
        #expect(output.contains("No syntax or stream encoding errors"))
        #endif
    }

    // MARK: Round trip

    @Test func roundTripThroughPDFKit() async throws {
        let result = try await Self.applicationForm()
        let document = try #require(PDFDocument(data: result.data))
        var widgets: [String: [PDFAnnotation]] = [:]
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                widgets[annotation.fieldName ?? "", default: []].append(annotation)
            }
        }
        func widget(_ suffix: String) throws -> PDFAnnotation {
            try #require(widgets.first { $0.key == suffix || $0.key.hasSuffix("." + suffix) }?.value.first, "\(suffix)")
        }
        try widget("firstName").widgetStringValue = "Janet"
        try widget("comments").widgetStringValue = "Line one\nLine two"
        try widget("creditCheck").buttonWidgetState = .onState
        try widget("hasPets").buttonWidgetState = .offState
        try widget("state").widgetStringValue = "WA"
        let residence = try #require(widgets.first { $0.key.hasSuffix("residence") }?.value)
        // Like a tap: turn the chosen button on (PDFKit turns its siblings off).
        try #require(residence.first { $0.buttonWidgetStateString == "own" }).buttonWidgetState = .onState

        let saved = try #require(document.dataRepresentation())
        if let output = ProcessInfo.processInfo.environment["JSONRENDER_PDF_OUTPUT"] {
            try? saved.write(to: URL(fileURLWithPath: output).appendingPathComponent("roundtrip-saved.pdf"))
        }
        let reader = try PDFFormReader(data: saved)
        let values = reader.values(for: result.formFields)
        #expect(values["applicant.firstName"] == "Janet")
        #expect(values["declaration.comments"] == "Line one\nLine two")
        #expect(values["declaration.creditCheck"] == true)
        #expect(values["household.hasPets"] == false)
        #expect(values["applicant.address.state"] == "WA")
        #expect(values["applicant.address.residence"] == "own", "raw: \(String(describing: reader.values()["applicant.address.residence"]))")
        #expect(values["applicant.lastName"] == "Appleseed", "untouched values survive")
        // PDFKit before OS 27 drops multi-select list values (array /V) when it saves.
        if #available(iOS 27, macOS 27, *) {
            #expect(values["employment.incomeSources"] == ["salary", "freelance"])
        }

        let updates = PDFFormReader.stateUpdates(values, fields: result.formFields)
        #expect(updates.contains { $0.pointer == "/applicant/firstName" && $0.value == "Janet" })
        #expect(updates.contains { $0.pointer == "/household/hasPets" && $0.value == false })
        #expect(!updates.contains { $0.pointer == "" })
    }

    @Test func readerReadsUnmodifiedRender() async throws {
        let result = try await Self.applicationForm()
        let values = try PDFFormReader(data: result.data).values(for: result.formFields)
        for field in result.formFields {
            switch field.type {
            case .textInput: #expect(values[field.name] == (field.value ?? ""), "\(field.name)")
            default: if let value = field.value { #expect(values[field.name] == value, "\(field.name)") }
            }
        }
    }

    // MARK: Validation of untrusted input

    @Test func readerValidatesUntrustedValues() throws {
        let fields = [
            PDFFormFieldInfo(name: "t", type: .textInput, maxLength: 3),
            PDFFormFieldInfo(name: "c", type: .checkbox),
            PDFFormFieldInfo(name: "r", type: .radioGroup, options: [.init(label: "A", value: "a")]),
            PDFFormFieldInfo(name: "s", type: .select, options: [.init(label: "A", value: "a")]),
            PDFFormFieldInfo(name: "e", type: .select, options: [.init(label: "A", value: "a")], isEditable: true),
            PDFFormFieldInfo(name: "l", type: .listBox, options: [.init(label: "A", value: "a"), .init(label: "B", value: "b")],
                             allowsMultipleSelection: true),
        ]
        func check(_ entry: PDFFormReader.RawEntry, _ index: Int) -> JSONValue? { PDFFormReader.validate(entry, for: fields[index]) }
        #expect(check(.text("abcdef"), 0) == "abc")
        #expect(check(.checkbox("Yes"), 0).isAbsent)
        #expect(check(.invalid, 0).isAbsent)
        #expect(check(.checkbox("Yes"), 1) == true)
        #expect(check(.checkbox(nil), 1) == false)
        #expect(check(.checkbox("Unrecognized"), 1).isAbsent)
        #expect(check(.text("yes"), 1).isAbsent)
        #expect(check(.radio("z"), 2).isAbsent)
        #expect(check(.radio("a"), 2) == "a")
        #expect(check(.radio(nil), 2).isAbsent)
        #expect(check(.choice(["z"], multiple: false), 3).isAbsent)
        #expect(check(.choice(["free text"], multiple: false), 4) == "free text")
        #expect(check(.choice(["a", "z", "b"], multiple: true), 5).isAbsent)
        #expect(check(.choice(["a", "b"], multiple: true), 5) == ["a", "b"])
        #expect(check(.invalid, 5).isAbsent)
        #expect(throws: PDFFormReader.ReadError.self) { try PDFFormReader(data: Data("not a pdf".utf8)) }
    }

    // MARK: Layout

    @Test func fieldsNeverSplitAndMoveWithTheirLabels() async throws {
        var elements: [String: JSONValue] = [
            "doc": ["type": "Document", "children": ["page"]],
        ]
        var children: [JSONValue] = []
        for index in 0..<40 {
            elements["f\(index)"] = ["type": "TextInput", "props": [
                "name": .string("field\(index)"), "label": .string("Label \(index)"), "multiline": .bool(index % 3 == 0), "lines": 3,
            ]]
            children.append(.string("f\(index)"))
        }
        elements["page"] = ["type": "Page", "props": [:], "children": .array(children)]
        let spec = Spec(json: ["root": "doc", "elements": .object(elements)])
        let pdf = try await PDFTestSupport.render(spec)
        #expect(pdf.pageCount >= 3)
        var widgetsSeen = 0
        for page in pdf.pages {
            let content = CGRect(x: 40, y: 40, width: page.size.width - 80, height: page.size.height - 80).insetBy(dx: -0.5, dy: -0.5)
            let labels = page.items.filter { $0.kind == .text && $0.text?.hasPrefix("Label") == true }
            let widgets = page.items.filter { $0.kind == .formWidget }
            #expect(labels.count == widgets.count, "each label sits on its widget's page")
            for widget in widgets { #expect(content.contains(widget.rect), "widget inside the content area") }
            widgetsSeen += widgets.count
        }
        #expect(widgetsSeen == 40)
        let result = try await Self.render(spec)
        let (_, fields, _, document) = try Self.fieldTree(result.data)
        #expect(fields.count == 40)
        withExtendedLifetime(document) {}
    }

    @Test func duplicateNamesAreSuffixedInThePDF() async throws {
        let spec = Spec(json: [
            "root": "doc",
            "elements": [
                "doc": ["type": "Document", "children": ["page"]],
                "page": ["type": "Page", "children": ["a", "b", "c"]],
                "a": ["type": "TextInput", "props": ["name": "email"]],
                "b": ["type": "TextInput", "props": ["name": "email"]],
                "c": ["type": "Checkbox", "props": ["name": "email", "label": "Email me"]],
            ],
        ])
        let result = try await Self.render(spec)
        #expect(result.formFields.map(\.name) == ["email", "email#2", "email#3"])
        let (_, fields, _, document) = try Self.fieldTree(result.data)
        #expect(Set(fields.keys) == ["email", "email#2", "email#3"])
        withExtendedLifetime(document) {}
    }

    @Test func documentsWithoutFieldsAreUntouched() async throws {
        let result = try await Self.render(try PDFFixtures.spec("invoice"))
        #expect(result.formFields.isEmpty)
        let document = try #require(CGPDFDocument(CGDataProvider(data: result.data as CFData)!))
        #expect(PDFDict(document.catalog)?.dict("AcroForm") == nil)
    }
}

extension Optional where Wrapped == JSONValue {
    /// `nil` (absent) — `== nil` would compare against `JSONValue.null`.
    var isAbsent: Bool { if case .none = self { true } else { false } }
}
