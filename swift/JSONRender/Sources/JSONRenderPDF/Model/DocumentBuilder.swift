import CoreGraphics
import Foundation
import JSONRenderSwiftUI

/// A `PageNumber`: a page footer drawn in the bottom margin of every physical page of its
/// `Page`, wherever it appears in the element tree. It takes no space in the flow.
struct PageNumberSpec: Sendable {
    var format: String
    var style: TextStyle

    func text(page: Int, total: Int) -> String {
        EmojiStripper.strip(
            format.replacingFirst("{pageNumber}", with: String(page)).replacingFirst("{totalPages}", with: String(total))
        )
    }
}

/// One `Page` element: geometry plus its flow content (may produce several physical pages).
struct PageModel: Sendable {
    var size: CGSize
    var margins: EdgeInsets
    var background: PDFColor?
    var content: LayoutNode
    var pageNumbers: [PageNumberSpec]
    /// Height reserved at the bottom for the page-number footer (at least `margins.bottom`).
    var footerHeight: CGFloat = 0

    /// The bottom margin in effect: grown when the footer needs more room than the margin.
    var effectiveBottomMargin: CGFloat { max(margins.bottom, footerHeight) }

    var contentRect: CGRect {
        CGRect(
            x: margins.left, y: margins.top,
            width: max(size.width - margins.horizontal, 1),
            height: max(size.height - margins.top - effectiveBottomMargin, 1)
        )
    }
}

struct DocumentModel: Sendable {
    var title: String?
    var author: String?
    var subject: String?
    var pages: [PageModel]
    var form = FormModel()
}

/// Paper sizes in points (react-pdf / PDFKit values).
enum PaperSize: String, CaseIterable {
    case a3 = "A3", a4 = "A4", a5 = "A5", letter = "LETTER", legal = "LEGAL", tabloid = "TABLOID"

    var size: CGSize {
        switch self {
        case .a3: CGSize(width: 841.89, height: 1190.55)
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .a5: CGSize(width: 419.53, height: 595.28)
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1008)
        case .tabloid: CGSize(width: 792, height: 1224)
        }
    }
}

/// Maps resolved catalog components to layout nodes, mirroring the style recipes of
/// `@json-render/react-pdf` `components/standard.tsx`.
final class DocumentBuilder {
    static let componentTypes: Set<String> = [
        "Document", "Page", "View", "Row", "Column", "Heading", "Text", "Image", "Link",
        "Table", "List", "Divider", "Spacer", "PageNumber",
        "FieldSet", "TextInput", "Checkbox", "RadioGroup", "Select", "ListBox",
    ]

    /// Lengths (padding, gaps, borders, sizes) are clamped to this range.
    static let length: ClosedRange<CGFloat> = 0...10_000
    static let fontSize: ClosedRange<CGFloat> = 1...500

    private let images: [String: LoadedImage]
    private var pageNumbers: [PageNumberSpec] = []
    /// Fields and FieldSets collected while building (document order).
    var form = FormModel()
    /// Enclosing FieldSet indices while building.
    var fieldSetStack: [Int] = []
    var usedFieldNames: Set<String> = []

    init(images: [String: LoadedImage]) {
        self.images = images
    }

    func document(from root: ResolvedElement?) -> DocumentModel {
        guard let root else { return DocumentModel(pages: [emptyPage()]) }
        var model = DocumentModel(pages: [])
        switch root.type {
        case "Document":
            model.title = root.string("title")
            model.author = root.string("author")
            model.subject = root.string("subject")
            var loose: [ResolvedElement] = []
            func flushLoose() {
                guard !loose.isEmpty else { return }
                model.pages.append(page(nil, children: loose))
                loose.removeAll()
            }
            for child in root.children {
                if child.type == "Page" {
                    flushLoose()
                    model.pages.append(page(child, children: child.children))
                } else {
                    loose.append(child)
                }
            }
            flushLoose()
        case "Page":
            model.pages = [page(root, children: root.children)]
        default:
            model.pages = [page(nil, children: [root])]
        }
        if model.pages.isEmpty { model.pages = [emptyPage()] }
        model.form = form
        return model
    }

    // MARK: Pages

    private func emptyPage() -> PageModel {
        page(nil, children: [])
    }

