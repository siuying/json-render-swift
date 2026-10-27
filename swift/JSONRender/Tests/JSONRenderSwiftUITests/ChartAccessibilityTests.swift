import Accessibility
import SwiftUI
import Testing
@testable import JSONRenderSwiftUI

@Suite("Chart accessibility")
@MainActor
struct ChartAccessibilityTests {
    @Test func audioGraphHasValuesAndDuplicateCategories() throws {
        let data = ChartData(points: [.init(id: 0, label: "Same", value: -2), .init(id: 1, label: "Same", value: 8)], valueKey: "sales")
        let representation = ChartAccessibility(title: "Revenue", summary: nil, data: data, horizontal: true)
        let descriptor = representation.makeChartDescriptor()
        #expect(descriptor.title == "Revenue")
        #expect(descriptor.summary == "2 categories. sales ranges from -2 to 8.")
        #expect((descriptor.xAxis as? AXCategoricalDataAxisDescriptor)?.categoryOrder == ["1. Same", "2. Same"])
        #expect(descriptor.series.count == 1)
        #expect(descriptor.series[0].dataPoints.count == 2)
        #expect(descriptor.series[0].dataPoints[0].label == "Same")
        #expect(descriptor.contentDirection == .topToBottom)
    }

    @Test func descriptorUpdatesWhenDataChanges() {
        let initial = ChartAccessibility(title: "Empty", summary: nil, data: ChartData(points: [], valueKey: "sales"))
        let descriptor = initial.makeChartDescriptor()
        let next = ChartAccessibility(title: "New", summary: "Custom summary", data: ChartData(points: [.init(id: 0, label: "A", value: 5)], valueKey: "sales"))
        next.updateChartDescriptor(descriptor)
        #expect(descriptor.title == "New")
        #expect(descriptor.summary == "Custom summary")
        #expect(descriptor.series[0].dataPoints.count == 1)
    }
}
