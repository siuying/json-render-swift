import CoreGraphics
import Foundation

/// What a laid-out box draws.
enum LaidContent {
    case container([LaidBox])
    case text(lines: [TextLine], style: TextStyle)
    case image(ImageContent)
    case formWidget(FormWidgetRef)
    case chart(ChartContent)
    case empty
}

/// A measured box. `frame` is the border box relative to the parent's border box
/// (top-left origin, points); `margin` is kept for re-stacking after page breaks.
struct LaidBox {
    var frame: CGRect
    var style: BoxStyle
    var content: LaidContent
    var breakBehavior: BreakBehavior
    var key: String?
    var link: URL?

    var outerHeight: CGFloat { frame.height + style.margin.vertical }
}

/// A measured flexbox subset modelled on yoga as used by react-pdf: column and row
/// stacks with `gap`, padding, margins, borders, `flex` grow weights (zero basis),
/// shrinking of auto-sized row children, `alignItems`, `justifyContent` and row `wrap`.
///
/// A column with a definite height (the page content area, a fixed `height`, or a
/// container stretched by its row) distributes free space to `flex` children and then
/// applies `justifyContent`. A wrapped row lays each visual line out as its own box so
/// pagination can break between lines.
final class LayoutEngine {
    let text: TextEngine
    /// Page and total substituted into `PageNumber` formats when measuring them.
    var pageNumberSample = 1

    init(text: TextEngine = TextEngine()) {
        self.text = text
    }

    /// Lays `node` out in a border box `width` points wide; `height` makes the box's
    /// height definite (used for column flex and justification).
    func layout(_ node: LayoutNode, width: CGFloat, height definiteHeight: CGFloat? = nil) -> LaidBox {
        let style = node.style
        let inset = style.inset
        let width = width.isFinite ? max(width, 0) : 0
        let innerWidth = max(width - inset.horizontal, 0)
        var size = CGSize(width: width, height: 0)
        var direction = style.direction
        let content: LaidContent
        switch node.content {
        case .text(let string, let textStyle):
            let lines = text.lines(string, textStyle, width: innerWidth)
            content = .text(lines: lines, style: textStyle)
            size.height = (lines.last.map { $0.y + $0.height } ?? 0) + inset.vertical
        case .image(let image):
            size = imageSize(node, image, available: width)
            content = .image(image)
        case .formWidget(let widget):
            size = CGSize(width: style.resolvedWidth(in: width).map { min($0, width) } ?? width, height: style.height ?? 22)
            content = .formWidget(widget)
        case .chart(let chart):
            size.height = style.height ?? 300
            content = .chart(chart)
        case .empty:
            size.height = inset.vertical
            content = .empty
        case .container(let children):
            let fixed = (style.height ?? definiteHeight).map { max($0 - inset.vertical, 0) }
            let (laid, height): ([LaidBox], CGFloat)
            if style.direction == .row && style.wrap {
                (laid, height) = layoutWrappedRow(children, style: style, innerWidth: innerWidth)
                direction = .column // paginates line by line
            } else if style.direction == .row {
                (laid, height) = layoutRowLine(
                    Array(children.indices), children: children, style: style, innerWidth: innerWidth,
                    top: inset.top, left: inset.left, crossSize: fixed
                )
            } else {
                (laid, height) = layoutColumn(children, style: style, innerWidth: innerWidth, innerHeight: fixed)
            }
            content = .container(laid)
            size.height = max(height, fixed ?? 0) + inset.vertical
        }
        // An explicit `height` is exact; a parent-supplied height is a minimum (overflowing
        // content keeps its natural height so pagination sees it).
        if let fixed = style.height { size.height = max(fixed, inset.vertical) }
        var laidStyle = style
        laidStyle.direction = direction
        return LaidBox(
            frame: CGRect(origin: .zero, size: size), style: laidStyle, content: content,
            breakBehavior: node.breakBehavior, key: node.key, link: node.link
        )
    }

    /// A chart's max-content width: what it gets in a row without `flex` (before shrinking).
    static let chartContentWidth: CGFloat = 320

    func sampleText(_ spec: PageNumberSpec) -> String {
        spec.text(page: pageNumberSample, total: pageNumberSample)
    }

    /// The max-content border-box width (no wrapping).
    func maxContentWidth(_ node: LayoutNode) -> CGFloat {
        if case .points(let width)? = node.style.width { return width }
        let inset = node.style.inset.horizontal
        switch node.content {
        case .text(let string, let style):
            return text.maxContentWidth(string, style) + inset
        case .image(let image):
            return imageSize(node, image, available: .greatestFiniteMagnitude).width
        case .formWidget:
            return 0
        case .chart:
            return Self.chartContentWidth + inset
        case .empty:
            return inset
        case .container(let children):
            let widths = children.map { maxContentWidth($0) + $0.style.margin.horizontal }
            if node.style.direction == .row {
                return widths.reduce(0, +) + node.style.gap * CGFloat(max(children.count - 1, 0)) + inset
            }
            return (widths.max() ?? 0) + inset
        }
    }