    private func page(_ element: ResolvedElement?, children: [ResolvedElement]) -> PageModel {
        pageNumbers = []
        var size = (element?.string("size")).flatMap { PaperSize(rawValue: $0.uppercased()) }?.size ?? PaperSize.a4.size
        if element?.string("orientation") == "landscape" { size = CGSize(width: size.height, height: size.width) }
        // Margins are non-negative and leave at least a third of the page for content.
        let maxVertical = size.height / 3, maxHorizontal = size.width / 3
        let margins = EdgeInsets(
            top: element?.number("marginTop", in: 0...maxVertical) ?? 40,
            left: element?.number("marginLeft", in: 0...maxHorizontal) ?? 40,
            bottom: element?.number("marginBottom", in: 0...maxVertical) ?? 40,
            right: element?.number("marginRight", in: 0...maxHorizontal) ?? 40
        )
        var root = LayoutNode(content: .container(children.flatMap(nodes)), breakBehavior: .flow, key: element?.key)
        root.style.alignItems = .stretch
        return PageModel(
            size: size,
            margins: margins,
            background: PDFColor(element?.string("backgroundColor")),
            content: root,
            pageNumbers: pageNumbers
        )
    }

    // MARK: Components

    /// Layout nodes for an element.
    private func nodes(_ element: ResolvedElement) -> [LayoutNode] {
        switch element.type {
        case "View": [view(element)]
        case "Row": [stack(element, direction: .row)]
        case "Column", "Page", "Document": [stack(element, direction: .column)]
        case "Heading": [heading(element)]
        case "Text": [text(element)]
        case "Link": [link(element)]
        case "Image": [image(element)]
        case "Table": [table(element)]
        case "List": [list(element)]
        case "Divider": [divider(element)]
        case "Spacer": [spacer(element)]
        case "PageNumber": pageNumber(element)
        case "FieldSet": [fieldSet(element)]
        case "TextInput", "Checkbox", "RadioGroup", "Select", "ListBox": [formField(element)]
        default: []
        }
    }

    func children(_ element: ResolvedElement) -> [LayoutNode] {
        element.children.flatMap(nodes)
    }

    private func view(_ element: ResolvedElement) -> LayoutNode {
        var style = BoxStyle()
        let padding = element.number("padding", in: Self.length) ?? 0
        style.padding = EdgeInsets(
            top: element.number("paddingTop", in: Self.length) ?? padding,
            left: element.number("paddingLeft", in: Self.length) ?? padding,
            bottom: element.number("paddingBottom", in: Self.length) ?? padding,
            right: element.number("paddingRight", in: Self.length) ?? padding
        )
        style.margin = EdgeInsets(all: element.number("margin", in: Self.length) ?? 0)
        style.background = PDFColor(element.string("backgroundColor"))
        style.border = EdgeInsets(all: element.number("borderWidth", in: Self.length) ?? 0)
        style.borderColor = PDFColor(element.string("borderColor")) ?? .black
        style.borderRadius = element.number("borderRadius", in: Self.length) ?? 0
        applyFlex(element, to: &style)
        return LayoutNode(style: style, content: .container(children(element)), breakBehavior: .keepTogetherIfSmall, key: element.key)
    }

    private func stack(_ element: ResolvedElement, direction: BoxStyle.Direction) -> LayoutNode {
        var style = BoxStyle()
        style.direction = direction
        style.gap = element.number("gap", in: Self.length) ?? 0
        style.padding = EdgeInsets(all: element.number("padding", in: Self.length) ?? 0)
        style.wrap = direction == .row && element.bool("wrap") == true
        applyFlex(element, to: &style)
        // Rows stay together; small columns move whole, taller ones flow across pages.
        let behavior: BreakBehavior = direction == .row ? .keepTogether : .keepTogetherIfSmall
        return LayoutNode(style: style, content: .container(children(element)), breakBehavior: behavior, key: element.key)
    }

    private func applyFlex(_ element: ResolvedElement, to style: inout BoxStyle) {
        style.flex = element.number("flex", in: 0...1_000) ?? 0
        switch element.string("alignItems") {
        case "flex-start": style.alignItems = .start
        case "center": style.alignItems = .center
        case "flex-end": style.alignItems = .end
        default: style.alignItems = .stretch
        }
        switch element.string("justifyContent") {
        case "center": style.justifyContent = .center
        case "flex-end": style.justifyContent = .end
        case "space-between": style.justifyContent = .spaceBetween
        case "space-around": style.justifyContent = .spaceAround
        default: style.justifyContent = .start
        }
    }

