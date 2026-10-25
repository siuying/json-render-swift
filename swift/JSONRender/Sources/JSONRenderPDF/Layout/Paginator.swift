import CoreGraphics
import Foundation

/// Splits a page's laid-out flow into page-sized fragments.
///
/// Rules:
/// - Text splits between lines.
/// - Rows (and table rows, and the visual lines of a wrapped row) move to the next page
///   whole when they fit on one page; taller rows split every child at the same cut.
/// - Views, Columns and Lists up to a third of the page height move whole too
///   (``BreakBehavior/keepTogetherIfSmall``); taller ones flow, splitting between children.
/// - Tables split only between rows and repeat the header row on each continuation page.
///   A row taller than a page is split across pages under the repeated header.
/// - Every page makes progress: content that cannot be split (an oversized empty box,
///   an image) is placed at the top of a page and clipped or scaled to fit.
struct Paginator {
    let pageHeight: CGFloat
    /// Pages this flow may still produce.
    let maxPages: Int

    /// Fraction of the page height up to which `keepTogetherIfSmall` boxes move whole.
    static let smallFraction: CGFloat = 1.0 / 3.0

    struct Result {
        var pages: [LaidBox]
        var truncated = false
        var clipped = false
    }

    func paginate(_ root: LaidBox) throws -> Result {
        var result = Result(pages: [])
        var remaining: LaidBox? = root
        while let box = remaining {
            try Task.checkCancellation()
            guard result.pages.count < maxPages else {
                result.truncated = true
                break
            }
            var (head, tail) = split(box, available: pageHeight, atPageTop: true)
            if head == nil || (tail.map { Self.isUnchanged($0, from: box) } ?? false) {
                // No progress is possible: clip what is left to this page.
                head = Self.clip(box, to: pageHeight)
                tail = nil
                result.clipped = true
            }
            result.pages.append(head ?? Self.emptyFragment(of: box))
            remaining = tail.flatMap { Self.hasContent($0) ? $0 : nil }
        }
        if result.pages.isEmpty { result.pages = [Self.emptyFragment(of: root)] }
        return result
    }

    // MARK: Splitting

    /// Splits `box` so the head's border box is at most `available` tall. `nil` head:
    /// nothing fits (move the whole box on). `nil` tail: everything fits.
    private func split(_ box: LaidBox, available: CGFloat, atPageTop: Bool) -> (LaidBox?, LaidBox?) {
        if box.frame.height <= available + 0.01 { return (box, nil) }
        guard available > 0.01 else { return atPageTop ? (Self.clip(box, to: 0), nil) : (nil, box) }
        switch box.content {
        case .text(let lines, let style):
            return splitText(box, lines: lines, style: style, available: available, atPageTop: atPageTop)
        case .container(let children):
            let fitsOnPage = box.outerHeight <= pageHeight
            switch box.breakBehavior {
            case .keepTogether where !atPageTop && fitsOnPage:
                return (nil, box)
            case .keepTogetherIfSmall where !atPageTop && fitsOnPage && box.outerHeight <= pageHeight * Self.smallFraction:
                return (nil, box)
            case .table:
                return splitTable(box, children: children, available: available, atPageTop: atPageTop)
            default:
                return box.style.direction == .row
                    ? splitRow(box, children: children, available: available, atPageTop: atPageTop)
                    : splitColumn(box, children: children, available: available, atPageTop: atPageTop)
            }
        case .image, .formWidget, .empty:
            return atPageTop ? (Self.clip(box, to: available), nil) : (nil, box)
        }
    }

