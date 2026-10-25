import Foundation
import Testing
@testable import JSONRenderSwiftUI

/// `fixtures/parity/repeat.json`: repeat-scope cases generated from `@json-render/core`.
/// (`renderTree` cases are asserted by the JSONRenderPDF tests.)
@Suite("Core parity: repeat scope")
struct RepeatParityTests {
    static let cases = Fixtures.parityCases("repeat").filter { $0["fn"]?.stringValue != "renderTree" }

    static func scope(_ json: JSONValue?) -> RepeatScope? {
        guard let json, json.objectValue != nil else { return nil }
        return RepeatScope(item: json["item"], index: json["index"]?.intValue, basePath: json["basePath"]?.stringValue)
    }

    @Test func fixturesPresent() {
        #expect(Self.cases.count > 20)
    }

    @Test("repeat", arguments: cases)
    func repeatCase(_ testCase: ParityCase) throws {
        let state = testCase.state
        let scope = Self.scope(testCase["scope"])
        let expectsUndefined = testCase["undefined"] == .bool(true)
        func check(_ value: JSONValue?) {
            if expectsUndefined { #expect(value == nil) } else { #expect(value == testCase["expected"]) }
        }
        switch testCase["fn"]?.stringValue {
        case "resolvePropValue":
            var undefinedPaths: [String] = []
            let value = Expressions.resolve(testCase["value"], state: state, scope: scope, at: "", undefinedPaths: &undefinedPaths)
            if value == nil { undefinedPaths.append("") }
            check(value)
            let expected = testCase["undefinedPaths"]?.arrayValue?.compactMap(\.stringValue) ?? []
            #expect(undefinedPaths.sorted() == expected.sorted())
        case "resolveActionParam":
            check(Expressions.resolveActionParam(testCase["value"], state: state, scope: scope))
        case "resolveBindings":
            let props = try #require(testCase["props"]?.objectValue)
            let expected = testCase["expected"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
            #expect(Expressions.bindings(in: props, scope: scope) == expected)
        case "evaluateVisibility":
            #expect(.bool(Visibility.evaluate(testCase["condition"], state: state, scope: scope)) == testCase["expected"])
        case "resolveRepeatStatePath":
            let config = RepeatConfig(statePath: testCase["statePath"] ?? .null)
            let base = RepeatScope(item: nil, index: nil, basePath: testCase["basePath"]?.stringValue)
            check(config.resolvedStatePath(in: base).map(JSONValue.string))
        case "resolveRepeatItemStatePath":
            let path = try #require(testCase["statePath"]?.stringValue)
            let index = try #require(testCase["index"]?.intValue)
            check(.string(RepeatConfig.join(path, String(index))))
        case let fn:
            Issue.record("Unknown fn \(fn ?? "nil")")
        }
    }
}
