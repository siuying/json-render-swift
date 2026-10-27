import SwiftUI
import Testing
@testable import JSONRenderSwiftUI

@Suite("Pie chart data")
struct PieChartDataTests {
    private func records(_ pairs: [(JSONValue, JSONValue)]) -> [JSONValue] {
        pairs.map { ["name": $0, "value": $1] }
    }

    @Test func inlineSlicesKeepDataOrderAndSkipNonPositiveValues() throws {
        let data = PieChartData(props: try ChartDataTests.props("pie-inline"))
        // Refund (-40) and Utilities (0) are left out; the unnamed record is the 6th in data.
        #expect(data.slices.map(\.label) == ["Rent", "Groceries", "Transport", "Segment 6", "Savings"])
        #expect(data.slices.map(\.value) == [1450, 420.5, 160, 95, 600])
        #expect(data.slices.map(\.id) == Array(0..<5))
        #expect(abs(data.slices.map(\.fraction).reduce(0, +) - 1) < 1e-12)
        #expect(abs(data.slices[0].fraction - 1450 / 2725.5) < 1e-12)
        #expect(data.slices.map(\.percentText) == ["53%", "15%", "6%", "3%", "22%"])
    }

    @Test func aggregatedSlicesAreGroupedAndSortedByName() throws {
        let data = PieChartData(props: try ChartDataTests.props("pie-state-aggregate-donut"))
        #expect(data.slices.map(\.label) == ["Chat", "Email", "Phone"])
        #expect(data.slices.map(\.value) == [3, 4, 1])
        let summed = PieChartData(
            records: records([("a", 2), ("b", -5), ("a", 3), ("b", 1), (.null, 4)]), nameKey: "name", valueKey: "value", aggregate: .sum
        )
        // b sums to -4 and is left out; a record without a name groups as "unknown".
        #expect(summed.slices.map(\.label) == ["a", "unknown"])
        #expect(summed.slices.map(\.value) == [5, 4])
    }

    @Test func emptyWhenNothingIsPositive() throws {
        #expect(PieChartData(props: try ChartDataTests.props("pie-empty")).isEmpty)
        #expect(PieChartData(records: records([("a", 0), ("b", 0)]), nameKey: "name", valueKey: "value", aggregate: nil).isEmpty)
        #expect(PieChartData(records: [], nameKey: "name", valueKey: "value", aggregate: .count).isEmpty)
    }

    @Test func fractionsStayFiniteWhenTheTotalOverflows() {
        let data = PieChartData(
            records: records([("a", 1.5e308), ("b", 1.5e308), ("c", .number(.greatestFiniteMagnitude))]),
            nameKey: "name", valueKey: "value", aggregate: nil
        )
        #expect(data.slices.allSatisfy { $0.fraction.isFinite && $0.fraction > 0 })
        #expect(abs(data.slices.map(\.fraction).reduce(0, +) - 1) < 1e-12)
        #expect(abs(data.slices[0].fraction / data.slices[1].fraction - 1) < 1e-12)
    }

    @Test func fallbackLabelsAndTinyShares() {
        let data = PieChartData(
            records: [["value": 1000], ["name": 7, "value": "1"], ["name": nil, "value": 2]],
            nameKey: "name", valueKey: "value", aggregate: nil
        )
        #expect(data.slices.map(\.label) == ["Segment 1", "7", "Segment 3"])
        #expect(data.slices[1].percentText == "<1%")
    }

    @Test func colorsCycleThroughValidHexStrings() {
        #expect(ChartColors.list(nil) == ChartColors.palette)
        #expect(ChartColors.list(["red", 3]) == ChartColors.palette, "no valid hex: the default palette")
        #expect(ChartColors.list(["#abc", "blue", "#0ea5e9"]) == ["#abc", "#0ea5e9"])
        #expect(ChartColors.palette.count == 5)
        #expect(ChartColors.rgba("#ff000080").map { [$0.red, $0.green, $0.blue] } == [1, 0, 0])
        #expect(ChartColors.rgba("#+12345") == nil)
    }
}

/// Draws pies with `ImageRenderer` and reads pixels back.
@Suite("Pie chart rendering")
@MainActor
struct PieChartRenderingTests {
    private func image(_ props: [String: JSONValue], width: CGFloat = 320) -> CGImage? {
        let element = Element(json: ["type": "PieChart", "props": [:], "children": []])!
        let context = ComponentContext(
            key: "c", element: element, props: Props(props),
            session: FormSession(), bindings: [:], ancestors: [], localValues: .constant([:])
        )
        return ImageRenderer(content: PieChartComponent(context: context).frame(width: width).background(.white)).cgImage
    }

    /// The pixel at `point` as 0...255 RGB.
    private func pixel(_ image: CGImage, _ point: CGPoint) -> [Int] {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -point.x, y: point.y - CGFloat(image.height) + 1, width: CGFloat(image.width), height: CGFloat(image.height)))
        return bytes.prefix(3).map(Int.init)
    }

    @Test func slicesStartAtTwelveOClockAndRunClockwise() throws {
        // A quarter (#ff0000) then three quarters (#0000ff), no legend: the pie fills a 320×200 image.
        let image = try #require(self.image([
            "data": [["n": "a", "v": 1], ["n": "b", "v": 3]], "nameKey": "n", "valueKey": "v",
            "colors": ["#ff0000", "#0000ff"], "legend": false, "height": 200,
        ]))
        #expect(image.height == 200)
        let center = CGPoint(x: CGFloat(image.width) / 2, y: 100)
        func at(_ degrees: CGFloat) -> [Int] {
            let angle = (degrees - 90) * .pi / 180 // clockwise from 12 o'clock, y down
            return pixel(image, CGPoint(x: center.x + 50 * cos(angle), y: center.y + 50 * sin(angle)))
        }
        #expect(at(45) == [255, 0, 0], "first slice between 12 and 3 o'clock")
        #expect(at(135) == [0, 0, 255])
        #expect(at(315) == [0, 0, 255])
    }

    @Test func donutLeavesTheMiddleEmpty() throws {
        let props: [String: JSONValue] = [
            "data": [["n": "a", "v": 1]], "nameKey": "n", "valueKey": "v", "colors": ["#ff0000"], "legend": false,
            "height": 200,
        ]
        let pie = try #require(image(props)), donut = try #require(image(props.merging(["donut": true]) { $1 }))
        let center = CGPoint(x: CGFloat(pie.width) / 2, y: 100)
        #expect(pixel(pie, center) == [255, 0, 0])
        #expect(pixel(donut, center) == [255, 255, 255])
        #expect(pixel(donut, CGPoint(x: center.x, y: center.y - 75)) == [255, 0, 0], "the ring")
    }

    @Test func legendAddsRowsBelowThePie() throws {
        let props: [String: JSONValue] = [
            "data": [["n": "a", "v": 1], ["n": "b", "v": 2], ["n": "c", "v": 3]], "nameKey": "n", "valueKey": "v", "height": 200,
        ]
        let withLegend = try #require(image(props)), without = try #require(image(props.merging(["legend": false]) { $1 }))
        #expect(withLegend.height > without.height + 30)
    }

    @Test(arguments: ["pie-inline", "pie-state-aggregate-donut", "pie-empty"])
    func fixturesRender(_ name: String) throws {
        #expect(image(try ChartDataTests.props(name).values) != nil)
    }
}