    private func splitText(
        _ box: LaidBox, lines: [TextLine], style: TextStyle, available: CGFloat, atPageTop: Bool
    ) -> (LaidBox?, LaidBox?) {
        let inset = box.style.inset
        let count = lines.prefix { inset.top + $0.y + $0.height <= available + 0.01 }.count
        if count == 0 {
            guard atPageTop else { return (nil, box) }
            // A single line taller than the remaining page cannot be placed whole.
            return (Self.clip(box, to: available), nil)
        }
        guard count < lines.count else { return (box, nil) }
        var head = box
        head.content = .text(lines: Array(lines[..<count]), style: style)
        head.frame.size.height = min(inset.top + lines[count - 1].y + lines[count - 1].height, available)
        head.style.margin.bottom = 0
        let shift = lines[count].y
        let rest = lines[count...].map { line -> TextLine in
            var moved = line
            moved.y -= shift
            return moved
        }
        var tail = box
        tail.content = .text(lines: rest, style: style)
        tail.frame.size.height = (rest.last.map { $0.y + $0.height } ?? 0) + inset.bottom
        tail.style.margin.top = 0
        return (head, tail)
    }

    private func splitColumn(
        _ box: LaidBox, children: [LaidBox], available: CGFloat, atPageTop: Bool
    ) -> (LaidBox?, LaidBox?) {
        let inset = box.style.inset
        var head: [LaidBox] = []
        var tail: [LaidBox] = []
        var tailHasFragment = false
        for child in children {
            if !tail.isEmpty {
                tail.append(child)
                continue
            }
            if child.frame.maxY + child.style.margin.bottom + inset.bottom <= available + 0.01 {
                head.append(child)
                continue
            }
            let childAvailable = available - inset.bottom - child.frame.minY
            let (childHead, childTail) = childAvailable > 0.01
                ? split(child, available: childAvailable, atPageTop: atPageTop && head.isEmpty)
                : (nil, child)
            if let childHead { head.append(childHead) }
            if let childTail {
                tail.append(childTail)
                tailHasFragment = childHead != nil
            }
        }
        if head.isEmpty { return (nil, box) }
        var headBox = box
        headBox.content = .container(head)
        let contentBottom = (head.map { $0.frame.maxY + $0.style.margin.bottom }.max() ?? inset.top) + inset.bottom
        if tail.isEmpty {
            headBox.frame.size.height = min(max(box.frame.height, contentBottom), available)
            return (headBox, nil)
        }
        headBox.frame.size.height = min(contentBottom, available)
        headBox.style.margin.bottom = 0
        return (headBox, restackedTail(tail, of: box, firstIsFragment: tailHasFragment))
    }

    private func splitRow(
        _ box: LaidBox, children: [LaidBox], available: CGFloat, atPageTop: Bool
    ) -> (LaidBox?, LaidBox?) {
        let inset = box.style.inset
        var head: [LaidBox] = []
        var tail: [LaidBox] = []
        for child in children {
            let childAvailable = available - inset.bottom - child.frame.minY
            let (childHead, childTail) = childAvailable > 0.01
                ? split(child, available: childAvailable, atPageTop: atPageTop)
                : (nil, child)
            if let childHead { head.append(childHead) }
            if var childTail {
                childTail.frame.origin.y = inset.top
                tail.append(childTail)
            }
        }
        if head.isEmpty { return (nil, box) }
        var headBox = box
        headBox.content = .container(head)
        headBox.frame.size.height = min(
            (head.map { $0.frame.maxY + $0.style.margin.bottom }.max() ?? inset.top) + inset.bottom, available
        )
        if tail.isEmpty { return (headBox, nil) }
        headBox.style.margin.bottom = 0
        var tailBox = box
        tailBox.content = .container(tail)
        tailBox.frame.size.height = (tail.map { $0.frame.maxY + $0.style.margin.bottom }.max() ?? inset.top) + inset.bottom
        tailBox.style.margin.top = 0
        return (headBox, tailBox)
    }

