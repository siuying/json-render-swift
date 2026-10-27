import SwiftUI
import Testing
@testable import JSONRenderSwiftUI

@Suite("Chart data")
struct ChartDataTests {
    static let files = Fixtures.files(in: "charts", withExtension: "json")

    /// The chart element's props of a `fixtures/charts` spec, resolved against its state.
    static func props(_ name: String) throws -> Props {
        let spec = Spec(json: try Fixtures.json("charts/\(name).json"))
        let chart = try #require(spec.elements["chart"])
        return Props(Expressions.resolveProps(chart.props, state: spec.state ?? .object([:])))
    }

    @Test func areaSeriesSummedByDay() throws {
        let data = ChartData(props: try Self.props("area-date-series"))
        #expect(data.points.map(\.label) == ["Mar 01", "Mar 02", "Mar 03", "Mar 04", "Mar 05"])
        #expect(data.points.map(\.value) == [215, 180, 300, 150, 310])
    }

    @Test func inlineRecordsInDataOrder() throws {
        let data = ChartData(props: try Self.props("bar-inline"))
        #expect(data.points.map(\.label) == ["Jan", "Feb", "Mar", "Apr", "May", "Jun"])
        #expect(data.points.map(\.value) == [4200, 3800, 5100, 4700, 6200, 5900], "numeric string \"4700\"")
        #expect(data.points.map(\.id) == Array(0..<6))
        #expect(data.valueKey == "revenue")
    }

    @Test func stateRecordsSummedByCategory() throws {
        let data = ChartData(props: try Self.props("bar-state-aggregate"))
        // Sorted by key; "n/a" counts as 0 and "450.50" parses.
        #expect(data.points.map(\.label) == ["East", "North", "West"])
        #expect(data.points.map(\.value) == [1450, 300, 1650.5])
        #expect(data.valueKey == "amount")
    }

    @Test func datesGroupedByDayAndCounted() throws {
        // `data` is `{ "data": [...] }` in this fixture.
        let data = ChartData(props: try Self.props("line-date-series"))
        #expect(data.points.map(\.label) == ["Mar 01", "Mar 02", "Mar 03", "Mar 04", "Mar 05"])
        #expect(data.points.map(\.value) == [1, 3, 2, 1, 4])
        #expect(data.valueKey == "count")
    }

    @Test func emptyStateArray() throws {
        let data = ChartData(props: try Self.props("line-empty"))
        #expect(data.isEmpty)
        #expect(data.valueKey == "count")
    }

    @Test func separateCategoryLabels() {
        let props = Props(["data": [["key": "a", "label": "Alpha", "value": 3], ["key": "b", "label": "Beta", "value": 5]], "xKey": "key", "yKey": "value", "labelKey": "label"])
        let data = ChartData(props: props)
        #expect(data.points.map(\.label) == ["Alpha", "Beta"])
        #expect(data.points.map(\.value) == [3, 5])
    }

    @Test func categoryCapKeepsTopValuesInDisplayOrder() {
        let props = Props(["data": [["x": "b", "y": 4], ["x": "a", "y": 2], ["x": "c", "y": 8]], "xKey": "x", "yKey": "y", "maxCategories": 2, "otherLabel": "Rest"])
        let bars = ChartData(props: props)
        #expect(bars.points.map(\.label) == ["c", "Rest"])
        #expect(bars.points.map(\.value) == [8, 6])
        let pie = PieChartData(props: Props(["data": props["data"]!, "nameKey": "x", "valueKey": "y", "maxCategories": 2]))
        #expect(pie.slices.map(\.label) == ["c", "Other"])
        #expect(pie.slices.map(\.value) == [8, 6])
        #expect(abs(pie.slices[1].fraction - 6.0 / 14) < 0.00001)
        let all = ChartData(props: Props(["data": props["data"]!, "xKey": "x", "yKey": "y", "maxCategories": 1]))
        #expect(all.points.map(\.value) == [14])
    }

