import Foundation
import Testing
@testable import JSONRenderSwiftUI

@Suite("Spec decoding")
struct SpecDecodingTests {
    static let specFiles = Fixtures.files(in: "specs", withExtension: "json")

    @Test("fixture specs decode", arguments: specFiles)
    func decodes(_ path: String) throws {
        let data = try Data(contentsOf: Fixtures.url(path))
        let spec = try JSONDecoder().decode(Spec.self, from: data)
        let root = try #require(spec.rootElement)
        #expect(root.type == "Form")
        #expect(spec.state?.objectValue != nil)
        for (key, element) in spec.elements {
            #expect(ComponentRegistry.standard.renderer(for: element.type) != nil, "\(key): \(element.type)")
            for child in element.children { #expect(spec.elements[child] != nil, "\(key) → \(child)") }
        }
        // Round-trips through Codable without loss.
        let reencoded = try JSONDecoder().decode(Spec.self, from: JSONEncoder().encode(spec))
        #expect(reencoded == spec)
    }

    @Test func fixtureSpecsHaveFields() throws {
        for path in Self.specFiles {
            let spec = Spec(json: try Fixtures.json(path))
            let fields = FormField.fields(in: spec, state: spec.state ?? .object([:]))
            #expect(!fields.isEmpty, "\(path) has validated fields")
        }
    }

    @Test func partialSpecsAreTolerated() {
        let spec = Spec(json: [
            "root": "form",
            "elements": [
                "form": ["type": "Form", "children": ["missing", 3, "field"]],
                "field": ["props": ["label": nil]],
                "junk": "not an element",
            ],
            "state": "not an object",
        ])
        #expect(spec.rootElement?.children == ["missing", "field"])
        #expect(spec.elements["field"]?.type == "")
        #expect(spec.elements["junk"] == nil)
        #expect(spec.state == nil)
        #expect(Spec(json: ["root": ""]).root == nil)
    }

    @Test func actionBindingsDecodeSingleAndArray() {
        let element = Element(json: [
            "type": "Button",
            "on": [
                "press": [["action": "setState", "params": ["statePath": "/a", "value": 1]], ["action": "submit"]],
                "longPress": ["action": "showAlert", "confirm": ["title": "T", "message": "M"]],
                "bad": ["params": [:]],
            ],
        ])
        #expect(element?.on["press"]?.map(\.action) == ["setState", "submit"])
        #expect(element?.on["longPress"]?.first?.confirm?.title == "T")
        #expect(element?.on["bad"] == nil)
    }
}

@Suite("JavaScript bridge")
struct BridgeTests {
    static let bridge: JSONRenderBridge? = try? JSONRenderBridge()

    func makeBridge() throws -> JSONRenderBridge {
        try #require(Self.bridge, "json-render-bridge.js loads in a bare JSContext")
    }

    @Test func systemPromptListsCatalog() async throws {
        let bridge = try makeBridge()
        let prompt = try await bridge.systemPrompt()
        #expect(!prompt.isEmpty)
        let manifest = try await bridge.catalogManifest()
        for component in ComponentRegistry.standard.types {
            #expect(manifest.components.contains(component), "catalog declares \(component)")
            #expect(prompt.contains(component), "prompt mentions \(component)")
        }
        #expect(Set(manifest.components) == Set(ComponentRegistry.standard.types), "every catalog component has a native renderer")
        for action in ["submit", "resetForm", "setState", "pushState", "removeState", "showAlert", "openURL"] {
            #expect(manifest.actions.contains(action))
        }
        let custom = try await bridge.systemPrompt(customRules: ["ALWAYS-INCLUDE-THIS-RULE"])
        #expect(custom.contains("ALWAYS-INCLUDE-THIS-RULE"))
        let version = try await bridge.version()
        #expect(!version.isEmpty)
    }

    @Test func userPromptIncludesCurrentSpec() async throws {
        let bridge = try makeBridge()
        let spec = Spec(json: try Fixtures.json("specs/registration.json"))
        let fresh = try await bridge.buildUserPrompt("A sign-up form")
        let edit = try await bridge.buildUserPrompt("Add a phone field", currentSpec: spec, state: spec.state)
        #expect(fresh.contains("A sign-up form"))
        #expect(edit.contains("Add a phone field"))
        #expect(edit.contains("confirm-password"))
    }

    @Test("streams JSONL chunk by chunk", arguments: Fixtures.files(in: "specs", withExtension: "jsonl"))
    @MainActor
    func streamsJSONL(_ path: String) async throws {
        let bridge = try makeBridge()
        let text = try Fixtures.text(path)
        let compiler = try await bridge.makeStreamCompiler()
        let session = FormSession()
        var patchCount = 0
        var index = text.startIndex
        while index < text.endIndex {
            // Irregular chunk sizes split lines mid-way, like a network stream.
            let end = text.index(index, offsetBy: 7 + patchCount % 23, limitedBy: text.endIndex) ?? text.endIndex
            let update = try await compiler.push(String(text[index..<end]))
            patchCount += update.newPatches.count
            session.spec = update.spec
            #expect(session.store.peek(at: "")?.objectValue != nil)
            index = end
        }
        let final = try await compiler.finish()
        let lineCount = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        let flushedByFinish = text.hasSuffix("\n") ? 0 : 1
        #expect(patchCount == lineCount - flushedByFinish)
        session.spec = final
        #expect(session.store.peek(at: "") == final.state)
        #expect(final.rootElement?.type == "Form")

        let jsonPath = path.replacingOccurrences(of: ".jsonl", with: ".json")
        if FileManager.default.fileExists(atPath: Fixtures.url(jsonPath).path) {
            #expect(final == Spec(json: try Fixtures.json(jsonPath)), "stream compiles to \(jsonPath)")
        }
        let validation = try await bridge.validateSpec(final)
        #expect(validation.valid, "\(validation.issues)")
    }

