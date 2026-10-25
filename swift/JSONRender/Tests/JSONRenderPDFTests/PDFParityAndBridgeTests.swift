import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import JSONRenderPDF
import JSONRenderSwiftUI

/// `renderTree` cases of `fixtures/parity/repeat.json`: the element walk of react-pdf's
/// `renderToBuffer` (visibility, props, repeat scopes, skipped types and keys).
@Suite("PDF parity: renderTree")
struct RenderTreeParityTests {
    static let cases: [JSONValue] = {
        let cases = (try? PDFFixtures.json("parity/repeat.json"))?["cases"]?.arrayValue ?? []
        return cases.filter { $0["fn"]?.stringValue == "renderTree" }
    }()

    static func tree(_ element: ResolvedElement) -> JSONValue {
        var node: [String: JSONValue] = [
            "key": .string(element.key), "type": .string(element.type),
            "props": .object(element.props), "children": .array(element.children.map(tree)),
        ]
        if let scope = element.scope {
            var json: [String: JSONValue] = [:]
            if let index = scope.index { json["index"] = .number(Double(index)) }
            if let basePath = scope.basePath { json["basePath"] = .string(basePath) }
            node["scope"] = .object(json)
        }
        return .object(node)
    }

    @Test func casesPresent() {
        #expect(Self.cases.count >= 3)
    }

    @Test("renderTree", arguments: cases.indices)
    func renderTree(_ index: Int) throws {
        let testCase = Self.cases[index]
        let spec = Spec(json: try #require(testCase["spec"]))
        let resolved = SpecResolver(spec: spec, state: spec.state ?? .object([:]), knownTypes: DocumentBuilder.componentTypes)
            .resolveRoot()
        let actual: JSONValue = resolved.map(Self.tree) ?? .null
        #expect(actual == testCase["expected"], "\(testCase["name"]?.stringValue ?? "")")
    }
}

@Suite("PDF catalog bridge")
struct PDFBridgeTests {
    @Test func pdfCatalogPromptManifestAndValidation() async throws {
        let bridge = try #require(PDFFixtures.bridge)
        let manifest = try await bridge.catalogManifest(catalog: .pdf)
        #expect(Set(manifest.components) == PDFRenderer.componentTypes, "every PDF component has a native renderer")
        #expect(manifest.actions.isEmpty)
        let prompt = try await bridge.systemPrompt(catalog: .pdf)
        for component in ["Document", "Page", "Table", "PageNumber"] { #expect(prompt.contains(component)) }
        let formsManifest = try await bridge.catalogManifest()
        #expect(formsManifest.components.contains("TextField"), "forms catalog stays the default")
        for name in PDFFixtures.catalogSpecNames {
            let validation = try await bridge.validateSpec(try PDFFixtures.spec(name), catalog: .pdf)
            #expect(validation.valid, "\(name): \(validation.issues.map(\.message))")
        }
        let schema = try await bridge.jsonSchema(catalog: .pdf)
        #expect(schema.objectValue != nil)
    }
}

@Suite("PDF text fidelity")
struct PDFTextFidelityTests {
    @Test func hyphenationMatchesReactPDF() throws {
        let hyphenator = try #require(Hyphenator.enUS)
        #expect(hyphenator.syllables("conversation") == ["con", "ver", "sa", "tion"])
        #expect(hyphenator.syllables("projections.") == ["pro", "jec", "tions."])
        #expect(hyphenator.syllables("the") == ["the"])
    }

    /// Line breaks of upstream's reference renders (react-pdf Knuth & Plass + hyphenation).
    @Test func paragraphBreaksMatchReferenceRenders() async throws {
        let letter = try await PDFTestSupport.render(try PDFFixtures.spec("letter"))
        let lines = letter.items(.text).compactMap(\.item.text)
        #expect(lines.contains("Thank you for taking the time to meet with our team last Thursday. We greatly enjoyed the con-"))
        #expect(lines.contains("As discussed, we believe our enterprise platform can significantly streamline your operations while"))
        #expect(lines.contains("may have and discuss next steps. Please do not hesitate to reach out at your convenience. We look"))
        let report = try await PDFTestSupport.render(try PDFFixtures.spec("report"))
        #expect(report.items(.text).compactMap(\.item.text).contains("tions by 15%."))
    }

    @Test func overlongWordsNeverOverflow() async throws {
        let spec = PDFLayoutTests.document([
            "t": ["type": "Text", "props": ["text": .string(String(repeating: "W", count: 300))]],
        ])
        let pdf = try await PDFTestSupport.render(spec)
        for item in pdf.items(.text).map(\.item) {
            #expect(item.rect.maxX <= pdf.pages[0].size.width - 40 + 0.5)
        }
    }
}

@Suite("PDF preview")
@MainActor
struct PDFPreviewTests {
    @Test func renderPassProducesAPDF() async throws {
        let result = try #require(await JSONRenderPDFView.render(try PDFFixtures.spec("invoice"), options: .init(imageLoader: .placeholders)))
        let data = try result.get()
        #expect(PDFDocument(data: data)?.pageCount == 1)
    }

    @Test func previewMountsAndRenders() async throws {
        let rendered = Recorder<Int>()
        let view = JSONRenderPDFView(spec: try PDFFixtures.spec("invoice"), options: .init(imageLoader: .placeholders))
            .onPDFRender { result in rendered.values.append((try? result.get())?.count ?? -1) }
        #if canImport(UIKit)
        // The xctest host has no window scene, so only layout is exercised here.
        let host = UIHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        host.view.layoutIfNeeded()
        #else
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        for _ in 0..<200 where rendered.values.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect((rendered.values.first ?? 0) > 1000, "the .task renders and reports the PDF")
        #endif
    }
}

@MainActor
final class Recorder<Value> {
    var values: [Value] = []
}
