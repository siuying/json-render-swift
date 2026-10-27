import Charts
import SwiftUI

/// A chart's optional `title` above its content, or "No data available" when it is empty.
struct ChartFrame<Content: View>: View {
    let title: String?
    let isEmpty: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title).font(.headline)
            }
            if isEmpty {
                Text("No data available")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                content()
            }
        }
    }
}

/// `BarChart` / `LineChart` / `AreaChart` — `title`, `data`, `xKey`, `yKey`, `aggregate`,
/// `color`, `height`. Swift Charts over ``ChartData``: rounded bars, a smooth 2 pt line
/// without point markers, or that line over a translucent fill down to zero; horizontal
/// gridlines with value labels, one x-axis label per category.
struct ChartComponent: View {
    enum Kind { case bar, line, area }

    let context: ComponentContext
    let kind: Kind

    var body: some View {
        let data = ChartData(props: context.props)
        ChartFrame(title: context.props.string("title"), isEmpty: data.isEmpty) {
            if kind == .bar && context.props.bool("horizontal") == true {
                HorizontalBarChart(context: context, data: data)
                    .id(data)
                    .frame(height: ChartData.height(context.props, categoryCount: data.points.count))
            } else {
                VerticalSeriesChart(context: context, kind: kind, data: data)
                    .id(data)
                    .frame(height: ChartData.height(context.props, categoryCount: data.points.count))
            }
        }
    }

}

private struct HorizontalBarChart: View {
    let context: ComponentContext
    let data: ChartData

    var body: some View {
        let labels = Dictionary(uniqueKeysWithValues: data.points.map { (String($0.id), $0.label) })
        let scale = ChartValueScale(data.points.map(\.value))
        return GeometryReader { geometry in
            Chart(data.points) { point in
                if point.isMissing {
                    PointMark(x: .value(data.valueKey, 0.0), y: .value("Category", String(point.id)))
                        .symbol(.square)
                        .symbolSize(24)
                        .foregroundStyle(.secondary)
                        .annotation(position: .trailing) { Text(point.valueText).font(.caption) }
                } else {
                BarMark(x: .value(data.valueKey, scale.plotted(point.value)), y: .value("Category", String(point.id)))
                    .cornerRadius(4)
                    .foregroundStyle(chartMarkStyle(context, point: point))
                    .accessibilityLabel(point.label)
                    .accessibilityValue(point.valueText)
                    .chartValueAnnotation(point, position: .trailing)
                }
            }
            .modifier(SeriesChartPress(context: context, data: data, horizontal: true, bars: true))
            .chartYScale(domain: data.points.map { String($0.id) })
            .chartYAxis {
                AxisMarks(preset: .aligned, position: .leading) { value in
                    AxisValueLabel(centered: false, multiLabelAlignment: .trailing) {
                        Text(value.as(String.self).flatMap { labels[$0] } ?? "")
                            .multilineTextAlignment(.trailing)
                            .lineLimit(3)
                            .frame(width: min(160, geometry.size.width * 0.45), alignment: .trailing)
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    if scale.isScaled {
                        AxisValueLabel { Text(value.as(Double.self).map(scale.label) ?? "") }
                    } else {
                        AxisValueLabel()
                    }
                }
            }
        }

    }

    /// The `color` prop (`#rgb`, `#rrggbb`, `#rrggbbaa`); the app's tint otherwise.
    private var style: AnyShapeStyle {
        Color(chartHex: context.props.string("color")).map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint)
    }
}

private struct VerticalSeriesChart: View {
    let context: ComponentContext
    let kind: ChartComponent.Kind
    let data: ChartData

