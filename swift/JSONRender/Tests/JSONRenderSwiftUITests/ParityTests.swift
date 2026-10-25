import Foundation
import Testing
@testable import JSONRenderSwiftUI

/// Asserts the native runtime against expectations generated from `@json-render/core`
/// (`fixtures/parity/*.json`).
@Suite("Core parity")
struct ParityTests {
    @Test("fixtures are present")
    func fixturesPresent() {
        #expect(!Fixtures.parityCases("expressions").isEmpty)
        #expect(!Fixtures.parityCases("visibility").isEmpty)
        #expect(!Fixtures.parityCases("validation").isEmpty)
    }

    @Test("expressions", arguments: Fixtures.parityCases("expressions"))
    func expressions(_ testCase: ParityCase) throws {
        let state = testCase.state
        var undefinedPaths: [String] = []
        switch testCase["fn"]?.stringValue {
        case "resolvePropValue":
            let resolved = Expressions.resolve(testCase["value"] ?? .null, state: state, at: "", undefinedPaths: &undefinedPaths)
            if resolved == nil { undefinedPaths.append("") }
            if testCase["undefined"] == .bool(true) {
                #expect(resolved == nil)
            } else {
                #expect(resolved == testCase["expected"])
            }
        case "resolveElementProps":
            let props = try #require(testCase["props"]?.objectValue)
            let resolved = Expressions.resolve(.object(props), state: state, at: "", undefinedPaths: &undefinedPaths)
            #expect(resolved == testCase["expected"])
            #expect(JSONValue.object(Expressions.resolveProps(props, state: state)) == testCase["expected"])
            let bindings = Expressions.bindings(in: props)
            let expectedBindings = testCase["bindings"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
            #expect(bindings == expectedBindings)
        case let fn:
            Issue.record("Unknown parity fn \(fn ?? "nil")")
        }
        let expectedUndefined = testCase["undefinedPaths"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(undefinedPaths.sorted() == expectedUndefined.sorted(), "undefined vs null")
    }

    @Test("visibility", arguments: Fixtures.parityCases("visibility"))
    func visibility(_ testCase: ParityCase) {
        let visible = Visibility.evaluate(testCase["condition"], state: testCase.state)
        #expect(.bool(visible) == testCase["expected"])
    }

    @Test("validation", arguments: Fixtures.parityCases("validation"))
    func validation(_ testCase: ParityCase) throws {
        let config = ValidationConfig(json: testCase["config"] ?? .object([:]))
        let result = Validation.run(config, value: testCase["value"], state: testCase.state)
        let expected = try #require(testCase["expected"])
        #expect(.bool(result.valid) == expected["valid"])
        #expect(.array(result.errors.map(JSONValue.string)) == expected["errors"])
        let checks = result.checks.map { check -> JSONValue in
            ["type": .string(check.type), "valid": .bool(check.valid), "message": .string(check.message)]
        }
        #expect(.array(checks) == expected["checks"])
    }
}