    // MARK: Column

    /// Stacks children; with a definite `innerHeight`, grows `flex` children into the free
    /// space and then applies `justifyContent` to what is left.
    private func layoutColumn(
        _ children: [LayoutNode], style: BoxStyle, innerWidth: CGFloat, innerHeight: CGFloat?
    ) -> ([LaidBox], CGFloat) {
        let inset = style.inset
        var boxes = children.map { child in layout(child, width: columnChildWidth(child, style: style, innerWidth: innerWidth)) }
        let gaps = style.gap * CGFloat(max(children.count - 1, 0))
        func used() -> CGFloat {
            zip(children, boxes).map { $1.frame.height + $0.style.margin.vertical }.reduce(0, +) + gaps
        }
        var free = (innerHeight ?? 0) - used()
        let flexTotal = children.map(\.style.flex).reduce(0, +)
        if innerHeight != nil, free > 0, flexTotal > 0 {
            for index in children.indices where children[index].style.flex > 0 {
                let grown = boxes[index].frame.height + free * children[index].style.flex / flexTotal
                boxes[index] = layout(children[index], width: boxes[index].frame.width, height: grown)
            }
            free = max((innerHeight ?? 0) - used(), 0)
        }
        let leftover = innerHeight == nil ? 0 : max(free, 0)
        var (y, extraGap) = Self.justify(leftover, count: children.count, style.justifyContent)
        for index in children.indices {
            let child = children[index]
            let available = max(innerWidth - child.style.margin.horizontal, 0)
            let offset: CGFloat = switch style.alignItems {
            case .center: (available - boxes[index].frame.width) / 2
            case .end: available - boxes[index].frame.width
            case .start, .stretch: 0
            }
            y += child.style.margin.top
            boxes[index].frame.origin = CGPoint(x: inset.left + child.style.margin.left + max(offset, 0), y: inset.top + y)
            y += boxes[index].frame.height + child.style.margin.bottom + style.gap + extraGap
        }
        if !children.isEmpty { y -= style.gap + extraGap }
        return (boxes, y)
    }

    private func columnChildWidth(_ child: LayoutNode, style: BoxStyle, innerWidth: CGFloat) -> CGFloat {
        let available = max(innerWidth - child.style.margin.horizontal, 0)
        if let fixed = child.style.resolvedWidth(in: innerWidth) { return min(fixed, available) }
        if style.alignItems == .stretch || isImage(child) { return available }
        return min(maxContentWidth(child), available)
    }

    /// Start offset and extra spacing for `justifyContent` over `leftover` space.
    private static func justify(_ leftover: CGFloat, count: Int, _ justify: BoxStyle.Justify) -> (CGFloat, CGFloat) {
        guard leftover > 0, count > 0 else { return (0, 0) }
        switch justify {
        case .start: return (0, 0)
        case .center: return (leftover / 2, 0)
        case .end: return (leftover, 0)
        case .spaceBetween: return count > 1 ? (0, leftover / CGFloat(count - 1)) : (0, 0)
        case .spaceAround:
            let share = leftover / CGFloat(count)
            return (share / 2, share)
        }
    }

    // MARK: Row