    private func heading(_ element: ResolvedElement) -> LayoutNode {
        let (size, marginBottom): (CGFloat, CGFloat) = switch element.string("level") {
        case "h1": (24, 8)
        case "h3": (16, 4)
        case "h4": (14, 4)
        default: (20, 6)
        }
        var text = TextStyle()
        text.fontSize = size
        text.bold = true
        text.color = PDFColor(element.string("color")) ?? .black
        text.alignment = alignment(element.string("align"))
        var node = textNode(element.string("text"), text, key: element.key)
        node.style.margin.bottom = marginBottom
        return node
    }

    private func text(_ element: ResolvedElement) -> LayoutNode {
        var text = TextStyle()
        text.fontSize = element.number("fontSize", in: Self.fontSize) ?? 12
        text.color = PDFColor(element.string("color")) ?? .black
        text.alignment = alignment(element.string("align"))
        text.bold = element.string("fontWeight") == "bold"
        text.italic = element.string("fontStyle") == "italic"
        text.lineHeight = element.number("lineHeight", in: 0.1...20)
        return textNode(element.string("text"), text, key: element.key)
    }

    private func link(_ element: ResolvedElement) -> LayoutNode {
        var text = TextStyle()
        text.fontSize = element.number("fontSize", in: Self.fontSize) ?? 12
        text.color = PDFColor(element.string("color")) ?? PDFColor("#2563eb")!
        text.underline = true
        var node = textNode(element.string("text"), text, key: element.key)
        node.link = element.string("href").flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
        return node
    }

    func textNode(_ string: String?, _ style: TextStyle, key: String?) -> LayoutNode {
        LayoutNode(content: .text(EmojiStripper.strip(string ?? ""), style), key: key)
    }

    func alignment(_ value: String?) -> TextStyle.Alignment {
        switch value {
        case "center": .center
        case "right": .right
        default: .left
        }
    }

    private func image(_ element: ResolvedElement) -> LayoutNode {
        let source = element.string("src") ?? ""
        let loaded = images[source]
        var content = ImageContent(source: source, data: loaded?.data, pixelSize: loaded?.pixelSize)
        content.maxDrawDimension = loaded?.maxDrawDimension ?? content.maxDrawDimension
        content.fit = element.string("objectFit").flatMap(ImageContent.Fit.init(rawValue:)) ?? .contain
        var style = BoxStyle()
        style.width = element.number("width", in: Self.length).map { .points($0) }
        style.height = element.number("height", in: Self.length)
        return LayoutNode(style: style, content: .image(content), key: element.key)
    }

    private func table(_ element: ResolvedElement) -> LayoutNode {
        struct Column {
            var header: String
            var width: BoxStyle.Width
            var align: TextStyle.Alignment
        }
        let rawColumns = element.props["columns"]?.arrayValue ?? []
        let defaultWidth = BoxStyle.Width.fraction(rawColumns.isEmpty ? 1 : 1 / CGFloat(rawColumns.count))
        let columns = rawColumns.map { column in
            Column(
                header: column["header"].map(Self.cellString) ?? "",
                width: column["width"].flatMap(Self.parseWidth) ?? defaultWidth,
                align: alignment(column["align"]?.stringValue)
            )
        }
        let borderColor = PDFColor(element.string("borderColor")) ?? PDFColor("#e5e7eb")!
        let fontSize = element.number("fontSize", in: Self.fontSize) ?? 10
        let striped = element.bool("striped") == true

        func row(_ cells: [String], header: Bool, index: Int) -> LayoutNode {
            var style = BoxStyle()
            style.direction = .row
            style.border.bottom = 1
            style.borderColor = borderColor
            if header {
                style.background = PDFColor(element.string("headerBackgroundColor")) ?? PDFColor("#f3f4f6")!
            } else if striped && index % 2 == 1 {
                style.background = PDFColor("#f9fafb")
            }
            let cellNodes = columns.enumerated().map { offset, column -> LayoutNode in
                var text = TextStyle()
                text.fontSize = fontSize
                text.bold = header
                text.alignment = column.align
                if header { text.color = PDFColor(element.string("headerTextColor")) ?? PDFColor("#111827")! }
                var cell = BoxStyle()
                cell.padding = EdgeInsets(all: 6)
                cell.width = column.width
                let content = textNode(offset < cells.count ? cells[offset] : "", text, key: nil)
                return LayoutNode(style: cell, content: .container([content]))
            }
            return LayoutNode(style: style, content: .container(cellNodes), key: header ? "\(element.key)#header" : "\(element.key)#row\(index)")
        }

        let rows = (element.props["rows"]?.arrayValue ?? []).map { ($0.arrayValue ?? []).map(Self.cellString) }
        var style = BoxStyle()
        style.width = .fraction(1)
        let content = [row(columns.map(\.header), header: true, index: -1)]
            + rows.enumerated().map { row($1, header: false, index: $0) }
        return LayoutNode(style: style, content: .container(content), breakBehavior: .table, key: element.key)
    }

