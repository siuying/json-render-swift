import Foundation
import Testing
@testable import JSONRenderSwiftUI

@Suite("JavaScript semantics")
struct JSSemanticsTests {
    @Test("Number → String", arguments: [
        (0.0, "0"), (-0.0, "0"), (1, "1"), (100, "100"), (1.5, "1.5"), (-2.25, "-2.25"),
        (0.1, "0.1"), (0.000001, "0.000001"), (0.0000001, "1e-7"), (1e21, "1e+21"),
        (1.2345678901234568e20, "123456789012345680000"), (1.7976931348623157e308, "1.7976931348623157e+308"),
        (5e-324, "5e-324"), (Double.nan, "NaN"), (Double.infinity, "Infinity"),
    ])
    func numberToString(value: Double, expected: String) {
        #expect(JS.numberToString(value) == expected)
    }

    @Test("String → Number")
    func stringToNumber() {
        #expect(JS.stringToNumber(" 42 ") == 42)
        #expect(JS.stringToNumber("") == 0)
        #expect(JS.stringToNumber("0x1F") == 31)
        #expect(JS.stringToNumber("1e3") == 1000)
        #expect(JS.stringToNumber(".5") == 0.5)
        #expect(JS.stringToNumber("-Infinity") == -.infinity)
        #expect(JS.stringToNumber("12px").isNaN)
        #expect(JS.stringToNumber("nan").isNaN)
        #expect(JS.stringToNumber("-0x10").isNaN)
    }

    @Test("ToString of containers and truthiness")
    func containers() {
        #expect(JS.toString(["a", 1, nil, ["b"]]) == "a,1,,b")
        #expect(JS.toString(["k": 1]) == "[object Object]")
        #expect(JS.isTruthy(.array([])))
        #expect(!JS.isTruthy(.number(.nan)))
        #expect(!JS.isTruthy(nil))
    }

    @Test("UTF-16 length and trim")
    func strings() {
        #expect(JS.length("😀") == 2)
        #expect(JS.trim("\u{FEFF}\u{00A0} hi \n") == "hi")
        #expect(JS.parseInt("12abc") == 12)
        #expect(JS.parseInt("abc") == nil)
    }
}

@Suite("JSON Pointer & StateStore")
@MainActor
struct PointerStateTests {
    let state: JSONValue = ["form": ["name": "Ada", "tags": ["a", "b"]], "a/b": 1, "m~n": 2]

    @Test func getByPath() {
        #expect(state.value(at: "/form/name") == "Ada")
        #expect(state.value(at: "/form/tags/1") == "b")
        #expect(state.value(at: "/form/tags/5") == nil)
        #expect(state.value(at: "/a~1b") == 1)
        #expect(state.value(at: "/m~0n") == 2)
        #expect(state.value(at: "") == state)
        #expect(state.value(at: "/form/name/length") == nil)
        #expect(state.value(at: "form/name") == "Ada")
    }

    @Test func setByPathCreatesContainers() {
        let next = state.setting("x", at: "/new/0/field")
        #expect(next.value(at: "/new") == [["field": "x"]])
        #expect(state.setting("c", at: "/form/tags/-").value(at: "/form/tags") == ["a", "b", "c"])
        #expect(state.setting(nil, at: "/form/name").value(at: "/form/name") == nil)
    }

    @Test func storeNotifiesObserversOnlyOnChange() {
        let store = StateStore(initialState: state)
        var changes: [[String]] = []
        store.addObserver { changes.append($0.pointers) }
        store.set("Ada", at: "/form/name")
        store.set("Grace", at: "/form/name")
        store.update([("/form/name", "Grace"), ("/count", 1)])
        #expect(changes == [["/form/name"], ["/count"]])
        #expect(store.peek(at: "/form/name") == "Grace")
    }

    @Test func pathObservationIsFineGrained() {
        let store = StateStore(initialState: state)
        let invalidations = Counter()
        withObservationTracking { _ = store.value(at: "/form/name") } onChange: { invalidations.increment() }
        store.set(3, at: "/count")
        store.set(["c"], at: "/form/tags")
        #expect(invalidations.value == 0)
        store.set(["name": "Grace"], at: "/form")
        #expect(invalidations.value == 1)
    }

