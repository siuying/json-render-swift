import Foundation
import Testing
@testable import JSONRenderSwiftUI

/// Regression tests for docs/reviews/swift-sdk-review.md (findings 1–11).
/// JS expectations were checked against `new RegExp` / `new URL` in Node.
@MainActor
@Suite("Review regressions")
struct ReviewRegressionTests {
    /// A single field `/name` (minLength 5), seeded with `name`.
    func nameForm(name: JSONValue = "abc", min: Int = 5, extraElements: [String: JSONValue] = [:]) -> Spec {
        var elements: [String: JSONValue] = [
            "form": ["type": "Form", "children": .array([.string("field")] + extraElements.keys.sorted().map(JSONValue.string))],
            "field": [
                "type": "TextField",
                "props": [
                    "label": "Name", "value": ["$bindState": "/name"],
                    "checks": [["type": "minLength", "args": ["min": .number(Double(min))], "message": .string("Need \(min)")]],
                ],
            ],
        ]
        elements.merge(extraElements) { $1 }
        return Spec(json: ["root": "form", "elements": .object(elements), "state": ["name": name, "derived": "initial"]])
    }

    func watcher(_ bindings: JSONValue) -> [String: JSONValue] {
        ["watcher": ["type": "Text", "props": ["content": "w"], "watch": ["/name": bindings]]]
    }

    func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    // MARK: 1. Halted submit stops the chain

    @Test func invalidSubmitStopsRemainingBindings() async {
        let session = FormSession(spec: nameForm())
        let after = Recorder<Void>()
        session.actions.register("after") { _, _ in after.values.append(()) }
        session.actions.register("submit") { _, _ in }
        let chain = [
            ActionBinding(action: "submit"),
            ActionBinding(action: "setState", params: ["statePath": "/name", "value": ""]),
            ActionBinding(action: "after"),
        ]
        await session.actions.dispatch(chain)
        #expect(after.values.isEmpty)
        #expect(session.store.peek(at: "/name") == "abc")
        #expect(session.validation.field("/name").errors == ["Need 5"])

        session.store.set("abcdef", at: "/name")
        await session.actions.dispatch(chain)
        #expect(after.values.count == 1, "a passing submit continues the chain")
    }

    @Test func cancelledConfirmAndUnhandledErrorsStopTheChain() async {
        struct Failure: Error {}
        let session = FormSession()
        session.actions.register("fail") { _, _ in throw Failure() }
        await session.actions.dispatch([
            ActionBinding(action: "fail"),
            ActionBinding(action: "setState", params: ["statePath": "/ran", "value": true]),
        ])
        #expect(session.store.peek(at: "/ran") == nil)

        await session.actions.dispatch([
            ActionBinding(action: "fail", onError: ["set": ["/handled": true]]),
            ActionBinding(action: "setState", params: ["statePath": "/ran", "value": true]),
        ])
        #expect(session.store.peek(at: "/handled") == true)
        #expect(session.store.peek(at: "/ran") == true, "an onError handler recovers the chain")

        let chain = Task {
            await session.actions.dispatch([
                ActionBinding(action: "setState", confirm: ActionConfirm(title: "Sure?", message: "")),
                ActionBinding(action: "setState", params: ["statePath": "/afterCancel", "value": true]),
            ])
        }
        while session.confirmation == nil { await Task.yield() }
        session.resolveConfirmation(false)
        await chain.value
        #expect(session.store.peek(at: "/afterCancel") == nil)
    }

    // MARK: 2. Watcher lifecycle

    @Test func watcherDoesNotWriteIntoANewRoot() async {
        let session = FormSession(spec: nameForm(extraElements: watcher(
            ["action": "setState", "params": ["statePath": "/derived", "value": "fired"]]
        )))
        session.store.set("changed", at: "/name")
        session.spec = Spec(json: ["root": "other", "elements": [:], "state": ["derived": "new form"]])
        await settle()
        #expect(session.store.peek(at: "/derived") == "new form")
    }

    @Test func suspendedWatcherChainStopsWhenItsElementIsRemoved() async {
        let gate = Recorder<Bool>()
        let session = FormSession(spec: nameForm(extraElements: watcher([
            ["action": "slow"],
            ["action": "setState", "params": ["statePath": "/derived", "value": "fired"]],
        ])))
        session.actions.register("slow") { _, _ in
            while gate.values.isEmpty { await Task.yield() }
        }
        session.store.set("changed", at: "/name")
        await settle()
        session.spec = nameForm(name: "changed") // same root, watcher element removed
        gate.values.append(true)
        await settle()
        #expect(session.store.peek(at: "/derived") == "initial")
    }