    @Test func capRunsAfterAggregationAndKeepsExistingOtherSeparate() {
        let rows: JSONValue = [["x": "z", "y": 10], ["x": "Other", "y": 20], ["x": "b", "y": 3], ["x": "b", "y": 5]]
        let props = Props(["data": rows, "xKey": "x", "yKey": "y", "aggregate": "avg", "maxCategories": 2])
        let data = ChartData(props: props)
        #expect(data.points.map(\.label) == ["Other", "Other"])
        #expect(data.points.map(\.value) == [20, 6])
        #expect(data.points[1].records.count == 3)
        let pie = PieChartData(props: Props(["data": rows, "nameKey": "x", "valueKey": "y", "aggregate": "avg", "maxCategories": 2]))
        #expect(pie.slices.map(\.value) == [20, 6])
        #expect(pie.slices.map(\.label) == ["Other", "Other"])
    }

    @Test func capBreaksTiesByOriginalOrderAndWeightsAveragesByRows() {
        let rows: JSONValue = [["x": "a", "y": 4], ["x": "a", "y": 8], ["x": "b", "y": 10], ["x": "c", "y": 2]]
        let props = Props(["data": rows, "xKey": "x", "yKey": "y", "aggregate": "avg", "maxCategories": 2])
        let bars = ChartData(props: props)
        #expect(bars.points.map(\.label) == ["b", "Other"])
        #expect(abs(bars.points[1].value - 14.0 / 3) < 0.00001)
        let pie = PieChartData(props: Props(["data": rows, "nameKey": "x", "valueKey": "y", "aggregate": "avg", "maxCategories": 2]))
        #expect(pie.slices.map(\.label) == ["b", "Other"])
        #expect(abs(pie.slices[1].value - 14.0 / 3) < 0.00001)
        let ties = ChartData(props: Props(["data": [["x": "a", "y": 9], ["x": "b", "y": 1], ["x": "c", "y": 9], ["x": "d", "y": 10]], "xKey": "x", "yKey": "y", "maxCategories": 3]))
        #expect(ties.points.map(\.label) == ["a", "d", "Other"])
        #expect(ties.points.map(\.value) == [9, 10, 10])
    }

    @Test func capHandlesInvalidLimitsAndOverflow() {
        let rows: JSONValue = [["x": "a", "y": 1.5e308], ["x": "b", "y": 1.5e308], ["x": "c", "y": -1.5e308]]
        for limit: JSONValue in [0, -1, 1.5, "2", 3, 1e308] {
            #expect(ChartData(props: Props(["data": rows, "xKey": "x", "yKey": "y", "maxCategories": limit])).points.count == 3)
        }
        #expect(ChartData(props: Props(["data": rows, "xKey": "x", "yKey": "y", "maxCategories": 1])).points.map(\.value) == [1.5e308])
        let pie = PieChartData(props: Props(["data": rows, "nameKey": "x", "valueKey": "y", "maxCategories": 1]))
        #expect(pie.slices.map(\.fraction) == [1])
        #expect(pie.slices[0].value == Double.greatestFiniteMagnitude)
    }

    @Test func averages() {
        let records: [JSONValue] = [
            ["team": "a", "score": 1], ["team": "b", "score": "4"], ["team": "a", "score": 2], ["team": "a", "score": true],
        ]
        let data = ChartData(records: records, xKey: "team", yKey: "score", aggregate: .avg)
        #expect(data.points.map(\.label) == ["a", "b"])
        #expect(data.points.map(\.value) == [1, 4], "booleans count as 0")
    }

    @Test func aggregatesNeverOverflow() {
        let records: [JSONValue] = [["x": "a", "y": 1.5e308], ["x": "a", "y": 1.5e308], ["x": "b", "y": -1.5e308], ["x": "b", "y": -1.5e308]]
        let sum = ChartData(records: records, xKey: "x", yKey: "y", aggregate: .sum)
        #expect(sum.points.map(\.value) == [.greatestFiniteMagnitude, -.greatestFiniteMagnitude])
        let avg = ChartData(records: records, xKey: "x", yKey: "y", aggregate: .avg)
        #expect(avg.points.map(\.value) == [1.5e308, -1.5e308])
    }

