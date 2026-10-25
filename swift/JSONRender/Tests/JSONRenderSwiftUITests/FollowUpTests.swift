import Foundation
import SwiftUI
import Testing
@testable import JSONRenderSwiftUI

@Suite("Demo-app follow-ups")
struct FollowUpTests {
    @Test func prettyJSONIsDisplayFriendly() {
        let value: JSONValue = ["b": [], "a": ["x": 1, "list": [1.5, "s\n\"q\"", nil, true]], "e": [:], "n": 1e21]
        #expect(value.jsonString(prettyPrinted: true) == """
        {
          "a": {
            "list": [
              1.5,
              "s\\n\\"q\\"",
              null,
              true
            ],
            "x": 1
          },
          "b": [],
          "e": {},
          "n": 1e+21
        }
        """)
        #expect(value.jsonString() == #"{"a":{"list":[1.5,"s\n\"q\"",null,true],"x":1},"b":[],"e":{},"n":1e+21}"#)
        #expect(JSONValue.string("a/b\u{01}é").jsonString() == #""a/b\u0001é""#)
        #expect(JSONValue.number(.nan).jsonString() == "null")
    }

    @Test func compactJSONRoundTrips() throws {
        let spec = try Fixtures.json("specs/registration.json")
        #expect(try JSONValue(jsonString: spec.jsonString()) == spec)
        #expect(try JSONValue(jsonString: spec.jsonString(prettyPrinted: true)) == spec)
    }

    @Test func hostActionsSuppressUnknownActionWarnings() async throws {
        let bridge = try #require(BridgeTests.bridge)
        let spec = Spec(json: [
            "root": "form",
            "elements": [
                "form": ["type": "Form", "props": [:], "children": ["a", "b"]],
                "a": ["type": "Button", "props": ["label": "A"], "on": ["press": ["action": "track"]], "children": []],
                "b": ["type": "Button", "props": ["label": "B"],
                      "on": ["press": [["action": "track"], ["action": "share"]]], "children": []],
            ],
        ])
        func unknownActions(_ validation: SpecValidation) -> [String] {
            validation.issues.filter { $0.code == "unknown_action" }.compactMap { $0.path }.sorted()
        }
        let all = try await bridge.validateSpec(spec)
        #expect(unknownActions(all).count == 3)
        let filtered = try await bridge.validateSpec(spec, hostActions: ["track"])
        #expect(unknownActions(filtered) == ["/elements/b/on/press/1/action"])
        #expect(filtered.valid == all.valid)
    }

    @Test func disposeFreesCompilerWithoutFlushing() async throws {
        let bridge = try #require(BridgeTests.bridge)
        let compiler = try await bridge.makeStreamCompiler()
        _ = try await compiler.push(#"{"op":"add","path":"/root","value":"x"}"#)
        await compiler.dispose()
        await compiler.dispose() // idempotent
        await #expect(throws: JSONRenderBridgeError.self) { try await compiler.push("\n") }
    }

    /// A fake bridge records `compilerDispose` calls, proving abandoned compilers are freed.
    @Test func releasedCompilersAreDisposed() async throws {
        let bridge = try JSONRenderBridge(script: """
        globalThis.disposed = [];
        globalThis.JSONRenderBridge = {
          invoke(method, argsJSON) {
            const args = JSON.parse(argsJSON);
            if (method === "createCompiler") return JSON.stringify({ result: 7 });
            if (method === "compilerDispose") { disposed.push(args[0]); return JSON.stringify({ result: null }); }
            if (method === "compilerFinish") return JSON.stringify({ result: {} });
            if (method === "version") return JSON.stringify({ result: JSON.stringify(disposed) });
            return JSON.stringify({ error: { message: "unexpected " + method } });
          }
        };
        """)
        do {
            let finished = try await bridge.makeStreamCompiler()
            _ = try await finished.finish()
        }
        do {
            _ = try await bridge.makeStreamCompiler() // released without finish/dispose
        }
        var disposed = ""
        for _ in 0..<100 where disposed != "[7]" {
            await Task.yield()
            disposed = try await bridge.version()
        }
        #expect(disposed == "[7]", "only the abandoned compiler is disposed")
    }

    @Test(arguments: [("segmented", true), ("menu", false), (nil, false)])
    @MainActor
    func segmentedPickerShowsFieldTitle(style: String?, showsTitle: Bool) {
        var props: [String: JSONValue] = [
            "label": "Plan", "selection": ["$bindState": "/plan"],
            "options": [["label": "Free", "value": "free"], ["label": "Pro", "value": "pro"]],
        ]
        props["style"] = style.map(JSONValue.string)
        let element = Element(type: "Picker", props: props)
        let session = FormSession(spec: Spec(json: [
            "root": "form",
            "elements": ["form": ["type": "Form", "children": ["plan"]], "plan": ["type": "Picker", "props": .object(props)]],
            "state": ["plan": "free"],
        ]))
        let context = ComponentContext(
            key: "plan", element: element, props: Props(Expressions.resolveProps(props, state: session.store)),
            session: session, bindings: Expressions.bindings(in: props), ancestors: [], localValues: .constant([:])
        )
        #expect(PickerComponent(context: context).showsFieldTitle == showsTitle)
    }
}