    @Test func newerChangeCancelsOlderWatcherChain() async {
        let gate = Recorder<Bool>()
        let runs = Recorder<JSONValue>()
        let session = FormSession(spec: nameForm(extraElements: watcher([
            ["action": "slow"],
            ["action": "record", "params": ["name": ["$state": "/name"]]],
        ])))
        session.actions.register("slow") { _, _ in
            while gate.values.isEmpty { await Task.yield() }
        }
        session.actions.register("record") { params, _ in runs.values.append(params["name"] ?? .null) }
        session.store.set("first", at: "/name")
        await settle()
        session.store.set("second", at: "/name")
        gate.values.append(true)
        await settle()
        #expect(runs.values == ["second"])
    }

    // MARK: 3. Slot invalidation for append and index aliases

    @Test func appendAndIndexAliasesRefreshObservedSlots() {
        let store = StateStore(initialState: ["items": ["a"]])
        #expect(store.value(at: "/items/1") == nil)
        let appended = Counter()
        withObservationTracking { _ = store.value(at: "/items/1") } onChange: { appended.increment() }
        store.set("b", at: "/items/-")
        #expect(appended.value == 1)
        #expect(store.value(at: "/items/1") == "b")

        #expect(store.value(at: "/items/0") == "a")
        store.set("edited", at: "/items/00")
        #expect(store.value(at: "/items/0") == "edited")
        #expect(store.value(at: "/items/0") == store.peek(at: "/items/0"))
    }

    // MARK: 4. Array-aware state merge

    @Test func streamedArrayItemsSurviveEdits() {
        let merged = StateMerge.merge(
            current: ["items": [["name": "typed"]]],
            oldSeed: ["items": [["name": ""]]],
            newSeed: ["items": [["name": "", "age": 0], ["name": "new"]]]
        )
        #expect(merged == ["items": [["name": "typed", "age": 0], ["name": "new"]]])

        let withUserItem = StateMerge.merge(
            current: ["tags": ["seeded", "mine"]], oldSeed: ["tags": ["seeded"]], newSeed: ["tags": ["seeded", "streamed"]]
        )
        #expect(withUserItem == ["tags": ["seeded", "mine", "streamed"]])
    }

    // MARK: 5. Validation reconciles with spec-only updates

    @Test func specUpdatesReconcileValidation() {
        let session = FormSession(spec: nameForm())
        session.validateAll()
        #expect(session.validation.field("/name").errors == ["Need 5"])

        session.spec = nameForm(min: 2)
        #expect(session.validation.field("/name").errors.isEmpty, "changed checks re-validate")

        session.spec = Spec(json: nameForm().json.setting(["type": "Form", "children": []], at: "/elements/form"))
        #expect(!session.validation.field("/name").validated, "removed field clears state")
        session.spec = nameForm()
        #expect(!session.validation.field("/name").validated)
    }

    // MARK: 6. resetForm fires watchers

    @Test func resetFormFiresWatchers() async {
        let session = FormSession(spec: nameForm(extraElements: watcher(
            ["action": "setState", "params": ["statePath": "/derived", "value": "fired"]]
        )))
        session.store.set("changed", at: "/name")
        await settle()
        session.store.set("fresh", at: "/derived")
        session.resetForm(statePath: "/name")
        await settle()
        #expect(session.store.peek(at: "/name") == "abc")
        #expect(session.store.peek(at: "/derived") == "fired")
    }

    // MARK: 7. UTF-16 string equality