    @Test func overflowingPartialSumsKeepTheirCancellation() {
        let values: [Double] = [1.5e308, 1.5e308, -1.5e308]
        for order in [values, values.reversed(), [1.5e308, -1.5e308, 1.5e308]] {
            let records = order.map { JSONValue.object(["x": "a", "y": .number($0)]) }
            #expect(ChartData(records: records, xKey: "x", yKey: "y", aggregate: .sum).points.first?.value == 1.5e308, "\(order)")
            #expect(ChartData(records: records, xKey: "x", yKey: "y", aggregate: .avg).points.first?.value == 5e307, "\(order)")
        }
        // Ordinary sums are the plain sum (no rescaling error).
        let plain = [0.1, 0.2, 0.3].map { JSONValue.object(["x": "a", "y": .number($0)]) }
        #expect(ChartData(records: plain, xKey: "x", yKey: "y", aggregate: .sum).points.first?.value == 0.1 + 0.2 + 0.3)
        #expect(ChartData(records: plain, xKey: "x", yKey: "y", aggregate: .avg).points.first?.value == (0.1 + 0.2 + 0.3) / 3)
    }

    @Test func missingCategoriesAndValues() {
        let records: [JSONValue] = [["y": 1], ["x": nil, "y": 2], ["x": 3, "y": "abc"], ["x": "z", "y": "7px"], "junk"]
        let plain = ChartData(records: records, xKey: "x", yKey: "y", aggregate: nil)
        #expect(plain.points.map(\.label) == ["", "", "z"], "non-numeric values are skipped, missing x reads as \"\"")
        #expect(plain.points.map(\.value) == [1, 2, 7])
        let counted = ChartData(records: records, xKey: "x", yKey: "y", aggregate: .count)
        #expect(counted.points.map(\.label) == ["3", "unknown", "z"])
        #expect(counted.points.map(\.value) == [1, 3, 1])
    }

    @Test func dateLabelsWithoutAggregate() {
        let records: [JSONValue] = [["d": "2025-12-31", "v": 1], ["d": "2025-01-05T23:59:00-08:00", "v": 2], ["d": "soon", "v": 3]]
        let data = ChartData(records: records, xKey: "d", yKey: "v", aggregate: nil)
        #expect(data.points.map(\.label) == ["Dec 31", "Jan 05", "soon"])
        // Not dates: only the first record decides.
        let notDates = ChartData(records: [["d": "2025-13-01", "v": 1]], xKey: "d", yKey: "v", aggregate: nil)
        #expect(notDates.points.map(\.label) == ["2025-13-01"])
    }

    @Test func recordsFromData() {
        #expect(ChartData.records(from: [["a": 1]]).count == 1)
        #expect(ChartData.records(from: ["data": [["a": 1], ["a": 2]]]).count == 2)
        #expect(ChartData.records(from: ["rows": [["a": 1]]]).isEmpty)
        #expect(ChartData.records(from: "x").isEmpty)
        #expect(ChartData.records(from: nil).isEmpty)
    }

    @Test func height() {
        #expect(ChartData.height(Props([:])) == 300)
        #expect(ChartData.height(Props(["height": nil])) == 300)
        #expect(ChartData.height(Props(["height": 240])) == 240)
        #expect(ChartData.height(Props(["height": 50])) == 200)
    }

    @Test func parseFloat() {
        #expect(JS.parseFloat("12.5abc") == 12.5)
        #expect(JS.parseFloat("  7 ") == 7)
        #expect(JS.parseFloat("1e3") == 1000)
        #expect(JS.parseFloat("1e") == 1)
        #expect(JS.parseFloat(".5") == 0.5)
        #expect(JS.parseFloat("-2.") == -2)
        #expect(JS.parseFloat("-Infinityx") == -.infinity)
        #expect(JS.parseFloat("$5") == nil)
        #expect(JS.parseFloat("-") == nil)
        #expect(JS.parseFloat("") == nil)
    }

    @Test func hexColors() {
        #expect(Color(chartHex: "#2563eb") != nil)
        #expect(Color(chartHex: "#abc") != nil)
        #expect(Color(chartHex: "#2563eb80") != nil)
        #expect(Color(chartHex: "blue") == nil)
        #expect(Color(chartHex: "#12345") == nil)
        #expect(Color(chartHex: nil) == nil)
    }

    @Test func registeredAsStandardComponents() {
        for type in ["BarChart", "LineChart", "AreaChart", "PieChart"] {
            #expect(ComponentRegistry.standard.renderer(for: type) != nil, "\(type)")
        }
    }

