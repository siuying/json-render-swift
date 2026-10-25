import CoreGraphics
import Foundation

/// Port of `@react-pdf/textkit`'s line breaker: Knuth & Plass optimal fit (Bram Stein's
/// implementation, BSD licence) over boxes (syllables), glue (spaces) and hyphenation
/// penalties, with textkit's parameters, tolerance retries and best-fit fallback.
enum LineBreaker {
    enum Node {
        /// A syllable: UTF-16 range [start, end).
        case box(width: CGFloat, start: Int, end: Int)
        /// Inter-word space: UTF-16 range [start, end).
        case glue(width: CGFloat, start: Int, end: Int, stretch: CGFloat, shrink: CGFloat)
        case penalty(width: CGFloat, penalty: CGFloat, flagged: CGFloat)

        var isBox: Bool { if case .box = self { true } else { false } }
        var isGlue: Bool { if case .glue = self { true } else { false } }
        var isPenalty: Bool { if case .penalty = self { true } else { false } }
        var end: Int {
            switch self {
            case .box(_, _, let end), .glue(_, _, let end, _, _): end
            case .penalty: 0
            }
        }
    }

    static let infinity: CGFloat = 10_000
    /// textkit `getNodes`: glue stretch = width·3/6, shrink = width·3/9.
    private static let glueStretch: CGFloat = 3.0 / 6.0
    private static let glueShrink: CGFloat = 3.0 / 9.0
    /// textkit uses a fixed 5 pt hyphen width and penalty 600 for non-justified text.
    static let hyphenWidth: CGFloat = 5
    static let hyphenPenalty: CGFloat = 600

    /// Builds nodes for one paragraph from its syllables (spaces are their own tokens).
    static func nodes(syllables: [String], width: (Int, Int) -> CGFloat) -> [Node] {
        var nodes: [Node] = []
        var start = 0
        for (index, syllable) in syllables.enumerated() {
            let length = syllable.utf16.count
            let end = start + length
            let advance = width(start, end)
            if syllable.allSatisfy({ $0 == " " }) {
                nodes.append(.glue(width: advance, start: start, end: end,
                                   stretch: advance * glueStretch, shrink: advance * glueShrink))
            } else {
                nodes.append(.box(width: advance, start: start, end: end))
                let hyphenated = index + 1 < syllables.count && !syllables[index + 1].allSatisfy { $0 == " " }
                if hyphenated {
                    nodes.append(.penalty(width: hyphenWidth, penalty: hyphenPenalty, flagged: 1))
                }
            }
            start = end
        }
        nodes.append(.glue(width: 0, start: start, end: start, stretch: infinity, shrink: 0))
        nodes.append(.penalty(width: 0, penalty: -infinity, flagged: 1))
        return nodes
    }

    /// textkit `linebreaker`: K&P with tolerance 4, retried up to 50, else best fit.
    /// Returns break node indices (excluding the leading 0).
    static func breaks(_ nodes: [Node], lineWidth: CGFloat) -> [Int] {
        var tolerance: CGFloat = 4
        var result = knuthPlass(nodes, lineWidth: lineWidth, tolerance: tolerance)
        while result.isEmpty && tolerance < 50 {
            tolerance += 5
            result = knuthPlass(nodes, lineWidth: lineWidth, tolerance: tolerance)
        }
        if result.isEmpty || result == [0] { result = bestFit(nodes, lineWidth: lineWidth) }
        return Array(result.dropFirst())
    }

    // MARK: Knuth & Plass

    private struct Totals {
        var width: CGFloat = 0
        var stretch: CGFloat = 0
        var shrink: CGFloat = 0
    }

    private final class Breakpoint {
        let position: Int
        let demerits: CGFloat
        let line: Int
        let fitnessClass: Int
        let totals: Totals
        let previous: Breakpoint?

        init(position: Int, demerits: CGFloat, line: Int, fitnessClass: Int, totals: Totals, previous: Breakpoint?) {
            self.position = position
            self.demerits = demerits
            self.line = line
            self.fitnessClass = fitnessClass
            self.totals = totals
            self.previous = previous
        }
    }

