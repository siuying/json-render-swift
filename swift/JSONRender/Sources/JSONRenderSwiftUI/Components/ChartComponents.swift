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
        let scale = ChartValueScale(data.points.map(\.value))
        return Chart(data.points) { point in
            // Positions, not labels, on the x axis: repeated labels stay separate points.
            let x = PlottableValue.value("Category", String(point.id))
            let y = PlottableValue.value(data.valueKey, scale.plotted(point.value))
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