    @Test func wrappedInlineDataValidatesInBothCatalogs() async throws {
        let bridge = try #require(BridgeTests.bridge)
        for (type, nameKey, valueKey) in [
            ("BarChart", "xKey", "yKey"), ("LineChart", "xKey", "yKey"), ("AreaChart", "xKey", "yKey"),
            ("PieChart", "nameKey", "valueKey"),
        ] {
            let chart: JSONValue = [
                "type": .string(type),
                "props": ["data": ["data": [["x": "a", "y": 1]]], .init(nameKey): "x", .init(valueKey): "y"],
                "children": [],
            ]
            let form = Spec(json: ["root": "f", "elements": [
                "f": ["type": "Form", "props": [:], "children": ["s"]],
                "s": ["type": "Section", "props": [:], "children": ["c"]],
                "c": chart,
            ]])
            let document = Spec(json: ["root": "d", "elements": [
                "d": ["type": "Document", "props": [:], "children": ["p"]],
                "p": ["type": "Page", "props": [:], "children": ["c"]],
                "c": chart,
            ]])
            let forms = try await bridge.validateSpec(form)
            let pdf = try await bridge.validateSpec(document, catalog: .pdf)
            #expect(forms.valid, "\(type): \(forms.issues.map(\.message))")
            #expect(pdf.valid, "\(type): \(pdf.issues.map(\.message))")
        }
    }

    @Test("chart fixtures validate", arguments: files)
    func fixturesValidate(_ path: String) async throws {
        let bridge = try #require(BridgeTests.bridge)
        let validation = try await bridge.validateSpec(Spec(json: try Fixtures.json(path)))
        #expect(validation.valid, "\(validation.issues.map(\.message))")
    }
}

/// Draws charts with `ImageRenderer`, which runs Swift Charts' scale and axis computation.
@Suite("Chart rendering")
@MainActor
struct ChartRenderingTests {
    private func image(_ data: JSONValue, kind: ChartComponent.Kind) -> CGImage? {
        let element = Element(json: ["type": "BarChart", "props": [:], "children": []])!
        let context = ComponentContext(
            key: "c", element: element, props: Props(["data": data, "xKey": "x", "yKey": "y"]),
            session: FormSession(), bindings: [:], ancestors: [], localValues: .constant([:])
        )
        let renderer = ImageRenderer(content: ChartComponent(context: context, kind: kind).frame(width: 320))
        return renderer.cgImage
    }

    @Test(arguments: [
        [0.001, 0.004, 0.0025],
        [1e308, -1e308],
        [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude],
    ])
    func rendersSmallAndExtremeValues(_ values: [Double]) {
        let data = JSONValue.array(values.enumerated().map { ["x": .string("p\($0)"), "y": .number($1)] })
        for kind in [ChartComponent.Kind.bar, .line, .area] {
            #expect(image(data, kind: kind) != nil, "\(kind)")
        }
    }

    @Test func ordinaryValuesArePlottedAsTheyAre() {
        for values: [Double] in [[1, 2, 3], [-40, 0.001], [8e307, 5], [-8e307], [4e307, -4e307]] {
            let scale = ChartValueScale(values)
            #expect(!scale.isScaled, "\(values)")
            #expect(values.map(scale.plotted) == values)
        }
    }

    @Test func overflowingRangesKeepRelativeValuesAndLabels() {
        let values: [Double] = [5e307, 1e308, -1e308, .greatestFiniteMagnitude]
        let scale = ChartValueScale(values)
        #expect(scale.isScaled)
        let plotted = values.map(scale.plotted)
        #expect(plotted[0] / plotted[1] == 0.5, "5e307 stays half of 1e308")
        #expect(plotted.map { $0 * scale.divisor } == values, "exact")
        let lower = min(plotted.min()!, 0), upper = max(plotted.max()!, 0)
        #expect((upper - lower).isFinite)
        #expect(scale.label(plotted[0]) == "5E307")
        #expect(scale.label(plotted[2]) == "-1E308")
        #expect(scale.label(0) == "0")
        #expect(scale.label(scale.plotted(2.5e307)) == "2.5E307")
        #expect(ChartValueScale([1.7e308]).isScaled, "headroom: spans past half the largest Double are scaled")
    }
}
