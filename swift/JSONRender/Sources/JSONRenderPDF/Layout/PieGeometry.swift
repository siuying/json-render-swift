import CoreGraphics
import Foundation
import JSONRenderSwiftUI

/// Where a pie's slices go inside its frame (top-left origin): a circle as large as fits,
/// centered, slices from 12 o'clock clockwise in order, each spanning its share of 360°.
struct PieGeometry {
    /// 12 o'clock. Angles grow clockwise on the page (the y axis points down).
    static let startAngle = -CGFloat.pi / 2
    /// Gap between neighbouring slices, in points along the outer edge.
    static let gap: CGFloat = 1

    let center: CGPoint
    let radius: CGFloat
    /// 0 for a pie; ``PieChartData/donutRatio`` × `radius` for a donut.
    let innerRadius: CGFloat
    /// Each slice's start and end angle in radians; the last slice ends a full turn after the first starts.
    let angles: [(start: CGFloat, end: CGFloat)]

    init(data: PieChartData, frame: CGRect, donut: Bool) {
        center = CGPoint(x: frame.midX, y: frame.midY)
        radius = max(min(frame.width, frame.height) / 2, 0)
        innerRadius = donut ? radius * CGFloat(PieChartData.donutRatio) : 0
        var start = Self.startAngle
        var angles: [(start: CGFloat, end: CGFloat)] = []
        for (index, slice) in data.slices.enumerated() {
            let end = index == data.slices.count - 1 ? Self.startAngle + 2 * .pi : start + CGFloat(slice.fraction) * 2 * .pi
            angles.append((start, end))
            start = end
        }
        self.angles = angles
    }

    /// The slice's wedge (or ring segment), inset by half of ``gap`` on each side when there
    /// are several slices and the slice is wide enough.
    func path(_ index: Int) -> CGPath {
        var (start, end) = angles[index]
        if angles.count > 1, radius > 0 {
            let inset = Self.gap / 2 / radius
            if end - start > 4 * inset {
                start += inset
                end -= inset
            }
        }
        let path = CGMutablePath()
        if innerRadius > 0 {
            path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        } else {
            path.move(to: center)
            path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        }
        path.closeSubpath()
        return path
    }

    /// The square the pie is drawn in.
    var bounds: CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}