    @Test func stringsCompareByCodeUnits() {
        let composed = "\u{E9}", decomposed = "e\u{301}"
        #expect(JSONValue.string(composed) != .string(decomposed))
        #expect(!Validation.runCheck(
            ValidationCheck(type: "matches", args: ["other": .string(decomposed)], message: ""),
            value: .string(composed), state: JSONValue.object([:])
        ).valid)
        let state: JSONValue = ["name": .string(composed)]
        #expect(!Visibility.evaluate(["$state": "/name", "eq": .string(decomposed)], state: state))

        let store = StateStore(initialState: state)
        let changes = Recorder<[String]>()
        store.addObserver { changes.values.append($0.pointers) }
        store.set(.string(decomposed), at: "/name")
        #expect(store.peek(at: "/name")?.stringValue.map { Array($0.utf16) } == [101, 769])
        #expect(changes.values == [["/name"]])
    }

    // MARK: 8. Same-reference container equality

    @Test func containersFromTheSameStateLocationAreEqual() {
        let state: JSONValue = ["a": [1], "b": [1], "list": [[1], [1]], "o": ["k": 1]]
        #expect(Visibility.evaluate(["$state": "/a", "eq": ["$state": "/a"]], state: state))
        #expect(!Visibility.evaluate(["$state": "/a", "neq": ["$state": "/a"]], state: state))
        #expect(Visibility.evaluate(["$state": "/list/1", "eq": ["$state": "/list/01"]], state: state))
        #expect(Visibility.evaluate(["$state": "/o", "eq": ["$state": "/o"]], state: state))
        #expect(!Visibility.evaluate(["$state": "/a", "eq": ["$state": "/b"]], state: state), "distinct arrays")
        #expect(!Visibility.evaluate(["$state": "/list/0", "eq": ["$state": "/list/1"]], state: state))
        #expect(!Visibility.evaluate(["$state": "/a", "eq": [1]], state: state), "literal array")

        let matches = ValidationCheck(type: "matches", args: ["other": ["$state": "/a"]], message: "")
        #expect(Validation.runCheck(matches, value: state.value(at: "/a"), state: state, valuePointer: "/a").valid)
        #expect(!Validation.runCheck(matches, value: state.value(at: "/b"), state: state, valuePointer: "/b").valid)
        #expect(!Validation.runCheck(matches, value: state.value(at: "/a"), state: state).valid, "no provenance")
    }

    // MARK: 9. JavaScript regex semantics

    @Test("pattern uses JavaScript semantics", arguments: [
        (#"^\d{3}$"#, "١٢٣", false), (#"^\d{3}$"#, "123", true), (#"^\w+$"#, "é", false),
        (#"^\s$"#, "\u{A0}", true), (#"\bcat\b"#, "écat", true), ("^abc$", "abc\n", false),
        ("^.$", "\u{85}", true), ("(?i)abc", "abc", false), (#"^\a$"#, "a", true), ("[]", "a", false),
        ("^[^]$", "\n", true), ("a{", "a{", true), (#"^\p{L}$"#, "p{L}", true), ("a*+", "aaa", false),
        (#"^[\d-]+$"#, "1-2", true), (#"^\u0041$"#, "A", true), (#"^\x41$"#, "A", true),
        (#"^[\b]$"#, "\u{08}", true), (#"^\v$"#, "\u{0B}", true), (#"^\0$"#, "\u{00}", true),
        (#"^(?<y>\d{4})-\k<y>$"#, "2025-2025", true), (#"^\cJ$"#, "\n", true), ("a}", "a}", true),
        (#"^[^\d]$"#, "5", false), (#"^[\D]$"#, "x", true), (#"^\/$"#, "/", true),
        ("^[a-z]{2,3}$", "abc", true), (#"(?<=\$)\d+"#, "$42", true), (#"^[0-9]{5}$"#, "12345", true),
        ("(", "x", false), (#"abc\"#, "abc", false),
    ])
    func jsPattern(_ pattern: String, _ input: String, _ expected: Bool) {
        let check = ValidationCheck(type: "pattern", args: ["pattern": .string(pattern)], message: "")
        #expect(Validation.runCheck(check, value: .string(input), state: JSONValue.object([:])).valid == expected)
    }

    // MARK: 10. file: URLs

    @Test("file URLs are parsed", arguments: [
        ("file://example.com:999999/x", false), ("file:///etc/hosts", true), ("file://user@host/x", false),
        ("file://[::1/x", false), ("file://[::1]/x", true), ("file://C:/x", true), ("file:foo", true),
        ("file://localhost/x", true), ("file://exa mple/x", false), ("file://host:80/x", false),
        ("file://1.2.3.256/x", false), (#"file:\\server\share"#, true),
    ])
    func fileURL(_ url: String, _ valid: Bool) {
        let check = ValidationCheck(type: "url", message: "")
        #expect(Validation.runCheck(check, value: .string(url), state: JSONValue.object([:])).valid == valid)
    }

    // MARK: 11. Zone-less date-times on DST transition days

    @Test func zonelessDateTimesKeepWallClockTimeAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        for text in ["2026-03-08T09:15", "2026-11-01T09:15", "2026-03-08T09:15:30", "2026-11-01T23:59:59.5"] {
            let date = try #require(ISODate.parse(text, calendar: calendar), "\(text)")
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            let expected = text.split(separator: "T")[1].split(separator: ":").map { Int(Double($0)!) }
            #expect([parts.hour, parts.minute] == [expected[0], expected[1]], "\(text)")
            if expected.count == 3 { #expect(parts.second == expected[2]) }
        }
        let gap = try #require(ISODate.parse("2026-03-08T02:30", calendar: calendar))
        #expect(calendar.component(.hour, from: gap) == 3, "nonexistent times move forward")
        #expect(ISODate.parse("2025-02-31", calendar: calendar) == nil)
        #expect(ISODate.parse("2025-02-31T10:00", calendar: calendar) == nil)
        #expect(ISODate.parse("2025-06-01T24:00", calendar: calendar) == nil)
    }
}