    private static func cellString(_ value: JSONValue) -> String {
        value == .null ? "" : (value.stringValue ?? value.javaScriptString)
    }

    /// `"45%"` → 45 % of the table; a bare number → points.
    private static func parseWidth(_ value: JSONValue) -> BoxStyle.Width? {
        func points(_ value: Double?) -> BoxStyle.Width? {
            guard let value, value.isFinite, value >= 0 else { return nil }
            return .points(min(CGFloat(value), length.upperBound))
        }
        if let number = value.doubleValue { return points(number) }
        guard let text = value.stringValue?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasSuffix("%") {
            guard let percent = Double(text.dropLast()), percent.isFinite, percent >= 0 else { return nil }
            return .fraction(min(CGFloat(percent) / 100, 1))
        }
        return points(Double(text.hasSuffix("pt") ? String(text.dropLast(2)) : text))
    }

    private func list(_ element: ResolvedElement) -> LayoutNode {
        let fontSize = element.number("fontSize", in: Self.fontSize) ?? 12
        let ordered = element.bool("ordered") == true
        let color = PDFColor(element.string("color")) ?? .black
        let items = (element.props["items"]?.arrayValue ?? []).map(Self.cellString)
        let rows = items.enumerated().map { index, item -> LayoutNode in
            var text = TextStyle()
            text.fontSize = fontSize
            text.color = color
            var marker = textNode(ordered ? "\(index + 1)." : "\u{2022}", text, key: nil)
            marker.style.width = .points(ordered ? 20 : 12)
            var body = textNode(item, text, key: nil)
            body.style.flex = 1
            var row = BoxStyle()
            row.direction = .row
            row.gap = 6
            return LayoutNode(style: row, content: .container([marker, body]))
        }
        var style = BoxStyle()
        style.gap = element.number("spacing", in: Self.length) ?? 4
        return LayoutNode(style: style, content: .container(rows), breakBehavior: .keepTogetherIfSmall, key: element.key)
    }

    private func divider(_ element: ResolvedElement) -> LayoutNode {
        var style = BoxStyle()
        style.border.bottom = element.number("thickness", in: Self.length) ?? 1
        style.borderColor = PDFColor(element.string("color")) ?? PDFColor("#e5e7eb")!
        style.margin = EdgeInsets(top: element.number("marginTop", in: Self.length) ?? 8, bottom: element.number("marginBottom", in: Self.length) ?? 8)
        return LayoutNode(style: style, content: .empty, key: element.key)
    }

    private func spacer(_ element: ResolvedElement) -> LayoutNode {
        var style = BoxStyle()
        style.height = element.number("height", in: Self.length) ?? 20
        return LayoutNode(style: style, content: .empty, key: element.key)
    }

    /// Records the page's footer; contributes nothing to the flow.
    private func pageNumber(_ element: ResolvedElement) -> [LayoutNode] {
        var text = TextStyle()
        text.fontSize = element.number("fontSize", in: Self.fontSize) ?? 10
        text.color = PDFColor(element.string("color")) ?? PDFColor("#6b7280")!
        text.alignment = element.string("align").map(alignment) ?? .center
        pageNumbers.append(PageNumberSpec(format: element.string("format") ?? "{pageNumber} / {totalPages}", style: text))
        return []
    }
}

private extension String {
    /// JavaScript `String.prototype.replace` with a string pattern (first occurrence).
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let range = range(of: target) else { return self }
        return replacingCharacters(in: range, with: replacement)
    }
}