    /// Greedy line breaking on base widths; each visual line becomes a row box.
    private func layoutWrappedRow(_ children: [LayoutNode], style: BoxStyle, innerWidth: CGFloat) -> ([LaidBox], CGFloat) {
        let inset = style.inset
        let bases = children.map { baseWidth($0, innerWidth: innerWidth) }
        var lines: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for index in children.indices {
            let outer = bases[index] + children[index].style.margin.horizontal
            let needed = current.isEmpty ? outer : used + style.gap + outer
            if !current.isEmpty && needed > innerWidth + 0.01 {
                lines.append(current)
                current = [index]
                used = outer
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { lines.append(current) }
        var lineStyle = BoxStyle()
        lineStyle.direction = .row
        var boxes: [LaidBox] = []
        var top = inset.top
        for (number, line) in lines.enumerated() {
            if number > 0 { top += style.gap }
            let (laid, height) = layoutRowLine(line, children: children, style: style, innerWidth: innerWidth, top: 0, left: 0, crossSize: nil)
            boxes.append(LaidBox(
                frame: CGRect(x: inset.left, y: top, width: innerWidth, height: height), style: lineStyle,
                content: .container(laid), breakBehavior: .keepTogether, key: nil, link: nil
            ))
            top += height
        }
        return (boxes, top - inset.top)
    }

    private func baseWidth(_ child: LayoutNode, innerWidth: CGFloat) -> CGFloat {
        if let fixed = child.style.resolvedWidth(in: innerWidth) { return fixed }
        if child.style.flex > 0 { return 0 }
        return min(maxContentWidth(child), innerWidth)
    }

    /// One row line: grow by `flex`, shrink auto-sized children when overfull, then
    /// align on the cross axis (stretched containers get a definite height) and justify
    /// on the main axis. Returns the line height.
    private func layoutRowLine(
        _ indices: [Int], children: [LayoutNode], style: BoxStyle, innerWidth: CGFloat,
        top: CGFloat, left: CGFloat, crossSize: CGFloat?
    ) -> ([LaidBox], CGFloat) {
        guard !indices.isEmpty else { return ([], 0) }
        var widths = indices.map { baseWidth(children[$0], innerWidth: innerWidth) }
        let margins = indices.map { children[$0].style.margin.horizontal }
        let gaps = style.gap * CGFloat(indices.count - 1)
        var free = innerWidth - widths.reduce(0, +) - margins.reduce(0, +) - gaps
        let flexTotal = indices.map { children[$0].style.flex }.reduce(0, +)
        if free > 0, flexTotal > 0 {
            for (slot, index) in indices.enumerated() where children[index].style.flex > 0 {
                widths[slot] += free * children[index].style.flex / flexTotal
            }
            free = 0
        } else if free < -0.01 { // ignore rounding: a max-content child must not shrink by an ulp
            let shrinkable = indices.enumerated().filter { slot, index in
                children[index].style.width == nil && children[index].style.flex == 0 && !isImage(children[index]) && widths[slot] > 0
            }
            let total = shrinkable.map { widths[$0.offset] }.reduce(0, +)
            if total > 0 {
                let deficit = min(-free, total)
                for (slot, _) in shrinkable { widths[slot] -= deficit * widths[slot] / total }
                free += deficit
            }
        }

        var boxes = zip(indices, widths).map { index, width in layout(children[index], width: max(width, 0)) }
        var lineHeight = zip(indices, boxes).map { index, box in box.frame.height + children[index].style.margin.vertical }.max() ?? 0
        if let crossSize { lineHeight = max(lineHeight, crossSize) }

        let (start, extraGap) = Self.justify(max(free, 0), count: indices.count, style.justifyContent)
        var x = start
        for (slot, index) in indices.enumerated() {
            let child = children[index]
            let margin = child.style.margin
            if style.alignItems == .stretch, child.style.height == nil, !isImage(child) {
                let stretched = max(lineHeight - margin.vertical, boxes[slot].frame.height)
                if isContainer(child), stretched > boxes[slot].frame.height + 0.01 {
                    boxes[slot] = layout(child, width: boxes[slot].frame.width, height: stretched)
                } else {
                    boxes[slot].frame.size.height = stretched
                }
            }
            let outer = boxes[slot].frame.height + margin.vertical
            let crossOffset: CGFloat = switch style.alignItems {
            case .center: (lineHeight - outer) / 2
            case .end: lineHeight - outer
            case .start, .stretch: 0
            }
            boxes[slot].frame.origin = CGPoint(x: left + x + margin.left, y: top + crossOffset + margin.top)
            x += widths[slot] + margin.horizontal + style.gap + extraGap
        }
        return (boxes, lineHeight)
    }

    // MARK: Helpers

    private func isImage(_ node: LayoutNode) -> Bool {
        if case .image = node.content { return true }
        return false
    }

    private func isContainer(_ node: LayoutNode) -> Bool {
        if case .container = node.content { return true }
        return false
    }

    /// Explicit size, else derived from the natural (pixel = point) size and aspect ratio,
    /// scaled down to the available width. Placeholders default to 100 × 75.
    func imageSize(_ node: LayoutNode, _ image: ImageContent, available: CGFloat) -> CGSize {
        let natural = image.pixelSize
        let aspect = natural.map { $0.height / $0.width } ?? 0.75
        var size: CGSize
        switch (node.style.resolvedWidth(in: available), node.style.height) {
        case let (width?, height?): size = CGSize(width: width, height: height)
        case let (width?, nil): size = CGSize(width: width, height: width * aspect)
        case let (nil, height?): size = CGSize(width: aspect > 0 ? height / aspect : height, height: height)
        case (nil, nil): size = natural ?? CGSize(width: 100, height: 75)
        }
        if size.width > available, available > 0 {
            let scale = available / size.width
            size = CGSize(width: available, height: node.style.height ?? size.height * scale)
        }
        return CGSize(width: size.width.isFinite ? size.width : 0, height: size.height.isFinite ? size.height : 0)
    }
}