    private static func knuthPlass(_ nodes: [Node], lineWidth: CGFloat, tolerance: CGFloat) -> [Int] {
        var active = [Breakpoint(position: 0, demerits: 0, line: 0, fitnessClass: 0, totals: Totals(), previous: nil)]
        var sum = Totals()

        func cost(_ end: Int, _ breakpoint: Breakpoint) -> CGFloat {
            var width = sum.width - breakpoint.totals.width
            if case .penalty(let penaltyWidth, _, _) = nodes[end] { width += penaltyWidth }
            if width < lineWidth {
                let stretch = sum.stretch - breakpoint.totals.stretch
                return stretch > 0 ? (lineWidth - width) / stretch : infinity
            }
            if width > lineWidth {
                let shrink = sum.shrink - breakpoint.totals.shrink
                return shrink > 0 ? (lineWidth - width) / shrink : infinity
            }
            return 0
        }

        func sumAfter(_ index: Int) -> Totals {
            var result = sum
            for i in index..<nodes.count {
                switch nodes[i] {
                case .glue(let width, _, _, let stretch, let shrink):
                    result.width += width
                    result.stretch += stretch
                    result.shrink += shrink
                case .box:
                    return result
                case .penalty(_, let penalty, _) where penalty == -infinity && i > index:
                    return result
                default:
                    break
                }
            }
            return result
        }

        func mainLoop(_ index: Int) {
            let node = nodes[index]
            var candidates: [(breakpoint: Breakpoint?, demerits: CGFloat)] = Array(repeating: (nil, .infinity), count: 4)
            var survivors: [Breakpoint] = []
            let forced: Bool = if case .penalty(_, let penalty, _) = node { penalty == -infinity } else { false }
            for breakpoint in active {
                let ratio = cost(index, breakpoint)
                if !(ratio < -1 || forced) { survivors.append(breakpoint) }
                guard ratio >= -1 && ratio <= tolerance else { continue }
                let badness = 100 * pow(abs(ratio), 3)
                let lineDemerits = 10 + badness
                var demerits = lineDemerits * lineDemerits
                if case .penalty(_, let penalty, let flagged) = node {
                    if penalty >= 0 {
                        demerits += penalty * penalty
                    } else if penalty != -infinity {
                        demerits -= penalty * penalty
                    }
                    if case .penalty(_, _, let previousFlagged) = nodes[breakpoint.position] {
                        demerits += 100 * flagged * previousFlagged
                    }
                }
                let fitnessClass = ratio < -0.5 ? 0 : ratio <= 0.5 ? 1 : ratio <= 1 ? 2 : 3
                if abs(fitnessClass - breakpoint.fitnessClass) > 1 { demerits += 3000 }
                demerits += breakpoint.demerits
                if demerits < candidates[fitnessClass].demerits {
                    candidates[fitnessClass] = (breakpoint, demerits)
                }
            }
            active = survivors
            let totals = sumAfter(index)
            for (fitnessClass, candidate) in candidates.enumerated() {
                guard let previous = candidate.breakpoint else { continue }
                active.append(Breakpoint(
                    position: index, demerits: candidate.demerits, line: previous.line + 1,
                    fitnessClass: fitnessClass, totals: totals, previous: previous
                ))
            }
        }

        for (index, node) in nodes.enumerated() {
            switch node {
            case .box(let width, _, _):
                sum.width += width
            case .glue(let width, _, _, let stretch, let shrink):
                if index > 0, nodes[index - 1].isBox { mainLoop(index) }
                sum.width += width
                sum.stretch += stretch
                sum.shrink += shrink
            case .penalty(_, let penalty, _):
                if penalty != infinity { mainLoop(index) }
            }
        }

        guard var best = active.first else { return [] }
        for breakpoint in active where breakpoint.demerits < best.demerits { best = breakpoint }
        var positions: [Int] = []
        var current: Breakpoint? = best
        while let breakpoint = current {
            positions.append(breakpoint.position)
            current = breakpoint.previous
        }
        return positions.reversed()
    }

    // MARK: Best fit

    private static func bestFit(_ nodes: [Node], lineWidth: CGFloat) -> [Int] {
        var count = 0
        var breakpoints = [0]
        var subnodes = nodes[...]
        while !subnodes.isEmpty {
            guard let position = nextBreakpoint(Array(subnodes), lineWidth: lineWidth) else { break }
            count += position
            breakpoints.append(count)
            subnodes = subnodes.dropFirst(position + 1)
            count += 1
        }
        return breakpoints
    }

    private static func nextBreakpoint(_ nodes: [Node], lineWidth: CGFloat) -> Int? {
        var position: Int?
        var minimumBadness = CGFloat.infinity
        var sum = Totals()

        func ratio(_ node: Node) -> CGFloat {
            if sum.width < lineWidth {
                guard case .glue(_, _, _, let stretch, _) = node else { return infinity }
                return sum.stretch - stretch > 0 ? (lineWidth - sum.width) / sum.stretch : infinity
            }
            if sum.width > lineWidth {
                guard case .glue(_, _, _, _, let shrink) = node else { return infinity }
                return sum.shrink - shrink > 0 ? (lineWidth - sum.width) / sum.shrink : infinity
            }
            return 0
        }

        func endOfLine(after start: Int) -> Node {
            var j = start + 1
            while j < nodes.count, !nodes[j].isBox { j += 1 }
            return nodes[j - 1]
        }

        var hyphen: CGFloat = 0
        for (i, node) in nodes.enumerated() {
            switch node {
            case .box(let width, _, _):
                sum.width += width
            case .glue(let width, _, _, let stretch, let shrink):
                sum.width += width
                sum.stretch += stretch
                sum.shrink += shrink
            case .penalty:
                break
            }
            if case .penalty(let width, _, _) = endOfLine(after: i) { hyphen = width } else { hyphen = 0 }
            if sum.width - sum.shrink + hyphen > lineWidth {
                if position == nil {
                    var j = i == 0 ? 1 : i
                    while j < nodes.count, !nodes[j].isBox { j += 1 }
                    position = j - 1
                }
                break
            }
            if node.isPenalty || node.isGlue {
                let penalty: CGFloat = if case .penalty(_, let value, _) = node { value } else { 0 }
                let badness = 100 * pow(abs(ratio(node)), 3) + penalty
                if minimumBadness >= badness {
                    position = i
                    minimumBadness = badness
                }
            }
        }
        return sum.width - sum.shrink + hyphen > lineWidth ? position : nil
    }
}
