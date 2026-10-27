import SwiftUI
import Testing
@testable import JSONRenderSwiftUI

@Suite("Chart data")
struct ChartDataTests {
    static let files = Fixtures.files(in: "charts", withExtension: "json")

    /// The chart element's props of a `fixtures/charts` spec, resolved against its state.
    private func props(_ name: String) throws -> Props {
        let spec = Spec(json: try Fixtures.json("charts/\(name).json"))
        let chart = try #require(spec.elements["chart"])
        return Props(Expressions.resolveProps(chart.props, state: spec.state ?? .object([:])))
    }

    @Test func inlineRecordsInDataOrder() throws {
        let data = ChartData(props: try props("bar-inline"))
        #expect(data.points.map(\.label) == ["Jan", "Feb", "Mar", "Apr", "May", "Jun"])
        #expect(data.points.map(\.value) == [4200, 3800, 5100, 4700, 6200, 5900], "numeric string \"4700\"")
        #expect(data.points.map(\.id) == Array(0..<6))
        #expect(data.valueKey == "revenue")
    }

    @Test func stateRecordsSummedByCategory() throws {
        let data = ChartData(props: try props("bar-state-aggregate"))
        // Sorted by key; "n/a" counts as 0 and "450.50" parses.
        #expect(data.points.map(\.label) == ["East", "North", "West"])
        #expect(data.points.map(\.value) == [1450, 300, 1650.5])
        #expect(data.valueKey == "amount")
    }

    @Test func datesGroupedByDayAndCounted() throws {
        // `data` is `{ "data": [...] }` in this fixture.
        let data = ChartData(props: try props("line-date-series"))
        #expect(data.points.map(\.label) == ["Mar 01", "Mar 02", "Mar 03", "Mar 04", "Mar 05"])
        #expect(data.points.map(\.value) == [1, 3, 2, 1, 4])
        #expect(data.valueKey == "count")
    }

    @Test func emptyStateArray() throws {
        let data = ChartData(props: try props("line-empty"))
        #expect(data.isEmpty)
        #expect(data.valueKey == "count")
    }

    @Test func averages() {
        let records: [JSONValue] = [
            ["team": "a", "score": 1], ["team": "b", "score": "4"], ["team": "a", "score": 2], ["team": "a", "score": true],
        ]
        let data = ChartData(records: records, xKey: "team", yKey: "score", aggregate: .avg)
        #expect(data.points.map(\.label) == ["a", "b"])
        #expect(data.points.map(\.value) == [1, 4], "booleans count as 0")
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
        #expect(ComponentRegistry.standard.renderer(for: "BarChart") != nil)
        #expect(ComponentRegistry.standard.renderer(for: "LineChart") != nil)
    }

    @Test("chart fixtures validate", arguments: files)
    func fixturesValidate(_ path: String) async throws {
        let bridge = try #require(BridgeTests.bridge)
        let validation = try await bridge.validateSpec(Spec(json: try Fixtures.json(path)))
        #expect(validation.valid, "\(validation.issues.map(\.message))")
    }
}
