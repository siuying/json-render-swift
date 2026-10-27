import Charts
import SwiftUI

/// Tap-only input: all category and angle conversion belongs to Swift Charts. A drag
/// cancels SpatialTapGesture, so scrolling never emits a stream of press actions.
struct SeriesChartPress: ViewModifier {
    let context: ComponentContext
    let data: ChartData
    var horizontal = false
    var bars = false

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            if context.element.on["press"] != nil {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { tap in
                            guard let anchor = proxy.plotFrame else { return }
                            let plot = geometry[anchor]
                            guard plot.contains(tap.location) else { return }
                            let location = CGPoint(x: tap.location.x - plot.minX, y: tap.location.y - plot.minY)
                            let category: String? = horizontal
                                ? proxy.value(atY: location.y) : proxy.value(atX: location.x)
                            guard let point = data.points.first(where: { String($0.id) == category }) else { return }
                            if bars {
                                let scale = ChartValueScale(data.points.map(\.value))
                                let zero = horizontal ? proxy.position(forX: 0.0) : proxy.position(forY: 0.0)
                                let end = horizontal ? proxy.position(forX: scale.plotted(point.value)) : proxy.position(forY: scale.plotted(point.value))
                                guard let zero, let end else { return }
                                let valuePosition = horizontal ? location.x : location.y
                                guard (min(zero, end)...max(zero, end)).contains(valuePosition) else { return }
                                let band = horizontal ? proxy.positionRange(forY: String(point.id)) : proxy.positionRange(forX: String(point.id))
                                guard let band else { return }
                                let inset = (band.upperBound - band.lowerBound) * 0.1
                                let categoryPosition = horizontal ? location.y : location.x
                                guard (band.lowerBound + inset...band.upperBound - inset).contains(categoryPosition) else { return }
                            }
                            context.emit("press", datum: point.datum)
                        })
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

struct PieChartPress: ViewModifier {
    let context: ComponentContext
    let data: PieChartData

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            if context.element.on["press"] != nil {
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { tap in
                            guard let anchor = proxy.plotFrame else { return }
                            let plot = geometry[anchor]
                            guard plot.contains(tap.location) else { return }
                            let location = CGPoint(x: tap.location.x - plot.minX, y: tap.location.y - plot.minY)
                            let radius = min(plot.width, plot.height) / 2
                            let distance = hypot(location.x - plot.width / 2, location.y - plot.height / 2)
                            let inner = context.props.bool("donut") == true ? radius * PieChartData.donutRatio : 0
                            guard distance <= radius, distance >= inner,
                                  let fraction: Double = proxy.value(atAngle: proxy.angle(at: location)),
                                  let slice = data.slice(at: fraction) else { return }
                            context.emit("press", datum: slice.datum)
                        })
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// Swift Charts may combine line marks into a series. An explicit accessibility
/// representation keeps every datum individually focusable and activatable.
struct ChartMarkAccessibility: View {
    let context: ComponentContext
    let points: [ChartData.Point]
    var fractions: [Double] = []

    var body: some View {
        VStack {
            ForEach(points) { point in
                let value = point.value.formatted() + (fractions.indices.contains(point.id) ? ", " + (fractions[point.id] * 100).formatted() + "%" : "")
                if context.element.on["press"] != nil {
                    Text(point.label)
                        .accessibilityLabel(point.label)
                        .accessibilityValue(value)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            var payload = point.datum.objectValue ?? [:]
                            if fractions.indices.contains(point.id) { payload["fraction"] = .number(fractions[point.id]) }
                            context.emit("press", datum: .object(payload))
                        }
                } else {
                    Text(point.label).accessibilityValue(value)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(context.props.string("title") ?? "Chart")
    }
}