    @Test func streamedStateMergePreservesUserEdits() {
        let merged = StateMerge.merge(
            current: ["form": ["email": "typed@example.com", "name": ""]],
            oldSeed: ["form": ["email": "", "name": ""]],
            newSeed: ["form": ["email": "", "name": "", "plan": "free"]]
        )
        #expect(merged == ["form": ["email": "typed@example.com", "name": "", "plan": "free"]])
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

@Suite("Expressions & visibility")
struct ExpressionVisibilityTests {
    let state: JSONValue = ["form": ["name": "Ada", "age": 36, "plan": "pro", "tags": ["a", "b"]]]

    @Test func resolvesNestedExpressions() {
        let value: JSONValue = [
            "greeting": ["$template": "Hi ${/form/name} (${form/age}) ${/missing}!"],
            "plan": ["$cond": ["$state": "/form/plan", "eq": "pro"], "$then": "Pro", "$else": "Free"],
            "list": [["$state": "/form/tags"], ["$state": "/missing"]],
            "dropped": ["$state": "/missing"],
            "repeatOnly": ["$item": "title"],
        ]
        #expect(Expressions.resolve(value, state: state) == [
            "greeting": "Hi Ada (36) !",
            "plan": "Pro",
            "list": [["a", "b"], nil],
        ])
    }

    @Test func templateEdgeCases() {
        #expect(Expressions.interpolate("${}${/form/tags}${", state: state) == "${}a,b${")
    }

    @Test func bindingsOnlyForBindState() {
        let props: [String: JSONValue] = ["value": ["$bindState": "/form/name"], "label": ["$state": "/form/name"]]
        #expect(Expressions.bindings(in: props) == ["value": "/form/name"])
    }

    @Test func visibilityOperators() {
        #expect(Visibility.evaluate(["$state": "/form/age", "gte": 18], state: state))
        #expect(!Visibility.evaluate(["$state": "/form/age", "gt": ["$state": "/form/name"]], state: state))
        #expect(Visibility.evaluate(["$or": [false, ["$state": "/form/plan", "eq": "pro"]]], state: state))
        #expect(!Visibility.evaluate([["$state": "/form/name"], ["$state": "/missing"]], state: state))
        #expect(Visibility.evaluate(["$state": "/missing", "not": true], state: state))
        #expect(!Visibility.evaluate(.string("nonsense"), state: state))
    }
}

@Suite("Validation")
struct ValidationTests {
    let state: JSONValue = ["form": ["password": "hunter22", "start": "2025-06-01"]]

    private func check(_ type: String, _ value: JSONValue?, args: [String: JSONValue] = [:]) -> Bool {
        Validation.runCheck(ValidationCheck(type: type, args: args, message: "x"), value: value, state: state).valid
    }

    @Test func builtInsMirrorCore() {
        #expect(Validation.builtInFunctions.keys.sorted() == [
            "email", "equalTo", "greaterThan", "lessThan", "matches", "max", "maxLength", "min",
            "minLength", "numeric", "pattern", "required", "requiredIf", "url",
        ])
        #expect(check("matches", "hunter22", args: ["other": ["$state": "/form/password"]]))
        #expect(!check("matches", "hunter2", args: ["other": ["$state": "/form/password"]]))
        #expect(check("greaterThan", "2025-07-01", args: ["other": ["$state": "/form/start"]]))
        #expect(check("lessThan", "3", args: ["other": 5]))
        #expect(!check("minLength", "😀", args: ["min": 3]))
        #expect(check("pattern", "12345", args: ["pattern": "^[0-9]{5}$"]))
        #expect(!check("pattern", "x", args: ["pattern": "("]))
        #expect(check("unknownType", nil))
        #expect(check("requiredIf", "", args: ["field": false]))
    }

    @Test("url", arguments: [
        ("https://example.com/path?q=1#f", true), ("mailto:someone@example.com", true),
        ("http://localhost:8080", true), ("foo:bar", true), ("http://[::1]/", true),
        ("not a url", false), ("https://", false), ("http://exa mple.com", false),
        ("example.com", false), ("http://example.com:99999", false), ("http://1.2.3.256", false),
    ])
    func url(_ value: String, valid: Bool) {
        #expect(check("url", .string(value)) == valid)
    }

    @Test func enabledGatesConfig() {
        let config = ValidationConfig(
            checks: [ValidationCheck(type: "required", message: "Required")],
            enabled: ["$state": "/form/missing"]
        )
        #expect(Validation.run(config, value: nil, state: state) == .passed)
    }

    @Test func customFunctions() {
        let config = ValidationConfig(checks: [ValidationCheck(type: "even", message: "Even")])
        let even: ValidationFunction = { value, _ in (value?.intValue ?? 1) % 2 == 0 }
        #expect(!Validation.run(config, value: 3, state: state, customFunctions: ["even": even]).valid)
    }
}
