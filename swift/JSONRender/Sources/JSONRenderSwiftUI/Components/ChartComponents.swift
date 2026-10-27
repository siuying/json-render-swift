import Charts
import SwiftUI

/// `BarChart` / `LineChart` — `title`, `data`, `xKey`, `yKey`, `aggregate`, `color`, `height`.
/// Swift Charts over ``ChartData``: rounded bars or a smooth 2 pt line without point markers,
/// horizontal gridlines with value labels, one x-axis label per category.
struct ChartComponent: View {
    enum Kind { case bar, line }

    let context: ComponentContext
    let kind: Kind

    var body: some View {
        let data = ChartData(props: context.props)
        VStack(alignment: .leading, spacing: 8) {
            if let title = context.props.string("title"), !title.isEmpty {
                Text(title).font(.headline)
            }
            if data.isEmpty {
                Text("No data available")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                chart(data)
                    .frame(height: ChartData.height(context.props))
            }
        }
    }

    private func chart(_ data: ChartData) -> some View {
        let labels = Dictionary(uniqueKeysWithValues: data.points.map { (String($0.id), $0.label) })
        return Chart(data.points) { point in
            // Positions, not labels, on the x axis: repeated labels stay separate points.
            let x = PlottableValue.value("Category", String(point.id))
            let y = PlottableValue.value(data.valueKey, Self.plottable(point.value))
            if kind == .bar {
                BarMark(x: x, y: y)
                    .cornerRadius(4)
                    .foregroundStyle(style)
                    .accessibilityLabel(point.label)
            } else {
                LineMark(x: x, y: y)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(style)
                    .accessibilityLabel(point.label)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    Text(value.as(String.self).flatMap { labels[$0] } ?? "")
                }
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine()
                AxisValueLabel()
            }
        }
    }

    /// Swift Charts traps when the value range overflows (e.g. ±1e308), so plotted values are
    /// clamped to ±`Double.greatestFiniteMagnitude` / 4.
    static func plottable(_ value: Double) -> Double {
        let limit = Double.greatestFiniteMagnitude / 4
        return min(max(value, -limit), limit)
    }

    /// The `color` prop (`#rgb`, `#rrggbb`, `#rrggbbaa`); the app's tint otherwise.
    private var style: AnyShapeStyle {
        Color(chartHex: context.props.string("color")).map(AnyShapeStyle.init) ?? AnyShapeStyle(.tint)
    }
}

extension Color {
    init?(chartHex string: String?) {
        guard var digits = string?.trimmingCharacters(in: .whitespaces), digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let rgba = UInt64(digits, radix: 16) else { return nil }
        let value = digits.count == 6 ? rgba << 8 | 0xff : rgba
        self.init(
            .sRGB,
            red: Double(value >> 24 & 0xff) / 255,
            green: Double(value >> 16 & 0xff) / 255,
            blue: Double(value >> 8 & 0xff) / 255,
            opacity: Double(value & 0xff) / 255
        )
    }
}
