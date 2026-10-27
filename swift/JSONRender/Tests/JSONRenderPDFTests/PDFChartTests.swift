import CoreGraphics
import Foundation
import Testing
@testable import JSONRenderPDF
import JSONRenderSwiftUI

@Suite("PDF charts")
struct PDFChartTests {
    /// A `fixtures/charts` spec's chart element and state, on an A4 page after `before`.
    private func document(_ name: String, before: [String: JSONValue] = [:]) throws -> Spec {
        let fixture = try PDFFixtures.json("charts/\(name).json")
        let chart = try #require(fixture["elements"]?["chart"])
        var elements: [String: JSONValue] = before
        elements["doc"] = ["type": "Document", "props": [:], "children": ["page"]]
        elements["page"] = ["type": "Page", "props": ["size": "A4"], "children": .array(before.keys.sorted().map(JSONValue.string) + ["chart"])]
        elements["chart"] = chart
        return Spec(json: ["root": "doc", "elements": .object(elements), "state": fixture["state"] ?? [:]])
    }

    private func labels(_ pdf: RenderedPDF, kind: DrawnItem.Kind) -> [String] {
        pdf.items(kind).compactMap(\.item.text)
    }

    @Test func barChartDrawsOneBarPerPointWithLabels() async throws {
        let pdf = try await PDFTestSupport.render(try document("bar-inline"))
        #expect(labels(pdf, kind: .chartBar) == ["Jan", "Feb", "Mar", "Apr", "May", "Jun"])
        let text = labels(pdf, kind: .text)
        for expected in ["Monthly revenue", "Jan", "Jun", "0", "7,000"] {
            #expect(text.contains(expected), "\(expected) in \(text)")
        }
        let bars = pdf.items(.chartBar).map(\.item.rect)
        let plot = try #require(pdf.items(.chart).first?.item.rect)
        // Bars stand on the zero line (the plot's bottom) and scale with their values.
        for bar in bars { #expect(abs(bar.maxY - plot.maxY) < 0.01) }
        #expect(abs(bars[4].height / bars[1].height - 6200 / 3800) < 0.001)
        // `height: 240` is the whole chart: plot plus axis labels.
        let chartTop = try #require(pdf.items(.text).first { $0.item.text == "7,000" }?.item.rect.minY)
        let lowest = try #require(pdf.items(.text).filter { $0.item.text == "Jan" }.map(\.item.rect.maxY).max())
        #expect(abs(lowest - chartTop - 240) < 1.5)
    }

    @Test func aggregatedStateDataIsSortedByCategory() async throws {
        let pdf = try await PDFTestSupport.render(try document("bar-state-aggregate"))
        #expect(labels(pdf, kind: .chartBar) == ["East", "North", "West"])
        #expect(pdf.items(.chart).first?.item.text == "amount")
        let heights = pdf.items(.chartBar).map(\.item.rect.height)
        #expect(abs(heights[0] / heights[1] - 1450 / 300) < 0.001)
    }

    @Test func lineChartPlotsDaysWithoutMarkers() async throws {
        let pdf = try await PDFTestSupport.render(try document("line-date-series"))
        #expect(labels(pdf, kind: .chartPoint) == ["Mar 01", "Mar 02", "Mar 03", "Mar 04", "Mar 05"])
        #expect(pdf.items(.chartBar).isEmpty)
        #expect(pdf.items(.chart).first?.item.text == "count")
        let points = pdf.items(.chartPoint).map(\.item.rect.midY)
        // Counts 1, 3, 2, 1, 4: higher values sit higher on the page.
        #expect(points[1] < points[2] && points[2] < points[0] && points[4] < points[1])
        #expect(abs(points[0] - points[3]) < 0.01)
    }

    @Test func emptyDataShowsAMessage() async throws {
        let pdf = try await PDFTestSupport.render(try document("line-empty"))
        #expect(pdf.items(.chart).isEmpty)
        #expect(pdf.allText.contains("No data available"))
        #expect(pdf.allText.contains("Signups per hour"))
    }

    @Test func chartMovesToTheNextPageWhole() async throws {
        let spacer: JSONValue = ["type": "Spacer", "props": ["height": 560], "children": []]
        let pdf = try await PDFTestSupport.render(try document("bar-inline", before: ["a-spacer": spacer]))
        #expect(pdf.pageCount == 2)
        let charts = pdf.items(.chart)
        #expect(charts.count == 1)
        #expect(charts.first?.page == 1)
        #expect(Set(pdf.items(.chartBar).map(\.page)) == [1])
        // The title moves with the plot.
        #expect(pdf.items(.text).first { $0.item.text == "Monthly revenue" }?.page == 1)
    }

    @Test func oversizedChartShrinksToOnePageWithItsTitle() async throws {
        for before: [String: JSONValue] in [[:], ["a-text": ["type": "Text", "props": ["text": "Intro"], "children": []]]] {
            var spec = try document("bar-inline", before: before)
            spec = Spec(json: spec.json.setting(9_000, at: "/elements/chart/props/height"))
            let pdf = try await PDFTestSupport.render(spec)
            let plot = try #require(pdf.items(.chart).first)
            let title = try #require(pdf.items(.text).first { $0.item.text == "Monthly revenue" })
            #expect(pdf.items(.chart).count == 1)
            #expect(title.page == plot.page, "title and plot on one page")
            #expect(Set(pdf.items(.chartBar).map(\.page)) == [plot.page])
            let contentBottom = pdf.pages[plot.page].size.height - 40
            let lowest = try #require(pdf.items(.text).filter { $0.page == plot.page && $0.item.text == "Jun" }.first?.item.rect.maxY)
            #expect(lowest <= contentBottom + 0.5, "category labels inside the page")
            #expect(plot.item.rect.height > 600, "the plot fills the page")
        }
    }

    @Test func salesReportFixture() async throws {
        let pdf = try await PDFTestSupport.render(try PDFFixtures.spec("sales-report"))
        #expect(pdf.items(.chart).count == 3)
        #expect(labels(pdf, kind: .chartBar).prefix(6) == ["Oct", "Nov", "Dec", "Jan", "Feb", "Mar"])
        #expect(labels(pdf, kind: .chartBar).suffix(4) == ["East", "North", "South", "West"])
        #expect(labels(pdf, kind: .chartPoint) == ["Mar 01", "Mar 02", "Mar 03", "Mar 04", "Mar 05", "Mar 06", "Mar 07"])
        for (page, item) in pdf.items(.chart) {
            let size = pdf.pages[page].size
            #expect(item.rect.maxY < size.height - 60, "plot above the bottom margin")
        }
    }

    @Test func chartInARowSharesTheWidth() async throws {
        let bar: JSONValue = ["type": "BarChart", "props": ["data": [["x": "a", "y": 1], ["x": "b", "y": 2]], "xKey": "x", "yKey": "y"], "children": []]
        let spec = Spec(json: [
            "root": "row",
            "elements": [
                "row": ["type": "Row", "props": ["gap": 20], "children": ["left", "right"]],
                "left": bar,
                "right": bar,
            ],
        ])
        let pdf = try await PDFTestSupport.render(spec)
        let plots = pdf.items(.chart).map(\.item.rect)
        #expect(plots.count == 2)
        #expect(plots[0].maxX < plots[1].minX)
        #expect(plots[1].maxX <= pdf.pages[0].size.width - 40 + 0.01)
    }

    @Test func malformedChartsRender() async throws {
        let spec = Spec(json: [
            "root": "col",
            "elements": [
                "col": ["type": "Column", "props": [:], "children": ["junk", "huge", "negative", "single", "flat"]],
                "junk": ["type": "BarChart", "props": ["data": "junk", "xKey": nil, "color": "nope", "height": 1e9], "children": []],
                "huge": ["type": "BarChart", "props": ["data": [["x": "a", "y": 1e300], ["x": "b", "y": -1e300]], "xKey": "x", "yKey": "y"], "children": []],
                "negative": ["type": "BarChart", "props": ["data": [["x": "a", "y": -3], ["x": "b", "y": 5]], "xKey": "x", "yKey": "y"], "children": []],
                "single": ["type": "LineChart", "props": ["data": [["x": "a", "y": 2]], "xKey": "x", "yKey": "y"], "children": []],
                "flat": ["type": "LineChart", "props": ["data": [["x": "a", "y": 0], ["x": "b", "y": 0], ["x": "c", "y": 0]], "xKey": "x", "yKey": "y", "height": 9_000], "children": []],
            ],
        ])
        let pdf = try await PDFTestSupport.render(spec)
        for (index, page) in pdf.pages.enumerated() {
            let bounds = CGRect(origin: .zero, size: page.size).insetBy(dx: -0.5, dy: -0.5)
            for item in page.items {
                #expect(PDFDrawer.isFinite(item.rect))
                #expect(bounds.contains(item.rect), "page \(index + 1): \(item.kind) \(item.key ?? "") \(item.rect)")
            }
        }
        // A negative bar hangs below the zero line.
        let negative = pdf.items(.chartBar).filter { $0.item.key == "negative" }.map(\.item.rect)
        #expect(negative.count == 2)
        #expect(abs(negative[0].minY - negative[1].maxY) < 0.01)
    }
}

@Suite("Chart geometry")
struct ChartGeometryTests {
    @Test func niceTicks() {
        #expect(ChartGeometry.niceTicks(lower: 300, upper: 1650.5) == [0, 500, 1000, 1500, 2000])
        #expect(ChartGeometry.niceTicks(lower: 1, upper: 4) == [0, 1, 2, 3, 4])
        #expect(ChartGeometry.niceTicks(lower: -3, upper: 5) == [-4, -2, 0, 2, 4, 6])
        #expect(ChartGeometry.niceTicks(lower: 0, upper: 0) == [0, 0.2, 0.4, 0.6000000000000001, 0.8, 1])
        #expect(ChartGeometry.niceTicks(lower: 0.5, upper: 0.5).last == 0.5)
        #expect(ChartGeometry.niceTicks(lower: -1e300, upper: 1e300).count <= 21)
    }

