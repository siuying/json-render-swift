import Foundation
import Testing
@testable import JSONRenderSwiftUI

/// Collects values from `@Sendable` handler closures.
@MainActor
final class Recorder<Value> {
    var values: [Value] = []
}

@Suite("FormSession: actions & submit")
@MainActor
struct SessionTests {
    func registrationSession() throws -> FormSession {
        FormSession(spec: Spec(json: try Fixtures.json("specs/registration.json")))
    }

    func fillValidRegistration(_ session: FormSession) {
        session.store.update([
            ("/form/email", "ada@example.com"),
            ("/form/password", "correct horse 1"),
            ("/form/confirmPassword", "correct horse 1"),
            ("/form/fullName", "Ada Lovelace"),
            ("/form/acceptTerms", true),
        ])
    }

    @Test func submitBlocksAndShowsErrorsWhenInvalid() async throws {
        let session = try registrationSession()
        let submitted = Recorder<JSONValue>()
        session.actions.register("submit") { params, _ in submitted.values.append(params["data"] ?? .null) }

        await session.emit("press", from: "submit")

        #expect(submitted.values.isEmpty)
        let email = session.validation.field("/form/email")
        #expect(email.touched && email.validated)
        #expect(email.errors == ["Email is required", "Enter a valid email address"])
        #expect(session.validation.field("/form/acceptTerms").errors == ["You must accept the terms to continue"])
        // Hidden (personal account) company field is skipped.
        #expect(!session.validation.field("/form/company").validated)
    }

    @Test func submitPassesResolvedDataToHost() async throws {
        let session = try registrationSession()
        let submitted = Recorder<JSONValue>()
        session.actions.register("submit") { params, _ in submitted.values.append(params["data"] ?? .null) }
        fillValidRegistration(session)

        await session.emit("press", from: "submit")

        #expect(submitted.values.count == 1)
        #expect(submitted.values.first?["email"] == "ada@example.com")
        #expect(submitted.values.first?["accountType"] == "personal")
    }

    @Test func visibleConditionalFieldIsValidated() async throws {
        let session = try registrationSession()
        let submits = Recorder<Void>()
        session.actions.register("submit") { _, _ in submits.values.append(()) }
        fillValidRegistration(session)
        session.store.set("business", at: "/form/accountType")

        await session.emit("press", from: "submit")
        #expect(submits.values.isEmpty)
        #expect(session.validation.field("/form/company").errors == ["Company name is required for business accounts"])

        session.store.set("Acme", at: "/form/company")
        #expect(session.validation.field("/form/company").errors.isEmpty, "validated fields re-validate on change")
        await session.emit("press", from: "submit")
        #expect(submits.values.count == 1)
    }

    @Test func crossFieldErrorsStayCurrent() throws {
        let session = try registrationSession()
        session.store.update([("/form/password", "secret-123"), ("/form/confirmPassword", "secret-123")])
        session.validateAll()
        #expect(session.validation.field("/form/confirmPassword").errors.isEmpty)
        session.store.set("secret-456", at: "/form/password")
        #expect(session.validation.field("/form/confirmPassword").errors == ["Passwords do not match"])
    }

