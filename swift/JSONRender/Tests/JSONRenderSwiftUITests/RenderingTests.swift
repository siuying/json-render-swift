import SwiftUI
import Testing
@testable import JSONRenderSwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Mounts `JSONRenderView` in a real hosting view and forces layout, so every component's
/// body runs against fixture, partial and malformed specs.
@Suite("Rendering")
@MainActor
struct RenderingTests {
    private func mount(_ session: FormSession, registry: ComponentRegistry = .standard) {
        let root = NavigationStack {
            JSONRenderView(session: session)
                .jsonRenderRegistry(registry)
                .onJSONRenderAction("submit") { _, _ in }
        }
        #if canImport(UIKit)
        let controller = UIHostingController(rootView: root)
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        _ = controller.sizeThatFits(in: controller.view.bounds.size)
        #else
        let view = NSHostingView(rootView: root)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        view.layoutSubtreeIfNeeded()
        #endif
    }

    @Test("fixture specs render", arguments: SpecDecodingTests.specFiles)
    func fixtureSpecsRender(_ path: String) throws {
        let session = FormSession(spec: Spec(json: try Fixtures.json(path)))
        mount(session)
        session.validateAll()
        mount(session) // with inline errors
    }

    @Test("every streaming prefix renders", arguments: Fixtures.files(in: "specs", withExtension: "jsonl"))
    func partialSpecsRender(_ path: String) async throws {
        let bridge = try #require(BridgeTests.bridge)
        let compiler = try await bridge.makeStreamCompiler()
        let session = FormSession()
        for line in try Fixtures.text(path).split(separator: "\n") {
            session.spec = try await compiler.push(line + "\n").spec
            mount(session)
        }
        _ = try await compiler.finish()
    }

    @Test func malformedSpecsRender() {
        let session = FormSession(spec: Spec(json: [
            "root": "form",
            "elements": [
                "form": ["type": "Form", "children": ["loop", "unknown", "missing", "stepper", "slider", "date", "picker"]],
                "loop": ["type": "VStack", "children": ["loop", "form"]],
                "unknown": ["type": "Carousel", "props": [:]],
                "stepper": ["type": "Stepper", "props": ["label": nil, "minimum": 10, "maximum": 1, "step": 0]],
                "slider": ["type": "Slider", "props": ["label": "S", "minimum": 5, "maximum": 5, "value": "high"]],
                "date": ["type": "DatePicker", "props": ["label": "D", "selection": "garbage", "minimum": "2030-01-01", "maximum": "2020-01-01"]],
                "picker": ["type": "Picker", "props": ["label": "P", "options": [["label": "A"], "junk", ["label": "B", "value": 2]]]],
            ],
        ]))
        mount(session)
    }

    @Test func hostComponentsOverrideStandardOnes() {
        let session = FormSession(spec: Spec(json: ["root": "r", "elements": ["r": ["type": "Rating", "props": ["stars": 4]]]]))
        let rendered = Recorder<JSONValue?>()
        let registry = ComponentRegistry.standard.registering("Rating") { context in
            let _ = rendered.values.append(context.props["stars"])
            Text("Rating")
        }
        mount(session, registry: registry)
        #expect(rendered.values.contains(4))
    }
}

@Suite("ISO dates")
struct ISODateTests {
    @Test func roundTrips() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let date = try #require(ISODate.parse("2025-06-01", calendar: calendar))
        #expect(ISODate.formatDate(date, calendar: calendar) == "2025-06-01")
        let dateTime = try #require(ISODate.parse("2025-06-01T18:30:00Z"))
        #expect(ISODate.formatDateTime(dateTime) == "2025-06-01T18:30:00Z")
        #expect(ISODate.parse("2025-06-01T18:30:00.250Z") != nil)
        #expect(ISODate.parse("2025-06-01T18:30:00+02:00") == ISODate.parse("2025-06-01T16:30:00Z"))
        #expect(ISODate.parse("2025-06-01T09:15", calendar: calendar) != nil)
        #expect(ISODate.parse("June 1st") == nil)
    }
}