    @Test func tickLabels() {
        #expect(ChartGeometry.format(1200, step: 200) == "1,200")
        #expect(ChartGeometry.format(2.5, step: 0.5) == "2.5")
        #expect(ChartGeometry.format(-40, step: 20) == "-40")
        #expect(ChartGeometry.format(0.6000000000000001, step: 0.2) == "0.6")
        #expect(ChartGeometry.format(0.0025, step: 0.0005) == "0.0025")
        #expect(ChartGeometry.format(0.003, step: 0.001) == "0.003")
        #expect(ChartGeometry.format(0, step: 0.001) == "0")
        #expect(ChartGeometry.format(0.00000015, step: 0.00000005) == "1.5E-7")
        #expect(ChartGeometry.format(1e308, step: 2e307) == "1E308")
        let ticks = ChartGeometry.niceTicks(lower: 0, upper: 0.0004)
        #expect(Set(ticks.map { ChartGeometry.format($0, step: ticks[1] - ticks[0]) }).count == ticks.count, "distinct below 0.01")
    }

    @Test func smallValueLabelsAreDistinct() async throws {
        let data: JSONValue = [["x": "a", "y": 0.001], ["x": "b", "y": 0.004], ["x": "c", "y": 0.0025]]
        let spec = Spec(json: ["root": "c", "elements": [
            "c": ["type": "BarChart", "props": ["data": data, "xKey": "x", "yKey": "y"], "children": []],
        ]])
        let pdf = try await PDFTestSupport.render(spec)
        let labels = pdf.items(.text).compactMap(\.item.text).filter { !["a", "b", "c"].contains($0) }
        #expect(labels == ["0", "0.001", "0.002", "0.003", "0.004"])
    }

    @Test func monotoneCurveStaysWithinNeighbours() {
        let points = [CGPoint(x: 0, y: 100), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 50)]
        let bounds = ChartGeometry.monotonePath(points).boundingBoxOfPath
        #expect(bounds.minY >= -0.01 && bounds.maxY <= 100.01)
        #expect(ChartGeometry.monotonePath([CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)]).boundingBoxOfPath == CGRect(x: 0, y: 0, width: 5, height: 5))
    }
}
