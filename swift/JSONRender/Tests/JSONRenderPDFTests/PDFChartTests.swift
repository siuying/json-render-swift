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

    @Test func interactionAndAccessibilityPropsDoNotChangePDF() async throws {
        let baseline = try await PDFTestSupport.render(try document("bar-horizontal"))
        for fixture in ["bar-accessible", "bar-press"] {
            let pdf = try await PDFTestSupport.render(try document(fixture))
            #expect(pdf.items(.chartBar).map(\.item.rect) == baseline.items(.chartBar).map(\.item.rect))
            #expect(labels(pdf, kind: .chartBar) == labels(baseline, kind: .chartBar))
        }
    }

    @Test func capIsSharedByPDF() async throws {
        let pdf = try await PDFTestSupport.render(try document("bar-capped"))
        #expect(labels(pdf, kind: .chartBar) == ["All regions"])
    }

    @Test func horizontalLongLabelsWrapAndNegativeBarsShareZero() async throws {
        let pdf = try await PDFTestSupport.render(try document("bar-horizontal-long-labels"))
        let plot = try #require(pdf.items(.chart).first?.item.rect)
        let bars = pdf.items(.chartBar).map(\.item.rect)
        #expect(bars.count == 2)
        #expect(abs(bars[0].minX - bars[1].maxX) < 0.001)
        #expect(abs(bars[0].width / bars[1].width - 1.5) < 0.001)
        for bar in bars { #expect(plot.insetBy(dx: -0.01, dy: -0.01).contains(bar)) }
        let text = labels(pdf, kind: .text).joined(separator: " ")
        #expect(text.contains("A very long category label"))
        #expect(text.contains("available space"))
        #expect(text.contains("within its own band"))
    }

    @Test func horizontalBarsUseWidthForValues() async throws {
        let pdf = try await PDFTestSupport.render(try document("bar-horizontal"))
        let bars = pdf.items(.chartBar).map(\.item.rect)
        #expect(bars.count == 2)
        #expect(abs(bars[0].width / bars[1].width - 1.5) < 0.001)
        #expect(bars[0].midY < bars[1].midY)
        #expect(labels(pdf, kind: .text).contains("Western region"))
    }

    @Test func barChartUsesSeparateDisplayLabels() async throws {
        let pdf = try await PDFTestSupport.render(try document("bar-label-key"))
        #expect(labels(pdf, kind: .chartBar) == ["Western region", "Eastern region"])
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

    @Test func oversizedChartInARowMovesWithItsSibling() async throws {
        let fixture = try PDFFixtures.json("charts/bar-inline.json")
        let chart = try #require(fixture["elements"]?["chart"]).setting(9_000, at: "/props/height")
        let spec = Spec(json: ["root": "doc", "elements": [
            "doc": ["type": "Document", "props": [:], "children": ["page"]],
            "page": ["type": "Page", "props": ["size": "A4"], "children": ["intro", "row"]],
            "intro": ["type": "Text", "props": ["text": "Intro"], "children": []],
            "row": ["type": "Row", "props": ["gap": 12], "children": ["chart", "note"]],
            "chart": chart,
            "note": ["type": "Text", "props": ["text": "Side note"], "children": []],
        ]])
        let pdf = try await PDFTestSupport.render(spec)
        let page = { (text: String) in pdf.items(.text).first { $0.item.text == text }?.page }
        let plot = try #require(pdf.items(.chart).first)
        #expect(pdf.items(.chart).count == 1)
        #expect(page("Intro") == 0)
        #expect(page("Monthly revenue") == plot.page, "title with the plot")
        #expect(page("Side note") == plot.page, "the row stays together")
        #expect(Set(pdf.items(.chartBar).map(\.page)) == [plot.page])
        let bottom = pdf.pages[plot.page].size.height - 40
        #expect(pdf.items(.text).filter { $0.page == plot.page }.allSatisfy { $0.item.rect.maxY <= bottom + 0.5 })
    }

    @Test func salesReportFixture() async throws {
        let pdf = try await PDFTestSupport.render(try PDFFixtures.spec("sales-report"))
        #expect(pdf.items(.chart).count == 5)
        #expect(labels(pdf, kind: .chartBar).prefix(6) == ["Oct", "Nov", "Dec", "Jan", "Feb", "Mar"])
        #expect(labels(pdf, kind: .chartBar).suffix(4) == ["East", "North", "South", "West"])
        let days = ["Mar 01", "Mar 02", "Mar 03", "Mar 04", "Mar 05", "Mar 06", "Mar 07"]
        #expect(labels(pdf, kind: .chartPoint) == days + days, "the line, then the area")
        #expect(labels(pdf, kind: .chartSlice) == ["Phone", "Store", "Web"])
        #expect(pdf.items(.chartArea).count == 1)
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

@Suite("PDF pie and area charts")
struct PDFPieAndAreaTests {
    private func document(_ chart: JSONValue, state: JSONValue = [:]) -> Spec {
        Spec(json: ["root": "doc", "elements": [
            "doc": ["type": "Document", "props": [:], "children": ["page"]],
            "page": ["type": "Page", "props": ["size": "A4"], "children": ["chart"]],
            "chart": chart,
        ], "state": state])
    }

    private func fixture(_ name: String) throws -> Spec {
        let json = try PDFFixtures.json("charts/\(name).json")
        return document(try #require(json["elements"]?["chart"]), state: json["state"] ?? [:])
    }

    private func pie(_ records: [JSONValue], _ props: [String: JSONValue] = [:]) -> Spec {
        var all: [String: JSONValue] = ["data": .array(records), "nameKey": "n", "valueKey": "v"]
        all.merge(props) { $1 }
        return document(["type": "PieChart", "props": .object(all), "children": []])
    }

    /// The page's content area (A4, 40 pt margins).
    private let content = CGRect(x: 40, y: 40, width: 595.28 - 80, height: 841.89 - 80)

    @Test func pieDrawsSlicesInOrderWithALegend() async throws {
        let pdf = try await PDFTestSupport.render(try fixture("pie-inline"))
        #expect(pdf.items(.chartSlice).compactMap(\.item.text) == ["Rent", "Groceries", "Transport", "Segment 6", "Savings"])
        let swatches = pdf.items(.box).filter { $0.item.key?.hasPrefix("chart#legend") == true }
        #expect(swatches.count == 5)
        let text = pdf.items(.text).compactMap(\.item.text)
        for expected in ["Monthly budget", "Rent", "53%", "Segment 6", "22%"] {
            #expect(text.contains(expected), "\(expected)")
        }
        let circle = try #require(pdf.items(.chart).first?.item.rect)
        #expect(abs(circle.height - 300) < 0.01, "default height")
        for (_, item) in pdf.items(.chartSlice) { #expect(circle.insetBy(dx: -0.5, dy: -0.5).contains(item.rect)) }
        // The legend sits below the pie, inside the page's content area.
        for (_, item) in swatches {
            #expect(item.rect.minY > circle.maxY)
            #expect(content.insetBy(dx: -0.5, dy: -0.5).contains(item.rect))
        }
    }

    @Test func slicesCoverAFullTurnFromTwelveOClock() throws {
        let json = try PDFFixtures.json("charts/pie-inline.json")
        let props = try #require(json["elements"]?["chart"]?["props"]?.objectValue)
        let data = PieChartData(props: Props(Expressions.resolveProps(props, state: json["state"] ?? [:])))
        let geometry = PieGeometry(data: data, frame: CGRect(x: 0, y: 0, width: 400, height: 300), donut: false)
        #expect(geometry.radius == 150 && geometry.center == CGPoint(x: 200, y: 150))
        #expect(geometry.angles.first?.start == PieGeometry.startAngle)
        #expect(abs(geometry.angles.last!.end - geometry.angles.first!.start - 2 * .pi) < 1e-12)
        for (index, slice) in data.slices.enumerated() {
            let (start, end) = geometry.angles[index]
            if index > 0 { #expect(start == geometry.angles[index - 1].end) }
            #expect(abs(Double(end - start) - slice.fraction * 2 * .pi) < 1e-9)
        }
        let degrees = geometry.angles.map { Double($0.end - $0.start) * 180 / .pi }.reduce(0, +)
        #expect(abs(degrees - 360) < 1e-9)
        // Clockwise on the page: the first slice (53%) covers 3 o'clock, right of the centre.
        #expect(geometry.path(0).contains(CGPoint(x: 300, y: 150)))
        #expect(!geometry.path(0).contains(CGPoint(x: 100, y: 120)))
    }

    @Test func donutHasAHalfRadiusHole() async throws {
        let data = PieChartData(records: [["n": "a", "v": 1], ["n": "b", "v": 1]], nameKey: "n", valueKey: "v", aggregate: nil)
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let donut = PieGeometry(data: data, frame: frame, donut: true), pie = PieGeometry(data: data, frame: frame, donut: false)
        #expect(donut.innerRadius == 50 && pie.innerRadius == 0)
        let inHole = CGPoint(x: 125, y: 100), onRing = CGPoint(x: 175, y: 100)
        #expect(!donut.path(0).contains(inHole) && donut.path(0).contains(onRing))
        #expect(pie.path(0).contains(inHole))
        // One slice: a full disk or ring.
        let whole = PieGeometry(data: PieChartData(records: [["n": "a", "v": 2]], nameKey: "n", valueKey: "v", aggregate: nil), frame: frame, donut: true)
        #expect(whole.path(0).contains(CGPoint(x: 100, y: 25)) && whole.path(0).contains(CGPoint(x: 100, y: 175)))
        #expect(!whole.path(0).contains(CGPoint(x: 100, y: 100)))

        let pdf = try await PDFTestSupport.render(try fixture("pie-state-aggregate-donut"))
        #expect(pdf.items(.chartSlice).compactMap(\.item.text) == ["Chat", "Email", "Phone"])
        #expect(abs((pdf.items(.chart).first?.item.rect.height ?? 0) - 220) < 0.01)
    }

    @Test func emptyAndLegendlessPies() async throws {
        let empty = try await PDFTestSupport.render(try fixture("pie-empty"))
        #expect(empty.items(.chart).isEmpty)
        #expect(empty.allText.contains("No data available"))
        let bare = try await PDFTestSupport.render(pie([["n": "a", "v": 1], ["n": "b", "v": 2]], ["legend": false]))
        #expect(bare.items(.chartSlice).count == 2)
        #expect(bare.items(.box).isEmpty)
        #expect(!bare.allText.contains("%"))
    }

    @Test func longLegendLabelsWrapInsideTheContentWidth() async throws {
        let long = String(repeating: "Quarterly marketing and events spend ", count: 8)
        let word = String(repeating: "x", count: 120)
        let pdf = try await PDFTestSupport.render(pie([["n": .string(long), "v": 3], ["n": .string(word), "v": 1]], ["title": .string(long)]))
        let legend = pdf.items(.text).filter { $0.item.key?.hasPrefix("chart#legend") == true }
        #expect(legend.count > 4, "the long name wraps onto several lines")
        for (_, item) in pdf.items(.text) + pdf.items(.box) {
            #expect(item.rect.minX >= content.minX - 0.5 && item.rect.maxX <= content.maxX + 0.5, "\(item.text ?? "") \(item.rect)")
        }
    }

    @Test func oversizedPieKeepsTitlePieAndLegendOnOnePage() async throws {
        let records = (1...6).map { JSONValue.object(["n": .string("Slice \($0)"), "v": .number(Double($0))]) }
        for before in [false, true] {
            var spec = pie(records, ["title": "Shares", "height": 9_000])
            if before {
                spec = Spec(json: spec.json
                    .setting(["type": "Text", "props": ["text": "Intro"], "children": []], at: "/elements/intro")
                    .setting(["intro", "chart"], at: "/elements/page/children"))
            }
            let pdf = try await PDFTestSupport.render(spec)
            let circle = try #require(pdf.items(.chart).first)
            let page = circle.page
            #expect(pdf.items(.text).first { $0.item.text == "Shares" }?.page == page)
            #expect(Set(pdf.items(.chartSlice).map(\.page)) == [page])
            let swatches = pdf.items(.box).filter { $0.item.key?.hasPrefix("chart#legend") == true }
            #expect(swatches.count == 6 && swatches.allSatisfy { $0.page == page })
            #expect(swatches.allSatisfy { $0.item.rect.maxY <= content.maxY + 0.5 }, "legend above the bottom margin")
            #expect(circle.item.rect.height > 400, "the pie fills what is left")
        }
    }

    @Test func legendTallerThanAPageContinuesOnTheNextPages() async throws {
        let names = (1...90).map { "Slice \($0)" }
        let records = names.enumerated().map { JSONValue.object(["n": .string($1), "v": .number(Double($0 + 1))]) }
        for height: JSONValue in [300, 9_000] {
            let pdf = try await PDFTestSupport.render(pie(records, ["title": "Many slices", "height": height]))
            #expect(pdf.pageCount >= 2)
            let circle = try #require(pdf.items(.chart).first)
            #expect(pdf.items(.chart).count == 1)
            #expect(pdf.items(.text).first { $0.item.text == "Many slices" }?.page == circle.page, "title with the pie")
            #expect(circle.item.rect.height >= 120, "the pie keeps a usable size")
            let legend = pdf.items(.text).filter { $0.item.key?.hasPrefix("chart#legend") == true }
            for name in names {
                #expect(legend.filter { $0.item.text == name }.count == 1, "\(name) drawn once")
            }
            #expect(pdf.items(.box).filter { $0.item.key?.hasPrefix("chart#legend") == true }.count == 90)
            for (_, item) in legend + pdf.items(.box) {
                #expect(content.insetBy(dx: -0.5, dy: -0.5).contains(item.rect), "\(item.text ?? "") \(item.rect)")
            }
            // Rows continue in order.
            let pages = names.compactMap { name in legend.first { $0.item.text == name }?.page }
            #expect(pages == pages.sorted() && pages.last! > circle.page)
        }
    }

    /// A bold 12 pt title of `words` words (about 10 words per line on A4: 495 words leave
    /// 40–120 pt under the title, 900 do not fit on a page).
    private func title(words: Int) -> JSONValue {
        .string((1...words).map { "word\($0)" }.joined(separator: " "))
    }

    /// Title lines (keyed `chart#title`) and their pages.
    private func titleLines(_ pdf: RenderedPDF) -> [(page: Int, item: DrawnItem)] {
        pdf.items(.text).filter { $0.item.key == "chart#title" }
    }

    @Test func longTitleStaysWithAShorterPlot() async throws {
        let bar: JSONValue = [
            "type": "BarChart",
            "props": ["title": title(words: 495), "data": [["x": "a", "y": 1], ["x": "b", "y": 2]], "xKey": "x", "yKey": "y", "height": 9_000],
            "children": [],
        ]
        let records = (1...6).map { JSONValue.object(["n": .string("Slice \($0)"), "v": .number(Double($0))]) }
        for spec in [document(bar), pie(records, ["title": title(words: 495), "height": 9_000])] {
            let pdf = try await PDFTestSupport.render(spec)
            let plot = try #require(pdf.items(.chart).first)
            let lines = titleLines(pdf)
            #expect(lines.count > 40 && Set(lines.map(\.page)) == [plot.page], "the whole title is on the plot's page")
            // Shorter than the 120 pt minimum, to stay with the title (a bar's plot area also
            // leaves room for its axis labels).
            #expect(plot.item.rect.height < 120 && plot.item.rect.height > 0, "\(plot.item.rect.height)")
            if pdf.items(.chartSlice).count > 0 { #expect(plot.item.rect.height >= Paginator.plotFloor) }
            #expect(plot.item.rect.maxY <= content.maxY + 0.5)
            // A pie's legend rows continue on the next page, each drawn once.
            let legend = pdf.items(.text).filter { $0.item.key?.hasPrefix("chart#legend") == true }
            for name in records.compactMap({ $0["n"]?.stringValue }) where !legend.isEmpty {
                #expect(legend.filter { $0.item.text == name }.count == 1)
            }
        }
    }

    @Test func titleTallerThanThePageSplitsAndThePlotFollows() async throws {
        let bar: JSONValue = [
            "type": "BarChart",
            "props": ["title": title(words: 900), "data": [["x": "a", "y": 1]], "xKey": "x", "yKey": "y", "height": 9_000],
            "children": [],
        ]
        let pdf = try await PDFTestSupport.render(document(bar))
        let lines = titleLines(pdf)
        let plot = try #require(pdf.items(.chart).first)
        #expect(Set(lines.map(\.page)) == [0, 1], "the title flows as text")
        #expect(plot.page == 1 && plot.item.rect.height >= 40)
        #expect(Set(lines.map { $0.item.text ?? "" }).count == lines.count, "no title line is drawn twice")
        #expect(lines.map(\.item).allSatisfy { content.insetBy(dx: -0.5, dy: -0.5).contains($0.rect) })
    }

    @Test func continuingLegendInsideARow() async throws {
        let names = (1...90).map { "Slice \($0)" }
        let records = names.enumerated().map { JSONValue.object(["n": .string($1), "v": .number(Double($0 + 1))]) }
        let chart: JSONValue = ["type": "PieChart", "props": ["title": "Many slices", "data": .array(records), "nameKey": "n", "valueKey": "v"], "children": []]
        let spec = Spec(json: ["root": "doc", "elements": [
            "doc": ["type": "Document", "props": [:], "children": ["page"]],
            "page": ["type": "Page", "props": ["size": "A4"], "children": ["intro", "row"]],
            "intro": ["type": "Text", "props": ["text": "Intro"], "children": []],
            "row": ["type": "Row", "props": ["gap": 12], "children": ["chart", "note"]],
            "chart": chart,
            "note": ["type": "Text", "props": ["text": "Side note"], "children": []],
        ]])
        let pdf = try await PDFTestSupport.render(spec)
        let circle = try #require(pdf.items(.chart).first)
        #expect(pdf.items(.text).first { $0.item.text == "Many slices" }?.page == circle.page)
        #expect(pdf.items(.text).first { $0.item.text == "Side note" }?.page == circle.page)
        let legend = pdf.items(.text).filter { $0.item.key?.hasPrefix("chart#legend") == true }
        for name in names { #expect(legend.filter { $0.item.text == name }.count == 1, "\(name)") }
        for (_, item) in legend + pdf.items(.box) {
            #expect(content.insetBy(dx: -0.5, dy: -0.5).contains(item.rect), "\(item.text ?? "") \(item.rect)")
        }
        #expect(Set(legend.map(\.page)).count >= 2)
    }

    @Test func areaFillIsFiniteAndInsideThePlot() async throws {
        let pdf = try await PDFTestSupport.render(try fixture("area-date-series"))
        #expect(pdf.items(.chartPoint).compactMap(\.item.text) == ["Mar 01", "Mar 02", "Mar 03", "Mar 04", "Mar 05"])
        let plot = try #require(pdf.items(.chart).first?.item.rect)
        let area = try #require(pdf.items(.chartArea).first?.item.rect)
        #expect(abs(area.maxY - plot.maxY) < 0.01, "filled down to zero, the plot's bottom")
        #expect(plot.insetBy(dx: -0.5, dy: -0.5).contains(area))

        for values: [Double] in [[-3, 5, -2], [1e308, -1e308, 1.7e308], [4]] {
            let data = JSONValue.array(values.enumerated().map { ["x": .string("p\($0)"), "y": .number($1)] })
            let pdf = try await PDFTestSupport.render(document(["type": "AreaChart", "props": ["data": data, "xKey": "x", "yKey": "y"], "children": []]))
            let plot = try #require(pdf.items(.chart).first?.item.rect)
            let area = try #require(pdf.items(.chartArea).first?.item.rect)
            #expect(PDFDrawer.isFinite(area), "\(values)")
            #expect(plot.insetBy(dx: -1, dy: -1).contains(area), "\(values) \(area) in \(plot)")
        }
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
        for (lower, upper) in [(-1.7e308, 1.7e308), (0, Double.greatestFiniteMagnitude), (-Double.greatestFiniteMagnitude, 0)] {
            let ticks = ChartGeometry.niceTicks(lower: lower, upper: upper)
            #expect(ticks.count > 2 && ticks.allSatisfy(\.isFinite), "\(ticks)")
            #expect(ticks.first! <= lower && ticks.last! >= upper)
        }
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

    @Test func extremeValuesStayFinite() async throws {
        for values: [Double] in [[1e308, -1e308], [1.7e308, 1.7e308], [-1.7e308, 5]] {
            let data = JSONValue.array(values.enumerated().map { ["x": .string("p\($0)"), "y": .number($1)] })
            for (type, aggregate) in [("BarChart", JSONValue.null), ("LineChart", .null), ("BarChart", "sum"), ("LineChart", "avg")] {
                let spec = Spec(json: ["root": "c", "elements": [
                    "c": ["type": .string(type), "props": ["data": data, "xKey": "x", "yKey": "y", "aggregate": aggregate], "children": []],
                ]])
                let pdf = try await PDFTestSupport.render(spec)
                let plot = try #require(pdf.items(.chart).first?.item.rect)
                let marks = pdf.items(.chartBar) + pdf.items(.chartPoint)
                #expect(!marks.isEmpty, "\(type) \(values)")
                for (_, item) in marks {
                    #expect(PDFDrawer.isFinite(item.rect), "\(type) \(values) \(item.rect)")
                    #expect(plot.insetBy(dx: -2, dy: -2).contains(item.rect), "\(type) \(aggregate) \(values) \(item.rect) in \(plot)")
                }
            }
        }
    }

    @Test func monotoneCurveStaysWithinNeighbours() {
        let points = [CGPoint(x: 0, y: 100), CGPoint(x: 10, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 30, y: 50)]
        let bounds = ChartGeometry.monotonePath(points).boundingBoxOfPath
        #expect(bounds.minY >= -0.01 && bounds.maxY <= 100.01)
        #expect(ChartGeometry.monotonePath([CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)]).boundingBoxOfPath == CGRect(x: 0, y: 0, width: 5, height: 5))
    }
}
