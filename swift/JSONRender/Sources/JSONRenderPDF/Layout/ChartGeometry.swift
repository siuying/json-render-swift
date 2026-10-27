import CoreGraphics
import Foundation
import JSONRenderSwiftUI

/// Where a chart's parts go inside its frame (top-left origin): value labels on the left,
/// category labels along the bottom, and the plot area with one equal-width band per point.
struct ChartGeometry {
    /// Axis labels: 9 pt grey, never hyphenated.
    static let labelStyle: TextStyle = {
        var style = TextStyle()
        style.fontSize = 9
        style.color = PDFColor("#6b7280")!
        style.hyphenate = false
        return style
    }()

    static let gridColor = PDFColor("#e5e7eb")!
    /// Space between the value labels and the plot, and between the plot and category labels.
    static let labelGap: CGFloat = 8
    /// Bars fill this fraction of their band.
    static let barFraction: CGFloat = 0.8
    static let barRadius: CGFloat = 4

    let plot: CGRect
    /// Gridline values, ascending; the first and last are the ends of the value axis.
    let ticks: [Double]
    let tickLabels: [String]
    /// Every `labelStride`-th category label is drawn, so labels never overlap.
    let labelStride: Int
    let labelHeight: CGFloat
    private let count: Int

    init(data: ChartData, frame: CGRect, text: TextEngine) {
        count = data.points.count
        let values = data.points.map(\.value)
        ticks = Self.niceTicks(lower: values.min() ?? 0, upper: values.max() ?? 0)
        let step = ticks.count > 1 ? ticks[1] - ticks[0] : 1
        tickLabels = ticks.map { Self.format($0, step: step) }
        let style = Self.labelStyle
        labelHeight = text.lines("0", style, width: .greatestFiniteMagnitude).first?.height ?? style.fontSize * 1.2
        let valueWidth = tickLabels.map { text.maxContentWidth($0, style) }.max() ?? 0
        let left = min(valueWidth + Self.labelGap, frame.width / 2)
        // Half a label above the top gridline so its label fits inside the frame.
        let top = labelHeight / 2
        plot = CGRect(
            x: frame.minX + left, y: frame.minY + top,
            width: max(frame.width - left, 0),
            height: max(frame.height - top - Self.labelGap - labelHeight, 0)
        )
        let band = count > 0 ? plot.width / CGFloat(count) : 0
        let widest = data.points.map { text.maxContentWidth($0.label, style) }.max() ?? 0
        labelStride = band > 0 ? max(1, Int(((widest + 4) / band).rounded(.up))) : 1
    }

    var bandWidth: CGFloat { count > 0 ? plot.width / CGFloat(count) : 0 }

    /// The vertical position of `value` (the plot spans the first to the last tick). Halved
    /// operands keep the arithmetic finite near ±`Double.greatestFiniteMagnitude`.
    func y(_ value: Double) -> CGFloat {
        guard let lower = ticks.first, let upper = ticks.last, upper > lower else { return plot.maxY }
        let fraction = min(max((value / 2 - lower / 2) / (upper / 2 - lower / 2), 0), 1)
        return plot.maxY - CGFloat(fraction.isFinite ? fraction : 0) * plot.height
    }

    func band(_ index: Int) -> CGRect {
        CGRect(x: plot.minX + CGFloat(index) * bandWidth, y: plot.minY, width: bandWidth, height: plot.height)
    }

    /// From the zero line to `value` (downwards for negative values).
    func bar(_ index: Int, value: Double) -> CGRect {
        let band = band(index)
        let width = band.width * Self.barFraction
        let zero = y(0), top = y(value)
        return CGRect(x: band.midX - width / 2, y: min(zero, top), width: width, height: abs(zero - top))
    }

    func point(_ index: Int, value: Double) -> CGPoint {
        CGPoint(x: band(index).midX, y: y(value))
    }

    // MARK: Scale

    /// About `count` evenly spaced round values (steps of 1, 2 or 5 × 10ⁿ, chosen like d3's
    /// `ticks`) covering `lower...upper` and zero. The span is computed from divided operands so
    /// it stays finite for any finite input; ticks past the largest finite value are clamped.
    static func niceTicks(lower: Double, upper: Double, count: Int = 5) -> [Double] {
        let lower = min(lower, 0)
        var upper = max(upper, 0)
        if upper == lower { upper = lower + 1 }
        let raw = upper / Double(count) - lower / Double(count)
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        let residual = raw / magnitude
        let step = (residual >= 50.0.squareRoot() ? 10 : residual >= 10.0.squareRoot() ? 5 : residual >= 2.0.squareRoot() ? 2 : 1) * magnitude
        let first = (lower / step).rounded(.down), last = (upper / step).rounded(.up)
        guard step.isFinite, step > 0, first.isFinite, last.isFinite else { return [0, 1] }
        let limit = Double.greatestFiniteMagnitude
        return (0...min(Int(last - first), 20)).map { min(max((first + Double($0)) * step, -limit), limit) }
    }

    /// A tick label with as many decimals as the tick `step` needs (`0.0025` for steps of
    /// 0.0005), en-US grouping (`1,200`), trailing zeros dropped. Steps below 10⁻⁶ or values
    /// from 10¹⁵ use scientific notation (`1.5E-7`).
    static func format(_ value: Double, step: Double) -> String {
        let style = FloatingPointFormatStyle<Double>.number.locale(Locale(identifier: "en_US"))
        let decimals = step.isFinite && step > 0 ? max(Int((-log10(step) - 1e-9).rounded(.up)), 0) : .max
        if decimals > 6 || abs(value) >= 1e15 {
            return value.formatted(style.notation(.scientific).precision(.significantDigits(1...3)))
        }
        return value.formatted(style.precision(.fractionLength(0...decimals)))
    }

    // MARK: Line

    /// A monotone cubic through `points` (ordered by x): the curve never overshoots
    /// between neighbouring points (Fritsch–Carlson tangents, as d3's `curveMonotoneX`).
    static func monotonePath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: points[1]) }
            return path
        }
        let slopes = zip(points, points.dropFirst()).map { a, b in
            b.x - a.x == 0 ? 0 : (b.y - a.y) / (b.x - a.x)
        }
        var tangents = [CGFloat](repeating: 0, count: points.count)
        for index in 1..<(points.count - 1) {
            let s0 = slopes[index - 1], s1 = slopes[index]
            let h0 = points[index].x - points[index - 1].x, h1 = points[index + 1].x - points[index].x
            let p = h0 + h1 == 0 ? 0 : (s0 * h1 + s1 * h0) / (h0 + h1)
            tangents[index] = (s0.sign == s1.sign && s0 != 0 && s1 != 0)
                ? (s0 < 0 ? -1 : 1) * min(abs(s0), abs(s1), 0.5 * abs(p)) * 2
                : 0
        }
        tangents[0] = (3 * slopes[0] - tangents[1]) / 2
        tangents[points.count - 1] = (3 * slopes[points.count - 2] - tangents[points.count - 2]) / 2
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let dx = (b.x - a.x) / 3
            path.addCurve(
                to: b,
                control1: CGPoint(x: a.x + dx, y: a.y + dx * tangents[index - 1]),
                control2: CGPoint(x: b.x - dx, y: b.y - dx * tangents[index])
            )
        }
        return path
    }
}