    @Test("fixture specs validate", arguments: SpecDecodingTests.specFiles)
    func fixtureSpecsValidate(_ path: String) async throws {
        let bridge = try makeBridge()
        let validation = try await bridge.validateSpec(Spec(json: try Fixtures.json(path)))
        #expect(validation.valid, "\(validation.issues.map(\.message))")
    }

    @Test func validateSpecReportsIssues() async throws {
        let bridge = try makeBridge()
        let broken = Spec(json: [
            "root": "form",
            "elements": ["form": ["type": "Form", "props": [:], "children": ["ghost"]]],
        ])
        let validation = try await bridge.validateSpec(broken)
        #expect(!validation.valid)
        #expect(validation.issues.contains { $0.isError })
    }

    @Test func autoFixMovesMisplacedFields() async throws {
        let bridge = try makeBridge()
        let spec = Spec(json: [
            "root": "t",
            "elements": ["t": ["type": "Text", "props": ["content": "x", "visible": false], "children": []]],
        ])
        let fixed = try await bridge.autoFixSpec(spec)
        #expect(fixed.elements["t"]?.visible == false)
        #expect(fixed.elements["t"]?.props["visible"] == nil)
    }

    @Test func javaScriptErrorsSurfaceAsSwiftErrors() async throws {
        let bridge = try makeBridge()
        let compiler = SpecStreamCompiler(bridge: bridge, handle: 987_654)
        await #expect(throws: JSONRenderBridgeError.self) { try await compiler.push("{}") }

        let failing = try JSONRenderBridge(script: "globalThis.JSONRenderBridge = { invoke() { throw new Error('kaboom') } };")
        do {
            _ = try await failing.version()
            Issue.record("expected an error")
        } catch let JSONRenderBridgeError.javaScript(message, _) {
            #expect(message.contains("kaboom"))
        }
        #expect(throws: JSONRenderBridgeError.self) { try JSONRenderBridge(script: "syntax error (") }
    }

    @Test func customCatalogReachesJavaScript() async throws {
        // Built by scripts/build-bridge.mjs from packages/swift/test/fixtures/test-catalog-bridge.ts.
        let url = Fixtures.url("bridge/test-catalog-bridge.js")
        let bridge = try JSONRenderBridge(script: Fixtures.text("bridge/test-catalog-bridge.js"), sourceURL: url)
        let test = JSONRenderBridge.Catalog("test")

        let manifest = try await bridge.catalogManifest(catalog: test)
        #expect(manifest == CatalogManifest(components: ["Board", "Metric"], actions: ["refresh"]))
        let prompt = try await bridge.systemPrompt(customRules: ["CUSTOM-RULE"], catalog: "test")
        #expect(prompt.contains("Metric"))
        #expect(prompt.contains("CUSTOM-RULE"))

        let spec = Spec(json: [
            "root": "board",
            "elements": [
                "board": ["type": "Board", "props": ["title": "Today", "visible": true], "children": ["visits", "ghost"]],
                "visits": ["type": "Metric", "props": ["label": "Visits", "value": ["$state": "/visits"]], "children": []],
            ],
            "state": ["visits": 42],
        ])
        let report = try await bridge.validateSpec(spec, catalog: test)
        #expect(!report.valid)
        let fixed = try await bridge.autoFixSpec(spec, catalog: test)
        #expect(fixed.elements["board"]?.children == ["visits"])
        #expect(try await bridge.validateSpec(fixed, catalog: test) == SpecValidation(valid: true, issues: []))
        let schema = try await bridge.jsonSchema(catalog: test)
        #expect(schema["required"] == ["root", "elements"])

        // The built-ins are still there, and swiftui is still the default.
        #expect(Set(try await bridge.catalogManifest().components) == Set(ComponentRegistry.standard.types))
        #expect(try await bridge.catalogManifest(catalog: .pdf).components.contains("Document"))
    }

    @Test func catalogKeepsTheFormerEnumAPI() throws {
        typealias Catalog = JSONRenderBridge.Catalog
        #expect(Catalog.allCases == [.swiftui, .pdf])
        #expect(Catalog.allCases.map(\.rawValue) == ["swiftui", "pdf"])
        if let pdf = Catalog(rawValue: "pdf") {
            #expect(pdf == .pdf)
        } else {
            Issue.record("init?(rawValue:) returned nil")
        }
        #expect(Catalog(rawValue: "swiftui")! == .swiftui)
        #expect(Catalog(rawValue: "database")?.rawValue == "database")

        let literal: Catalog = "database"
        #expect(literal == Catalog("database"))
        #expect(literal.rawValue == "database")
        #expect(!Catalog.allCases.contains(literal))

        func title(_ catalog: Catalog) -> String {
            switch catalog {
            case .swiftui: "Form"
            case .pdf: "Document"
            default: catalog.rawValue
            }
        }
        #expect(Catalog.allCases.map(title) == ["Form", "Document"])
        #expect(title(literal) == "database")
    }

    @Test func unknownCatalogThrowsJavaScriptError() async throws {
        let bridge = try makeBridge()
        do {
            _ = try await bridge.catalogManifest(catalog: "database")
            Issue.record("expected an error")
        } catch let JSONRenderBridgeError.javaScript(message, _) {
            #expect(message == "Unknown catalog: database (expected swiftui | pdf)")
        }
        await #expect(throws: JSONRenderBridgeError.self) {
            try await bridge.validateSpec(Spec(json: ["root": "a", "elements": [:]]), catalog: .init("toString"))
        }
    }
}
