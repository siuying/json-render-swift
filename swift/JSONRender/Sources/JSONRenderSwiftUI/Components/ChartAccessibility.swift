import Accessibility
import SwiftUI

/// Shared semantic representation of the processed values, including for pie audio graphs.
struct ChartAccessibility: AXChartDescriptorRepresentable {
    let title: String?
    let summary: String?
    let data: ChartData
    var horizontal = false
    var radial = false
    var continuous = false

    var summaryText: String {
        if let summary { return summary }
        guard let lower = data.points.filter { !$0.isMissing }.map(\.value).min(), let upper = data.points.filter { !$0.isMissing }.map(\.value).max() else {
            return "No data available"
        }
        return "\(data.points.count) categories. \(data.valueKey) ranges from \(lower.formatted()) to \(upper.formatted())."
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = data.points.filter { !$0.isMissing }.map(\.value)
        let lower = min(values.min() ?? 0, 0)
        let maximum = max(values.max() ?? 0, 0)
        let upper = maximum == lower ? lower + 1 : maximum
        let axis = AXNumericDataAxisDescriptor(title: data.valueKey, range: lower...upper, gridlinePositions: []) { $0.formatted() }
        let categories = AXCategoricalDataAxisDescriptor(title: "Category", categoryOrder: data.points.map { "\($0.id + 1). \($0.label)" })
        let series = AXDataSeriesDescriptor(name: data.valueKey, isContinuous: continuous, dataPoints: data.points.filter { !$0.isMissing }.map {
            AXDataPoint(x: "\($0.id + 1). \($0.label)", y: $0.value, label: $0.label)
        })
        let descriptor = AXChartDescriptor(title: title, summary: summaryText, xAxis: categories, yAxis: axis, series: [series])
        descriptor.contentDirection = radial ? .radialClockwise : horizontal ? .topToBottom : .leftToRight
        return descriptor
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let next = makeChartDescriptor()
        descriptor.title = next.title
        descriptor.summary = next.summary
        descriptor.xAxis = next.xAxis
        descriptor.yAxis = next.yAxis
        descriptor.series = next.series
        descriptor.contentDirection = next.contentDirection
    }
}
