#if DEBUG
@testable import FormDemo
import Foundation
import JSONRenderPDF
import JSONRenderSwiftUI
import Testing

/// The `-demo intake` walkthrough's recorded streams (Debug-only resources in `DemoStreams/`).
@MainActor
@Suite("Demo walkthrough")
struct DemoScriptTests {
    @Test func intakeStreamsBuildAValidFormAndEditIt() async throws {
        let controller = GenerationController(generator: MockGenerator(.chunks([]))) {
            GenerationOptions(model: "m", reasoningEffort: nil)
        }
        await controller.replay(try ExampleSpec.replayStream(named: "demo-intake"), delay: .zero).value
        #expect(controller.errorMessage == nil)
        #expect(controller.issues.isEmpty, "\(controller.issues.map(\.message))")
        #expect(controller.session.visibleFields.map(\.path) == [
            "/form/clientName", "/form/email", "/form/siteAddress", "/form/budget",
        ])

        let edit = try ExampleSpec.replayStream(named: "demo-intake-edit")
        await controller.replay(edit, as: "Add planning permit status", delay: .zero).value
        #expect(controller.errorMessage == nil)
        #expect(controller.issues.isEmpty, "\(controller.issues.map(\.message))")
        let spec = try #require(controller.spec)
        #expect(spec.root == "form")
        #expect(spec.elements["permit-status"] != nil)

        // The permit number is shown only once the permit is approved; phone is now required.
        let store = controller.session.store
        #expect(!controller.session.visibleFields.map(\.path).contains("/form/permitNumber"))
        store.set(.string("approved"), at: "/form/permitStatus")
        #expect(controller.session.visibleFields.map(\.path).contains("/form/permitNumber"))
        #expect(controller.session.visibleFields.map(\.path).contains("/form/phone"))

        let state = store.state
        let fillable = FillablePDFMapper.spec(form: spec, data: state.value(at: "/form") ?? .null,
                                              dataRoot: "/form", state: state)
        let report = try await JSONRenderBridge().validateSpec(fillable, catalog: .pdf)
        #expect(report.valid, "\(report.issues.map(\.message))")
    }

    @Test func intakeScriptDecodes() throws {
        let script = try DemoScript.named("intake")
        #expect(script.steps.contains { $0.stream == "demo-intake-edit" })
        #expect(script.steps.last?.submit == .fillable)
    }
}
#endif
