import Testing
@testable import JSONRenderSwiftUI

@Suite("Chart data options")
struct ChartDataOptionsTests {
    @Test func explicitOtherUsesTruthyFlagsWithoutChangingOrderOrLegacyData() {
        let flags: [JSONValue] = [true, 1, "yes", [], [:], false, 0, "", .null]
        let rows = JSONValue.array(flags.enumerated().map { index, flag in
            ["x": .string("Row \(index)"), "y": 2, "rest": flag]
        })
        let props: [String: JSONValue] = ["data": rows, "xKey": "x", "yKey": "y", "nameKey": "x", "valueKey": "y", "otherKey": "rest"]
        let data = ChartData(props: Props(props))
        let pie = PieChartData(props: Props(props))
        #expect(data.points.map(\.isOther) == [true, true, true, true, true, false, false, false, false])
        #expect(pie.slices.map(\.isOther) == data.points.map(\.isOther))
        #expect(data.points.map(\.label) == (0..<9).map { "Row \($0)" })
        #expect(pie.slices.map(\.label) == data.points.map(\.label))
        #expect(data.points[0].datum["isOther"] == true)
        #expect(pie.slices[0].datum["isOther"] == true)
        #expect(data.points[0].datum["records"]?[0]?["rest"] == true)
        let legacy = ChartData(props: Props(props.filter { $0.key != "otherKey" }))
        #expect(legacy.points.allSatisfy { !$0.isOther && $0.datum["isOther"] == nil })
    }

    @Test func capReservesOneOtherSlotEvenWhenExplicitOtherIsLargest() {
        let rows: JSONValue = [["x": "A", "y": 12], ["x": "B", "y": 8], ["x": "C", "y": 4], ["x": "Rest", "y": 100, "rest": true]]
        let base: [String: JSONValue] = ["data": rows, "xKey": "x", "yKey": "y", "nameKey": "x", "valueKey": "y", "otherKey": "rest"]
        for cap in [1, 2, 3, 4] {
            let props = Props(base.merging(["maxCategories": .number(Double(cap))]) { _, new in new })
            let data = ChartData(props: props)
            let pie = PieChartData(props: props)
            #expect(data.points.count == cap)
            #expect(data.points.filter(\.isOther).count == 1)
            #expect(data.points.last?.isOther == true)
            #expect(data.points.map(\.value) == Array([12.0, 8, 4].prefix(cap - 1)) + [[124.0, 112, 104, 100][cap - 1]])
            #expect(pie.slices.map(\.value) == data.points.map(\.value))
            #expect(pie.slices.last?.datum["isOther"] == true)
            #expect(data.points.last?.records.count == 5 - cap)
        }
    }

    @Test func groupedOtherAndAverageCapUseContributingRows() {
        let rows: JSONValue = [["x": "A", "y": 12], ["x": "A", "y": 8], ["x": "B", "y": 4], ["x": "Rest", "y": 2, "rest": true], ["x": "Rest", "y": 6]]
        for aggregate: JSONValue in ["sum", "avg", "count"] {
            let props = Props(["data": rows, "xKey": "x", "yKey": "y", "nameKey": "x", "valueKey": "y", "otherKey": "rest", "aggregate": aggregate, "maxCategories": 2])
            let data = ChartData(props: props)
            let pie = PieChartData(props: props)
            #expect(data.points.map(\.label) == ["A", "Other"])
            #expect(data.points.map(\.isOther) == [false, true])
            #expect(data.points.last?.value == (aggregate == "avg" ? 4 : aggregate == "count" ? 3 : 12))
            #expect(pie.slices.map(\.value) == data.points.map(\.value))
        }
    }

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
