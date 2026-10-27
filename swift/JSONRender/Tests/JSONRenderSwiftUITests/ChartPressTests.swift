import SwiftUI
import Testing
@testable import JSONRenderSwiftUI

@Suite("Chart press")
@MainActor
struct ChartPressTests {
    @Test func cappedDatumContainsEverySourceRecord() {
        let data = ChartData(props: Props(["xKey": "x", "yKey": "y", "maxCategories": 1, "data": [["x": "a", "y": 2, "extra": "keep"], ["x": "b", "y": 3]]]))
        #expect(data.points[0].datum == ["index": 0, "label": "Other", "value": 5, "records": [["x": "a", "y": 2, "extra": "keep"], ["x": "b", "y": 3]]])
        let pie = PieChartData(props: Props(["nameKey": "x", "valueKey": "y", "aggregate": "sum", "data": [["x": "a", "y": 2], ["x": "a", "y": 3]]]))
        #expect(pie.slices[0].datum["records"]?.arrayValue?.count == 2)
        #expect(pie.slices[0].datum["fraction"] == 1)
    }

    @Test func pressingDatumResolvesWholeObjectAndPaths() async throws {
        let spec = Spec(json: ["root": "chart", "elements": ["chart": ["type": "BarChart", "props": [:], "on": ["press": ["action": "setState", "params": ["statePath": "/selected", "value": ["$datum": ""]]]]]]])
        let session = FormSession(spec: spec)
        let datum: JSONValue = ["label": "West", "value": 4]
        let element = try #require(spec.elements["chart"])
        let context = ComponentContext(key: "chart", element: element, props: Props([:]), session: session, bindings: [:], ancestors: [], localValues: .constant([:]))
        context.emit("press", datum: datum)
        for _ in 0..<50 where session.store.value(at: "/selected") == nil { await Task.yield() }
        #expect(session.store.value(at: "/selected") == datum)
    }

    @Test func pieSelectionHonorsSliceBoundaries() {
        let pie = PieChartData(records: [["n": "a", "v": 1], ["n": "b", "v": 3]], nameKey: "n", valueKey: "v", aggregate: nil)
        #expect(pie.slice(at: 0)?.label == "a")
        #expect(pie.slice(at: 0.249)?.label == "a")
        #expect(pie.slice(at: 0.25)?.label == "b")
        #expect(pie.slice(at: 0.99)?.label == "b")
        #expect(pie.slice(at: -1) == nil)
        #expect(pie.slice(at: .nan) == nil)
    }
}