    var body: some View {
        let labels = Dictionary(uniqueKeysWithValues: data.points.map { (String($0.id), $0.label) })
        let scale = ChartValueScale(data.points.map(\.value))
        let runs = Dictionary(uniqueKeysWithValues: data.numericSegments.enumerated().flatMap { index, points in points.map { ($0.id, index) } })
        return Chart(data.points) { point in
            // Positions, not labels, on the x axis: repeated labels stay separate points.
            let x = PlottableValue.value("Category", String(point.id))
            let y = PlottableValue.value(data.valueKey, scale.plotted(point.value))
            if point.isMissing {
                PointMark(x: x, y: .value(data.valueKey, 0.0))
                    .symbol(.square)
                    .symbolSize(24)
                    .foregroundStyle(.secondary)
                    .annotation(position: .top) { Text(point.valueText).font(.caption) }
            } else if kind == .bar {
                BarMark(x: x, y: y)
                    .cornerRadius(4)
                    .foregroundStyle(chartMarkStyle(context, point: point))
                    .accessibilityLabel(point.label)
                .accessibilityValue(point.valueText)
                    .chartValueAnnotation(point, position: .top)
            } else if kind == .area {
                AreaMark(x: x, y: y, series: .value("Run", runs[point.id] ?? 0))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(chartMarkStyle(context, point: point).opacity(0.25))
                    .accessibilityHidden(true)
                LineMark(x: x, y: y, series: .value("Run", runs[point.id] ?? 0))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(chartMarkStyle(context, point: point))
                    .accessibilityLabel(point.label)
                .accessibilityValue(point.valueText)
                    .chartValueAnnotation(point, position: .top)
            } else {
                LineMark(x: x, y: y, series: .value("Run", runs[point.id] ?? 0))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(chartMarkStyle(context, point: point))
                    .accessibilityLabel(point.label)
                .accessibilityValue(point.valueText)
                    .chartValueAnnotation(point, position: .top)
            }
        }
        .modifier(SeriesChartPress(context: context, data: data, bars: kind == .bar))
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    Text(value.as(String.self).flatMap { labels[$0] } ?? "")
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                if scale.isScaled {
                    AxisValueLabel { Text(value.as(Double.self).map(scale.label) ?? "") }
                } else {
                    AxisValueLabel()
                }
            }
        }
    }

    /// The `color` prop (`#rgb`, `#rrggbb`, `#rrggbbaa`); the app's tint otherwise.
    private var style: AnyShapeStyle {
        Color(chartHex: context.props.string("color")).map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint)
    }
}

extension ChartContent {
    @MainActor @ChartContentBuilder
    func chartValueAnnotation(_ point: ChartData.Point, position: AnnotationPosition) -> some ChartContent {
        if point.formattedValue != nil {
            self.annotation(position: position) { Text(point.valueText).font(.caption) }
        } else {
            self
        }
    }
}

/// Display color has no effect on the numeric axis or grouping identity.
@MainActor
private func chartMarkStyle(_ context: ComponentContext, point: ChartData.Point) -> AnyShapeStyle {
    let hex = point.isOther ? context.props.string("otherColor") ?? context.props.string("color") : context.props.string("color")
    return Color(chartHex: hex).map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint)
}

/// One divisor for every plotted value of a chart. Swift Charts traps when the value range
/// (including zero) overflows, e.g. ±1e308, so such data is plotted divided by 4 (exact for
/// these magnitudes) and axis labels are written in the original units. Otherwise values are
/// plotted as they are.
struct ChartValueScale: Equatable {
    let divisor: Double

    init(_ values: [Double]) {
        let lower = min(values.min() ?? 0, 0), upper = max(values.max() ?? 0, 0)
        divisor = upper / 2 - lower / 2 > .greatestFiniteMagnitude / 4 ? 4 : 1
    }

    var isScaled: Bool { divisor != 1 }

    func plotted(_ value: Double) -> Double { value / divisor }

    /// An axis label for a plotted value, in original units (`1E308`, `0`).
    func label(_ plotted: Double) -> String {
        guard plotted != 0 else { return "0" }
        return (plotted * divisor).formatted(
            .number.locale(Locale(identifier: "en_US")).notation(.scientific).precision(.significantDigits(1...3))
        )
    }
}

extension Color {
    /// A `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa` color (``ChartColors/rgba(_:)``).
    init?(chartHex string: String?) {
        guard let (red, green, blue, alpha) = ChartColors.rgba(string) else { return nil }
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}
