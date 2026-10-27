@testable import FormDemo
import JSONRenderSwiftUI
import Testing

@Suite("Chart examples")
@MainActor
struct ChartExampleTests {
    @Test(arguments: ["chart-interactions", "chart-composition", "chart-live"])
    func bundledExamplesValidate(_ name: String) async throws {
        let example = try #require(ExampleSpec.named(name, kind: .form))
        let spec = try example.load()
        let result = try await JSONRenderBridge().validateSpec(spec)
        #expect(result.valid, "\(result.issues.map(\.message))")
    }

    @Test func chartPressUpdatesTheDisplayedDatum() async throws {
        let spec = try #require(ExampleSpec.named("chart-interactions", kind: .form)).load()
        let session = FormSession(spec: spec)
        let datum: JSONValue = ["index": 0, "label": "West", "value": 12, "records": [["region": "West", "sales": 12]]]
        await session.emit("press", from: "chart", datum: datum)
        #expect(session.store.value(at: "/selected") == datum)
        let props = try #require(spec.elements["selection"]?.props)
        let resolved = Expressions.resolveProps(props, state: session.store.state)
        #expect(resolved["content"] == "Tapped datum: West, value 12")
    }
}