    @Test func blurValidatesOnlyBlurFields() throws {
        let session = try registrationSession()
        let fields = Dictionary(uniqueKeysWithValues: session.visibleFields.map { ($0.key, $0) })
        session.fieldDidBlur(try #require(fields["email"]))
        #expect(session.validation.field("/form/email").errors.first == "Email is required")
        session.fieldDidBlur(try #require(fields["terms"]))
        #expect(session.validation.field("/form/acceptTerms").touched)
        #expect(!session.validation.field("/form/acceptTerms").validated, "terms validates on submit")
    }

    @Test func validateOnChange() {
        let spec = Spec(json: [
            "root": "name",
            "elements": ["name": [
                "type": "TextField",
                "props": [
                    "label": "Name", "value": ["$bindState": "/name"], "validateOn": "change",
                    "checks": [["type": "minLength", "args": ["min": 3], "message": "Too short"]],
                ],
            ]],
            "state": ["name": ""],
        ])
        let session = FormSession(spec: spec)
        session.store.set("Al", at: "/name")
        #expect(session.validation.field("/name").errors == ["Too short"])
        session.store.set("Alan", at: "/name")
        #expect(session.validation.field("/name").errors.isEmpty)
    }

    @Test func stateBuiltIns() async {
        let session = FormSession(spec: Spec(json: ["root": "x", "elements": [:], "state": ["tags": ["a"], "draft": "b"]]))
        await session.perform("setState", params: ["statePath": "/flag", "value": true])
        await session.perform("pushState", params: ["statePath": "/tags", "value": ["$state": "/draft"], "clearStatePath": "/draft"])
        #expect(session.store.peek(at: "/flag") == true)
        #expect(session.store.peek(at: "/tags") == ["a", "b"])
        #expect(session.store.peek(at: "/draft") == "")
        await session.perform("pushState", params: ["statePath": "/items", "value": ["id": "$id"]])
        #expect(session.store.peek(at: "/items/0/id")?.stringValue?.isEmpty == false)
        await session.perform("removeState", params: ["statePath": "/tags", "index": 0])
        #expect(session.store.peek(at: "/tags") == ["b"])
    }

    @Test func resetFormRestoresInitialStateAndClearsValidation() async throws {
        let session = try registrationSession()
        session.store.set("typed", at: "/form/email")
        session.validateAll()
        await session.perform("resetForm")
        #expect(session.store.peek(at: "/form/email") == "")
        #expect(!session.validation.field("/form/email").validated)

        session.store.set("typed", at: "/form/email")
        session.store.set("Ada", at: "/form/fullName")
        await session.perform("resetForm", params: ["statePath": "/form/email"])
        #expect(session.store.peek(at: "/form/email") == "")
        #expect(session.store.peek(at: "/form/fullName") == "Ada")
    }

    @Test func showAlertAndOpenURL() async throws {
        let session = try registrationSession()
        await session.perform("showAlert", params: ["title": "Hello", "message": ["$template": "Plan: ${/form/accountType}"]])
        #expect(session.alert?.title == "Hello")
        #expect(session.alert?.message == "Plan: personal")

        var opened: [URL] = []
        session.openURLAction = { opened.append($0) }
        await session.emit("press", from: "terms-link")
        #expect(opened == [URL(string: "https://example.com/terms")!])
    }

    @Test func hostHandlersAndUnknownActions() async {
        let session = FormSession()
        let received = Recorder<[String: JSONValue]>()
        session.actions.register("track") { params, _ in received.values.append(params) }
        session.store.set("pro", at: "/plan")
        await session.perform("track", params: ["plan": ["$state": "/plan"]])
        #expect(received.values == [["plan": "pro"]])
        await session.perform("doesNotExist") // logged, no crash
    }

    @Test func onSuccessAndOnError() async {
        struct Failure: LocalizedError { var errorDescription: String? { "boom" } }
        let session = FormSession()
        session.actions.register("ok") { _, _ in }
        session.actions.register("fail") { _, _ in throw Failure() }
        await session.actions.dispatch(ActionBinding(action: "ok", onSuccess: ["set": ["/done": true]]))
        await session.actions.dispatch(ActionBinding(action: "fail", onError: ["set": ["/error": "$error.message"]]))
        await session.actions.dispatch(ActionBinding(
            action: "ok", onSuccess: ["action": "setState", "params": ["statePath": "/chained", "value": 1]]
        ))
        #expect(session.store.peek(at: "/done") == true)
        #expect(session.store.peek(at: "/error") == "boom")
        #expect(session.store.peek(at: "/chained") == 1)
    }

    @Test func confirmGatesDispatch() async {
        let session = FormSession()
        session.store.set("Ada", at: "/name")
        let binding = ActionBinding(
            action: "setState",
            params: ["statePath": "/cleared", "value": true],
            confirm: ActionConfirm(title: "Clear ${/name}?", message: "Sure?", variant: "danger")
        )

        let cancelled = Task { await session.actions.dispatch(binding) }
        while session.confirmation == nil { await Task.yield() }
        #expect(session.confirmation?.title == "Clear Ada?")
        #expect(session.confirmation?.isDestructive == true)
        session.resolveConfirmation(false)
        await cancelled.value
        #expect(session.store.peek(at: "/cleared") == nil)

        let confirmed = Task { await session.actions.dispatch(binding) }
        while session.confirmation == nil { await Task.yield() }
        session.resolveConfirmation(true)
        await confirmed.value
        #expect(session.store.peek(at: "/cleared") == true)
    }

    @Test func watchFiresOnChange() async {
        let spec = Spec(json: [
            "root": "country",
            "elements": ["country": [
                "type": "Picker",
                "props": ["label": "Country", "selection": ["$bindState": "/country"], "options": []],
                "watch": ["/country": ["action": "setState", "params": ["statePath": "/city", "value": ""]]],
            ]],
            "state": ["country": "UK", "city": "London"],
        ])
        let session = FormSession(spec: spec)
        session.store.set("FR", at: "/country")
        while session.store.peek(at: "/city") != "" { await Task.yield() }
        #expect(session.store.peek(at: "/city") == "")
    }

    @Test func runningActionsTrackHostWork() async {
        let session = FormSession()
        let sawRunning = Recorder<Bool>()
        session.actions.register("submit") { _, session in sawRunning.values.append(session.runningActions.contains("submit")) }
        await session.perform("submit")
        #expect(sawRunning.values == [true])
        #expect(session.runningActions.isEmpty)
    }
}

@Suite("FormSession: spec updates")
@MainActor
struct SpecUpdateTests {
    @Test func streamingKeepsUserInputAndAddsNewState() {
        let session = FormSession(spec: Spec(json: ["root": "form", "elements": [:], "state": ["form": ["email": ""]]]))
        session.store.set("typed@example.com", at: "/form/email")
        session.spec = Spec(json: ["root": "form", "elements": [:], "state": ["form": ["email": "", "plan": "free"]]])
        #expect(session.store.peek(at: "/form") == ["email": "typed@example.com", "plan": "free"])
        #expect(session.initialState == ["form": ["email": "", "plan": "free"]])
    }

    @Test func newRootReseeds() {
        let session = FormSession(spec: Spec(json: ["root": "a", "elements": [:], "state": ["x": 1]]))
        session.store.set(2, at: "/x")
        session.validation.field("/x").record(.passed)
        session.spec = Spec(json: ["root": "b", "elements": [:], "state": ["y": 1]])
        #expect(session.store.peek(at: "") == ["y": 1])
        #expect(!session.validation.field("/x").validated)
    }

    @Test func streamingFromEmptySeedsState() {
        let session = FormSession()
        session.spec = Spec(json: ["root": "form"])
        session.spec = Spec(json: ["root": "form", "state": ["form": ["email": ""]]])
        #expect(session.store.peek(at: "/form/email") == "")
    }
}
