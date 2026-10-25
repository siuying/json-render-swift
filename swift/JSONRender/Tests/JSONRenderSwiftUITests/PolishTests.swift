import Foundation
import SwiftUI
import Testing
@testable import JSONRenderSwiftUI

@Suite("SDK polish")
@MainActor
struct PolishTests {
    @Test func intPropsClampInsteadOfTrapping() {
        let props = Props(["big": 1e300, "small": -1e300, "normal": 2.6])
        #expect(props.int("big") == 2_147_483_647)
        #expect(props.int("small") == -2_147_483_648)
        #expect(props.int("normal") == 3)
    }

    @Test func concurrentRunsKeepTheActionRunning() async {
        let session = FormSession()
        let gates = Recorder<CheckedContinuation<Void, Never>>()
        session.actions.register("save") { _, _ in
            await withCheckedContinuation { gates.values.append($0) }
        }
        let first = Task { await session.perform("save") }
        let second = Task { await session.perform("save") }
        while gates.values.count < 2 { await Task.yield() }
        gates.values[0].resume()
        await first.value
        #expect(session.runningActions.contains("save"), "the second run is still going")
        gates.values[1].resume()
        await second.value
        #expect(session.runningActions.isEmpty)
    }

    @Test func urlOpenerWorksWithoutARenderedView() async {
        let session = FormSession()
        var opened: [URL] = []
        session.urlOpener = { opened.append($0) }
        await session.perform("openURL", params: ["url": "https://example.com"])
        #expect(opened == [URL(string: "https://example.com")!])
    }

    @Test func publicInitializersForHosts() {
        let request = ConfirmationRequest(title: "Delete?", message: "Sure", isDestructive: true)
        #expect(request.confirmLabel == "Confirm" && request.isDestructive)
        let result = ValidationResult(valid: false, errors: ["Required"],
                                      checks: [ValidationCheckResult(type: "required", valid: false, message: "Required")])
        #expect(!result.valid && result.checks.count == 1)
        let validation = SpecValidation(valid: true, issues: [.init(severity: "warning", message: "Note", path: "/root")])
        #expect(validation.issues.first?.isError == false)
        let session = FormSession()
        session.resolveConfirmation(true) // no pending request: no-op
        _ = FieldTitle(text: "Label")
    }

    @Test func validateSpecForwardsHostValidatorsAndActions() async throws {
        let bridge = try JSONRenderBridge()
        let spec = Spec(json: [
            "root": "form",
            "elements": [
                "form": ["type": "Form", "props": [:], "children": ["zip", "go"]],
                "zip": ["type": "TextField", "props": [
                    "label": "ZIP", "value": ["$bindState": "/zip"],
                    "checks": [["type": "postalCode", "message": "Invalid ZIP"]],
                ], "children": []],
                "go": ["type": "Button", "props": ["label": "Go"], "on": ["press": ["action": "track"]], "children": []],
            ],
            "state": ["zip": ""],
        ])
        let codes = { (validation: SpecValidation) in Set(validation.issues.compactMap(\.code)) }
        let plain = try await bridge.validateSpec(spec)
        #expect(codes(plain).isSuperset(of: ["unknown_check", "unknown_action"]))
        let hosted = try await bridge.validateSpec(spec, hostActions: ["track"], hostValidators: ["postalCode"])
        #expect(codes(hosted).isDisjoint(with: ["unknown_check", "unknown_action"]))
    }
}
