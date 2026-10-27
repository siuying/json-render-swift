import CoreGraphics
import Foundation
import JSONRenderSwiftUI

/// Per-edge lengths (padding, margin, border widths).
struct EdgeInsets: Sendable, Hashable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0

    static let zero = EdgeInsets()

    init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    init(all value: CGFloat) {
        self.init(top: value, left: value, bottom: value, right: value)
    }

    var horizontal: CGFloat { left + right }
    var vertical: CGFloat { top + bottom }
}

/// The flexbox subset the PDF catalog exposes.
struct BoxStyle: Sendable {
    enum Direction: Sendable { case column, row }
    enum Align: Sendable { case start, center, end, stretch }
    enum Justify: Sendable { case start, center, end, spaceBetween, spaceAround }
    enum Width: Sendable { case points(CGFloat), fraction(CGFloat) }

    var direction = Direction.column
    var gap: CGFloat = 0
    var padding = EdgeInsets.zero
    var margin = EdgeInsets.zero
    var border = EdgeInsets.zero
    var borderColor = PDFColor.black
    var borderRadius: CGFloat = 0
    var background: PDFColor?
    /// `flex: n` — grow weight with a zero basis (yoga semantics).
    var flex: CGFloat = 0
    var alignItems = Align.stretch
    var justifyContent = Justify.start
    var wrap = false
    var width: Width?
    var height: CGFloat?

    /// Padding plus border on each edge.
    var inset: EdgeInsets {
        EdgeInsets(
            top: padding.top + border.top,
            left: padding.left + border.left,
            bottom: padding.bottom + border.bottom,
            right: padding.right + border.right
        )
    }

    func resolvedWidth(in available: CGFloat) -> CGFloat? {
        switch width {
        case .points(let value)?: value
        case .fraction(let fraction)?: available * fraction
        case nil: nil
        }
    }
}

/// Typography of a text run.
struct TextStyle: Sendable {
    enum Alignment: Sendable { case left, center, right }

    var fontSize: CGFloat = 12
    var bold = false
    var italic = false
    var color = PDFColor.black
    var alignment = Alignment.left
    /// Multiplier of `fontSize`; `nil` uses the font's natural line height.
    var lineHeight: CGFloat?
    var underline = false
    /// Break words at hyphenation points (off for short UI labels such as form options).
    var hyphenate = true
}

/// What a node draws.
enum NodeContent: Sendable {
    case container([LayoutNode])
    case text(String, TextStyle)
    case image(ImageContent)
    /// The rectangle of a fillable field's widget (fixed size).
    case formWidget(FormWidgetRef)
    /// A bar or line chart's plot (fixed height, never split).
    case chart(ChartContent)
    case empty
}

/// One widget of a form field; radio groups have one per option.
struct FormWidgetRef: Sendable, Hashable {
    var fieldID: Int
    var option: Int?
    var kind: PDFFormFieldType
}

/// How pagination treats a container.
enum BreakBehavior: Sendable {
    /// Moves to the next page whole when it fits on one page; otherwise splits its children.
    case keepTogether
    /// Moves whole when it is at most a third of the page tall; otherwise flows.
    case keepTogetherIfSmall
    /// Splits between children freely (page content root).
    case flow
    /// Splits between rows only and repeats the first child (header) on continuation pages.
    case table
    /// A chart (optional title, then the plot): never split. Moves to the next page whole; when
    /// taller than the page, the plot is shortened so the chart fits on one page.
    case chart
}

/// A node of the resolved document, ready for measurement.
struct LayoutNode: Sendable {
    var style = BoxStyle()
    var content: NodeContent
    var breakBehavior = BreakBehavior.keepTogether
    /// Spec element key (diagnostics and tests).
    var key: String?
    var link: URL?
}

/// A `BarChart` or `LineChart` plot: the processed series (shared with the SwiftUI renderer)
/// and its color. Value labels, gridlines and category labels are laid out when drawn.
struct ChartContent: Sendable {
    enum Kind: Sendable { case bar, line }

    var kind: Kind
    var data: ChartData
    var color: PDFColor
}

/// An image to draw, already loaded (or failed → placeholder).
struct ImageContent: Sendable {
    enum Fit: String, Sendable { case contain, cover, fill, none }

    var source: String
    /// Decoded image bytes; `nil` draws the placeholder.
    var data: Data?
    var pixelSize: CGSize?
    var fit = Fit.contain
    /// Longest side images are downsampled to before drawing.
    var maxDrawDimension = 2_048
}
