import Charts
import SwiftUI

/// A tap resolves through the same ChartProxy that supplies each accessibility frame.
/// Dragging cancels SpatialTapGesture and never emits press events.
struct SeriesChartPress: ViewModifier {
    let context: ComponentContext
    let data: ChartData
    var horizontal = false
    var bars = false

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    let layout = layout(proxy: proxy, plot: plot)
                    Color.clear.contentShape(Rectangle())
                        .preference(key: ChartAccessibilityLayoutKey.self, value: layout)
                        .gesture(SpatialTapGesture().onEnded { tap in
                            guard context.element.on["press"] != nil, plot.contains(tap.location) else { return }
                            let location = CGPoint(x: tap.location.x - plot.minX, y: tap.location.y - plot.minY)
                            let category: String? = horizontal ? proxy.value(atY: location.y) : proxy.value(atX: location.x)
                            guard let point = data.points.first(where: { String($0.id) == category }) else { return }
                            if bars && !point.isMissing {
                                guard layout.marks.first(where: { $0.id == point.id })?.frame.contains(tap.location) == true else { return }
                            }
                            context.emit("press", datum: point.datum)
                        }, including: context.element.on["press"] == nil ? .none : .all)
                }
            }
        }
        .accessibilityHidden(true)
        .overlayPreferenceValue(ChartAccessibilityLayoutKey.self) { layout in
            ChartAccessibilityOverlay(context: context, layout: layout,
                descriptor: ChartAccessibility(title: context.props.string("title"), summary: context.props.string("accessibilitySummary"), data: data, horizontal: horizontal, continuous: !bars))
        }
    }

    private func layout(proxy: ChartProxy, plot: CGRect) -> ChartAccessibilityLayout {
        let scale = ChartValueScale(data.points.map(\.value))
        let marks = data.points.compactMap { point -> ChartAccessibleMark? in
            let category = String(point.id)
            let rect: CGRect
            if bars {
                let band = horizontal ? proxy.positionRange(forY: category) : proxy.positionRange(forX: category)
                let zero = horizontal ? proxy.position(forX: 0.0) : proxy.position(forY: 0.0)
                let end = horizontal ? proxy.position(forX: scale.plotted(point.value)) : proxy.position(forY: scale.plotted(point.value))
                guard let band, let zero, let end else { return nil }
                let inset = (band.upperBound - band.lowerBound) * 0.1
                if horizontal {
                    let empty = point.isMissing || point.value == 0
                    let x = empty ? min(max(zero - 12, 0), max(plot.width - 24, 0)) : min(zero, end)
                    rect = CGRect(x: plot.minX + x, y: plot.minY + band.lowerBound + inset,
                        width: empty ? 24 : max(abs(end - zero), 0.5), height: max(band.upperBound - band.lowerBound - inset * 2, 1))
                } else {
                    let y = point.isMissing || point.value == 0 ? max(zero - 24, 0) : min(zero, end)
                    rect = CGRect(x: plot.minX + band.lowerBound + inset, y: plot.minY + y,
                        width: max(band.upperBound - band.lowerBound - inset * 2, 1), height: point.isMissing || point.value == 0 ? 24 : max(abs(end - zero), 0.5))
                }
            } else {
                guard let x = proxy.position(forX: category), let y = proxy.position(forY: scale.plotted(point.value)) else { return nil }
                rect = CGRect(x: plot.minX + x - 12, y: plot.minY + y - 12, width: 24, height: 24)
            }
            let frame = rect.intersection(plot)
            guard !frame.isNull, frame.width > 0, frame.height > 0 else { return nil }
            return ChartAccessibleMark(id: point.id, label: point.label, value: point.valueText, datum: point.datum, frame: frame)
        }
        return ChartAccessibilityLayout(plot: plot, marks: marks)
    }
}

struct PieChartPress: ViewModifier {
    let context: ComponentContext
    let data: PieChartData

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    Color.clear.contentShape(Rectangle())
                        .preference(key: ChartAccessibilityLayoutKey.self, value: layout(plot: plot))
                        .gesture(SpatialTapGesture().onEnded { tap in
                            guard context.element.on["press"] != nil, plot.contains(tap.location) else { return }
                            let location = CGPoint(x: tap.location.x - plot.minX, y: tap.location.y - plot.minY)
                            let radius = min(plot.width, plot.height) / 2
                            let distance = hypot(location.x - plot.width / 2, location.y - plot.height / 2)
                            let inner = context.props.bool("donut") == true ? radius * PieChartData.donutRatio : 0
                            guard distance <= radius, distance >= inner,
                                  let fraction: Double = proxy.value(atAngle: proxy.angle(at: location)),
                                  let slice = data.slice(at: fraction) else { return }
                            context.emit("press", datum: slice.datum)
                        }, including: context.element.on["press"] == nil ? .none : .all)
                }
            }
        }
        .accessibilityHidden(true)
        .overlayPreferenceValue(ChartAccessibilityLayoutKey.self) { layout in
            ChartAccessibilityOverlay(context: context, layout: layout,
                descriptor: ChartAccessibility(title: context.props.string("title"), summary: context.props.string("accessibilitySummary"),
                    data: ChartData(points: data.slices.map { slice in
                        var point = ChartData.Point(id: slice.id, label: slice.label, value: slice.value, formattedValue: slice.formattedValue)
                        point.includesDisplay = slice.includesDisplay
                        return point
                    }, valueKey: context.props.string("valueKey") ?? "Value"), radial: true))
        }
    }

    private func layout(plot: CGRect) -> ChartAccessibilityLayout {
        let total = data.slices.reduce(0) { $0 + $1.fraction }
        let radius = min(plot.width, plot.height) / 2 * (context.props.bool("donut") == true ? 0.75 : 0.6)
        var start = 0.0
        let marks = data.slices.map { slice in
            let angle = (start + slice.fraction / 2) / max(total, .leastNonzeroMagnitude) * 2 * .pi
            start += slice.fraction
            let center = CGPoint(x: plot.midX + sin(angle) * radius, y: plot.midY - cos(angle) * radius)
            let frame = CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24).intersection(plot)
            return ChartAccessibleMark(id: slice.id, label: slice.label, value: "\(slice.valueText), \(slice.percentText)", datum: slice.datum, frame: frame)
        }
        return ChartAccessibilityLayout(plot: plot, marks: marks)
    }
}