    private func splitTable(
        _ box: LaidBox, children: [LaidBox], available: CGFloat, atPageTop: Bool
    ) -> (LaidBox?, LaidBox?) {
        guard let header = children.first else { return (box, nil) }
        let inset = box.style.inset
        guard header.frame.maxY + inset.bottom <= available + 0.01 else {
            return atPageTop ? (Self.clip(box, to: available), nil) : (nil, box)
        }
        var fitting = 1
        while fitting < children.count, children[fitting].frame.maxY + inset.bottom <= available + 0.01 {
            fitting += 1
        }
        var head = Array(children[..<fitting])
        var rest = Array(children[fitting...])
        if fitting < 2, children.count > 1 {
            // Header plus at least one row; at the top of a page a row too tall for the
            // remaining space is split across pages under the repeated header.
            guard atPageTop else { return (nil, box) }
            let row = children[1]
            let rowAvailable = available - inset.bottom - row.frame.minY
            let (rowHead, rowTail) = rowAvailable > 0.01 ? split(row, available: rowAvailable, atPageTop: true) : (nil, row)
            guard let rowHead else { return (nil, box) }
            head = [header, rowHead]
            rest = (rowTail.map { [$0] } ?? []) + children[2...]
        }
        var headBox = box
        headBox.content = .container(head)
        headBox.frame.size.height = min((head.last?.frame.maxY ?? 0) + inset.bottom, available)
        if rest.isEmpty { return (headBox, nil) }
        headBox.style.margin.bottom = 0
        return (headBox, restackedTail([header] + rest, of: box, firstIsFragment: false))
    }

    // MARK: Helpers

    /// A continuation box whose children are re-stacked from the content top.
    private func restackedTail(_ children: [LaidBox], of box: LaidBox, firstIsFragment: Bool) -> LaidBox {
        var y = box.style.inset.top
        let stacked = children.enumerated().map { index, child -> LaidBox in
            var moved = child
            if index > 0 { y += box.style.gap }
            if !(index == 0 && firstIsFragment) { y += child.style.margin.top }
            moved.frame.origin.y = y
            y += child.frame.height + child.style.margin.bottom
            return moved
        }
        var tail = box
        tail.content = .container(stacked)
        tail.frame.size.height = y + box.style.inset.bottom
        tail.style.margin.top = 0
        return tail
    }

    /// `box` cut to `height`: children (and text lines) that do not fit are dropped and
    /// images scaled down, so nothing is painted below the cut.
    static func clip(_ box: LaidBox, to height: CGFloat) -> LaidBox {
        let height = max(height, 0)
        guard box.frame.height > height + 0.01 else { return box }
        var clipped = box
        switch box.content {
        case .container(let children):
            clipped.content = .container(children.compactMap { child in
                guard child.frame.minY < height - 0.01 else { return nil }
                return clip(child, to: height - child.frame.minY)
            })
        case .text(let lines, let style):
            let inset = box.style.inset
            clipped.content = .text(lines: lines.filter { inset.top + $0.y + $0.height <= height + 0.01 }, style: style)
        case .image:
            let scale = box.frame.height > 0 ? height / box.frame.height : 0
            clipped.frame.size.width = box.frame.width * scale
        case .formWidget:
            clipped.content = .empty
        case .empty:
            break
        }
        clipped.frame.size.height = height
        return clipped
    }

    private static func isUnchanged(_ tail: LaidBox, from box: LaidBox) -> Bool {
        abs(tail.frame.height - box.frame.height) < 0.01 && contentCount(tail) == contentCount(box)
    }

    private static func contentCount(_ box: LaidBox) -> Int {
        switch box.content {
        case .container(let children): children.count
        case .text(let lines, _): lines.count
        default: 1
        }
    }

    private static func hasContent(_ box: LaidBox) -> Bool {
        if box.frame.height > 0.01 { return true }
        switch box.content {
        case .container(let children): return !children.isEmpty
        case .text(let lines, _): return !lines.isEmpty
        default: return true
        }
    }

    private static func emptyFragment(of box: LaidBox) -> LaidBox {
        var empty = box
        empty.content = .container([])
        empty.frame.size.height = 0
        return empty
    }
}
