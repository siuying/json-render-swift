import Testing
@testable import JSONRenderSwiftUI

@Suite("Chart data options")
struct ChartDataOptionsTests {
    @Test func showingMissingKeepsNullableDatumValuesAndNumericPositions() {
        let rows: JSONValue = [["x": "a", "y": 12], ["x": "b", "y": nil], ["x": "c", "y": "invalid"], ["x": "d", "y": "8.5"]]
        let defaults = ChartData(props: Props(["data": rows, "xKey": "x", "yKey": "y"]))
        #expect(defaults.points.count == 2)
        let shown = ChartData(props: Props(["data": rows, "xKey": "x", "yKey": "y", "missing": "show"]))
        #expect(shown.points.map(\.label) == ["a", "b", "c", "d"])
        #expect(shown.points.map { $0.datum["value"] ?? .null } == [12, .null, .null, 8.5])
        #expect(shown.points.allSatisfy { $0.value.isFinite })
        #expect(shown.points[1].records == [["x": "b", "y": nil]])
    }

    @Test func formatsProcessedValuesAndIdentifiesOnlyGeneratedOther() {
        let props = Props(["data": [["x": "Other", "y": 10], ["x": "b", "y": 2], ["x": "c", "y": 3]], "xKey": "x", "yKey": "y", "maxCategories": 2, "valueFormat": ["style": "currency", "currency": "HKD", "locale": "en_US"]])
        let data = ChartData(props: props)
        #expect(data.points.map(\.valueText) == ["HK$10.00", "HK$5.00"])
        #expect(data.points.map(\.isOther) == [false, true])
        #expect(data.points.map { $0.datum["value"] } == [10, 5])
        let pie = PieChartData(props: Props(["data": props["data"]!, "nameKey": "x", "valueKey": "y", "maxCategories": 2, "valueFormat": props["valueFormat"]!]))
        #expect(pie.slices.map(\.valueText) == ["HK$10.00", "HK$5.00"])
        #expect(pie.slices.map(\.isOther) == [false, true])
    }

    @Test func missingValuesSplitNumericLineSegmentsAndRemainMissingWhenFolded() {
        let rows: JSONValue = [["x": "a", "y": -2], ["x": "b", "y": nil], ["x": "c", "y": 3]]
        let shown = ChartData(props: Props(["data": rows, "xKey": "x", "yKey": "y", "missing": "show"]))
        #expect(shown.numericSegments.map { $0.map(\.label) } == [["a"], ["c"]])
        #expect(shown.points[1].valueText == "n/a")
        let capped = ChartData(props: Props(["data": rows, "xKey": "x", "yKey": "y", "missing": "show", "maxCategories": 2]))
        #expect(capped.points.map(\.label) == ["c", "Other"])
        #expect(capped.points[1].datum["value"] == -2)
        let missing = ChartData(props: Props(["data": [["x": "a", "y": nil], ["x": "b", "y": "bad"]], "xKey": "x", "yKey": "y", "missing": "show", "maxCategories": 1]))
        #expect(missing.points[0].datum["value"] == .null)
    }

    @Test func automaticHorizontalHeightTracksVisibleCategories() {
        let rows = JSONValue.array((0..<10).map { ["x": .string("Category \($0)"), "y": 1] })
        let props: [String: JSONValue] = ["data": rows, "xKey": "x", "yKey": "y", "horizontal": true]
        #expect(ChartData.height(Props(props)) == 372)
        #expect(ChartData.height(Props(props.merging(["height": 220]) { _, new in new })) == 220)
        #expect(ChartData.height(Props(props.merging(["maxCategories": 2]) { _, new in new })) == 200)
        #expect(ChartData.height(Props([:])) == 300)
    }
}
