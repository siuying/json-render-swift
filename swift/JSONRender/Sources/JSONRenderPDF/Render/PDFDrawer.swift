import CoreGraphics
import CoreText
import Foundation

/// One physical page: the fragment of a `Page` element's flow placed on it.
struct PhysicalPage {
    var page: PageModel
    var content: LaidBox
}

/// What was drawn where (page coordinates, top-left origin); used by tests and QA.
struct DrawnItem: Sendable {
    /// Charts record their plot area (`chart`), one `chartBar` per bar or one `chartPoint`
    /// per line or area point (`text` is the point's label), an area's fill (`chartArea`), and
    /// their axis labels as `text`. Pies record their circle (`chart`) and one `chartSlice`
    /// per slice (its bounding box, `text` the slice's name); legend swatches are `box`es.
    enum Kind: Sendable, Equatable {
        case box, text, image, imagePlaceholder, link, pageNumber, formWidget, chart, chartBar, chartPoint, chartArea,
             chartSlice
    }
    var kind: Kind
    var rect: CGRect
    var text: String?
    var key: String?
    var url: URL?
}

struct DrawnPage: Sendable {
    var size: CGSize
    var items: [DrawnItem]
}

/// Where a form widget landed: page index and rectangle in PDF space (bottom-left origin).
struct FormWidgetPlacement: Sendable, Hashable {
    var widget: FormWidgetRef
    var page: Int
    var rect: CGRect
}

/// Draws laid-out pages into a PDF context. Layout uses a top-left origin; the context
/// is flipped once per page, and link annotations are added in PDF space afterwards.
final class PDFDrawer {
    private let text: TextEngine
    private var items: [DrawnItem] = []
    private var links: [(URL, CGRect)] = []
    private var images: [String: CGImage] = [:]
    private var pageIndex = 0
    private var totalPages = 0
    private var pageHeight: CGFloat = 0
    private(set) var placements: [FormWidgetPlacement] = []
    private var placedWidgets: Set<FormWidgetRef> = []

    init(text: TextEngine) {
        self.text = text
    }

    func draw(_ pages: [PhysicalPage], document: DocumentModel) throws -> (Data, [DrawnPage]) {
        try Task.checkCancellation()
        let data = NSMutableData()
        var info: [CFString: Any] = [kCGPDFContextCreator: "json-render (JSONRenderPDF)"]
        if let title = document.title { info[kCGPDFContextTitle] = title }
        if let author = document.author { info[kCGPDFContextAuthor] = author }
        if let subject = document.subject { info[kCGPDFContextSubject] = subject }
        var defaultBox = CGRect(origin: .zero, size: pages.first?.page.size ?? PaperSize.a4.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &defaultBox, info as CFDictionary)
        else { throw PDFRenderError.contextUnavailable }

        totalPages = pages.count
        var report: [DrawnPage] = []
        for (index, physical) in pages.enumerated() {
            try Task.checkCancellation()
            items = []
            links = []
            pageIndex = index
            pageHeight = physical.page.size.height
            let size = physical.page.size
            var mediaBox = CGRect(origin: .zero, size: size)
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)] as CFDictionary
            context.beginPDFPage(pageInfo)
            context.saveGState()
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            if let background = physical.page.background {
                context.setFillColor(background.cgColor)
                context.fill(mediaBox)
            }
            let origin = physical.page.contentRect.origin
            drawBox(physical.content, origin: origin, in: context)
            drawFooter(physical.page, in: context)
            context.restoreGState()
            for (url, rect) in links {
                let pdfRect = CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
                context.setURL(url as CFURL, for: pdfRect)
            }
            context.endPDFPage()
            report.append(DrawnPage(size: size, items: items))
        }
        context.closePDF()
        return (data as Data, report)
    }

    // MARK: Boxes

    private func drawBox(_ box: LaidBox, origin: CGPoint, in context: CGContext) {
        let frame = box.frame.offsetBy(dx: origin.x, dy: origin.y)
        guard Self.isFinite(frame) else { return }
        let style = box.style
        if let background = style.background, background.alpha > 0 {
            context.setFillColor(background.cgColor)
            context.addPath(path(frame, radius: style.borderRadius))
            context.fillPath()
        }
        drawBorder(style, frame: frame, in: context)
        if style.background != nil || style.border != .zero {
            items.append(DrawnItem(kind: .box, rect: frame, key: box.key))
        }
        switch box.content {
        case .container(let children):
            for child in children { drawBox(child, origin: frame.origin, in: context) }
        case .text(let lines, let textStyle):
            let content = frame.inset(by: style.inset)
            drawLines(lines, style: textStyle, in: content, key: box.key, link: box.link, kind: .text, context: context)
        case .image(let image):
            drawImage(image, in: frame, key: box.key, context: context)
        case .formWidget(let widget):
            drawWidgetFrame(widget, in: frame, key: box.key, context: context)
        case .chart(let chart):
            drawChart(chart, in: frame.inset(by: style.inset), key: box.key, context: context)
        case .empty:
            break
        }
    }

    /// The static frame of a fillable widget (white fill, grey border; circles for radio
    /// buttons). The interactive field and its value are added by ``AcroFormWriter``.
    private func drawWidgetFrame(_ widget: FormWidgetRef, in frame: CGRect, key: String?, context: CGContext) {
        guard frame.width > 0, frame.height > 0, placedWidgets.insert(widget).inserted else { return }
        context.saveGState()
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.setStrokeColor(DocumentBuilder.fieldBorder.cgColor)
        context.setLineWidth(1)
        let inset = frame.insetBy(dx: 0.5, dy: 0.5)
        if widget.kind == .radioGroup {
            context.fillEllipse(in: frame)
            context.strokeEllipse(in: inset)
        } else {
            context.fill(frame)
            context.stroke(inset)
        }
        context.restoreGState()
        items.append(DrawnItem(kind: .formWidget, rect: frame, key: key))
        placements.append(FormWidgetPlacement(
            widget: widget, page: pageIndex,
            rect: CGRect(x: frame.minX, y: pageHeight - frame.maxY, width: frame.width, height: frame.height)
        ))
    }

    private func drawBorder(_ style: BoxStyle, frame: CGRect, in context: CGContext) {
        let border = style.border
        guard border != .zero else { return }
        context.setFillColor(style.borderColor.cgColor)
        context.setStrokeColor(style.borderColor.cgColor)
        if border.top == border.bottom, border.left == border.right, border.top == border.left {
            let width = border.top
            context.setLineWidth(width)
            context.addPath(path(frame.insetBy(dx: width / 2, dy: width / 2), radius: max(style.borderRadius - width / 2, 0)))
            context.strokePath()
            return
        }
        if border.top > 0 { context.fill(CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: border.top)) }
        if border.bottom > 0 {
            context.fill(CGRect(x: frame.minX, y: frame.maxY - border.bottom, width: frame.width, height: border.bottom))
        }
        if border.left > 0 { context.fill(CGRect(x: frame.minX, y: frame.minY, width: border.left, height: frame.height)) }
        if border.right > 0 {
            context.fill(CGRect(x: frame.maxX - border.right, y: frame.minY, width: border.right, height: frame.height))
        }
    }

    private func path(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let radius = min(max(radius, 0), min(rect.width, rect.height) / 2)
        return radius > 0
            ? CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            : CGPath(rect: rect, transform: nil)
    }

    // MARK: Text

    private func drawLines(
        _ lines: [TextLine], style: TextStyle, in content: CGRect, key: String?, link: URL?,
        kind: DrawnItem.Kind, context: CGContext
    ) {
        guard Self.isFinite(content), content.width > 0 else { return }
        // Text never paints outside its box (e.g. a glyph wider than a narrow column).
        let clip = content.insetBy(dx: -1, dy: -0.5)
        context.saveGState()
        context.clip(to: clip)
        defer { context.restoreGState() }
        for line in lines where content.minY + line.y < clip.maxY {
            let offset: CGFloat = switch style.alignment {
            case .left: 0
            case .center: (content.width - line.width) / 2
            case .right: content.width - line.width
            }
            let x = content.minX + max(offset, 0)
            let baseline = content.minY + line.y + line.baseline
            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: x, y: baseline)
            context.scaleBy(x: 1, y: -1)
            CTLineDraw(line.line, context)
            context.restoreGState()
            if style.underline {
                let thickness = max(style.fontSize * 0.05, 0.5)
                context.setFillColor(style.color.cgColor)
                context.fill(CGRect(x: x, y: baseline + style.fontSize * 0.1, width: line.width, height: thickness))
            }
            let rect = CGRect(x: x, y: content.minY + line.y, width: line.width, height: line.height).intersection(clip)
            items.append(DrawnItem(kind: kind, rect: rect, text: line.text, key: key, url: link))
            if let link {
                links.append((link, rect))
                items.append(DrawnItem(kind: .link, rect: rect, key: key, url: link))
            }
        }
    }

    /// Page numbers in the bottom margin: vertically centred in the (effective) bottom
    /// margin and aligned within the content area's width.
    private func drawFooter(_ page: PageModel, in context: CGContext) {
        for spec in page.pageNumbers {
            let rect = Self.footerRect(for: spec, on: page, text: text, page: pageIndex + 1, total: totalPages)
            let lines = text.lines(spec.text(page: pageIndex + 1, total: totalPages), spec.style, width: rect.width)
            drawLines(lines, style: spec.style, in: rect, key: nil, link: nil, kind: .pageNumber, context: context)
        }
    }

    static func footerRect(for spec: PageNumberSpec, on page: PageModel, text: TextEngine, page number: Int, total: Int) -> CGRect {
        let width = page.contentRect.width
        let lines = text.lines(spec.text(page: number, total: total), spec.style, width: width)
        let height = lines.last.map { $0.y + $0.height } ?? 0
        let margin = page.effectiveBottomMargin
        return CGRect(x: page.margins.left, y: page.size.height - margin + max((margin - height) / 2, 0), width: width, height: height)
    }

    // MARK: Charts

    private func drawChart(_ chart: ChartContent, in frame: CGRect, key: String?, context: CGContext) {
        guard Self.isFinite(frame), frame.width > 0, frame.height > 0 else { return }
        switch chart {
        case .series(let series): drawSeries(series, in: frame, key: key, context: context)
        case .pie(let pie): drawPie(pie, in: frame, key: key, context: context)
        }
    }

    /// Slices from 12 o'clock clockwise, colored in turn, with a 1 pt gap between them.
    private func drawPie(_ pie: PieContent, in frame: CGRect, key: String?, context: CGContext) {
        let geometry = PieGeometry(data: pie.data, frame: frame, donut: pie.donut)
        guard geometry.radius > 0 else { return }
        items.append(DrawnItem(kind: .chart, rect: geometry.bounds, key: key))
        for (index, slice) in pie.data.slices.enumerated() {
            let path = geometry.path(index)
            context.setFillColor((slice.isOther ? pie.otherColor ?? pie.colors[slice.id % pie.colors.count] : pie.colors[slice.id % pie.colors.count]).cgColor)
            context.addPath(path)
            context.fillPath()
            items.append(DrawnItem(kind: .chartSlice, rect: path.boundingBoxOfPath, text: slice.label, key: key))
            if let value = slice.formattedValue {
                let angle = (geometry.angles[index].start + geometry.angles[index].end) / 2
                let radius = (geometry.radius + geometry.innerRadius) / 2
                let center = CGPoint(x: geometry.center.x + cos(angle) * radius, y: geometry.center.y + sin(angle) * radius)
                var style = ChartGeometry.labelStyle
                style.alignment = .center
                let width = min(text.maxContentWidth(value, style), frame.width)
                let rect = CGRect(x: min(max(center.x - width / 2, frame.minX), frame.maxX - width), y: center.y - style.fontSize / 2, width: width, height: style.fontSize * 1.2)
                drawLines(text.lines(value, style, width: width), style: style, in: rect, key: key, link: nil, kind: .text, context: context)
            }
        }
    }

    /// Horizontal gridlines with value labels, then rounded bars, a monotone 2 pt line (no
    /// point markers) or that line over a translucent fill down to zero, then category labels
    /// under their bands.
    private func drawSeries(_ chart: SeriesChart, in frame: CGRect, key: String?, context: CGContext) {
        let geometry = ChartGeometry(data: chart.data, frame: frame, text: text, horizontal: chart.horizontal)
        let plot = geometry.plot
        let labelStyle = ChartGeometry.labelStyle
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: frame.insetBy(dx: -1, dy: -1))

        context.setStrokeColor(ChartGeometry.gridColor.cgColor)
        context.setLineWidth(0.5)
        for (value, label) in zip(geometry.ticks, geometry.tickLabels) {
            if chart.horizontal {
                let x = geometry.x(value)
                context.move(to: CGPoint(x: x, y: plot.minY))
                context.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.strokePath()
                var style = labelStyle
                style.alignment = .center
                let width = min(CGFloat(60), plot.width / CGFloat(max(geometry.ticks.count, 1)))
                let rect = CGRect(x: min(max(x - width / 2, frame.minX), frame.maxX - width), y: plot.maxY + ChartGeometry.labelGap, width: width, height: geometry.labelHeight)
                drawLines(text.lines(label, style, width: width), style: style, in: rect, key: key, link: nil, kind: .text, context: context)
                continue
            }
            let y = geometry.y(value)
            context.move(to: CGPoint(x: plot.minX, y: y))
            context.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.strokePath()
            var style = labelStyle
            style.alignment = .right
            let width = plot.minX - frame.minX - ChartGeometry.labelGap
            let rect = CGRect(x: frame.minX, y: y - geometry.labelHeight / 2, width: max(width, 0), height: geometry.labelHeight)
            drawLines(text.lines(label, style, width: .greatestFiniteMagnitude), style: style, in: rect, key: key, link: nil, kind: .text, context: context)
        }
        items.append(DrawnItem(kind: .chart, rect: plot, text: chart.data.valueKey, key: key))

        let points = chart.data.points
        context.setFillColor(chart.color.cgColor)
        context.setStrokeColor(chart.color.cgColor)
        switch chart.kind {
        case .bar:
            for (index, point) in points.enumerated() {
                guard !point.isMissing else { continue }
                context.setFillColor((point.isOther ? chart.otherColor ?? chart.color : chart.color).cgColor)
                let rect = geometry.bar(index, value: point.value)
                guard Self.isFinite(rect), rect.height > 0 else { continue }
                context.addPath(path(rect, radius: ChartGeometry.barRadius))
                context.fillPath()
                items.append(DrawnItem(kind: .chartBar, rect: rect, text: point.label, key: key))
            }
        case .line, .area:
            for points in chart.data.numericSegments {
            let positions = points.map { geometry.point($0.id, value: $0.value) }
            guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return }
            if chart.kind == .area, let first = positions.first, let last = positions.last {
                // The curve, then down to the zero line and back along it.
                let zero = geometry.y(0)
                let area = ChartGeometry.monotonePath(positions).mutableCopy() ?? CGMutablePath()
                area.addLine(to: CGPoint(x: last.x, y: zero))
                area.addLine(to: CGPoint(x: first.x, y: zero))
                area.closeSubpath()
                var fill = chart.color
                fill.alpha *= Self.areaOpacity
                context.setFillColor(fill.cgColor)
                context.addPath(area)
                context.fillPath()
                context.setFillColor(chart.color.cgColor)
                items.append(DrawnItem(kind: .chartArea, rect: area.boundingBoxOfPath, text: chart.data.valueKey, key: key))
            }
            if positions.count == 1 {
                context.fillEllipse(in: CGRect(x: positions[0].x - 2, y: positions[0].y - 2, width: 4, height: 4))
            } else {
                context.setLineWidth(2)
                context.setLineJoin(.round)
                context.setLineCap(.round)
                context.addPath(ChartGeometry.monotonePath(positions))
                context.strokePath()
            }
            for (point, position) in zip(points, positions) {
                let rect = CGRect(x: position.x - 1, y: position.y - 1, width: 2, height: 2)
                items.append(DrawnItem(kind: .chartPoint, rect: rect, text: point.label, key: key))
            }
            }
        }

        // Unknown values occupy their categorical band, with a neutral marker and n/a.
        // Formatted annotations are display-only and never enter a numeric scale.
        for point in points where point.isMissing || point.formattedValue != nil {
            let position: CGPoint
            if chart.horizontal {
                let bar = geometry.bar(point.id, value: point.value)
                position = CGPoint(x: geometry.x(point.value), y: bar.midY)
            } else { position = geometry.point(point.id, value: point.value) }
            if point.isMissing {
                let marker = CGRect(x: max(position.x - 2, plot.minX), y: position.y - 2, width: 4, height: 4)
                context.setFillColor(ChartGeometry.labelStyle.color.cgColor)
                context.fill(marker)
                items.append(DrawnItem(kind: .chartPoint, rect: marker, text: point.label, key: key))
            }
            var annotationStyle = labelStyle
            annotationStyle.alignment = .left
            let width = min(text.maxContentWidth(point.valueText, annotationStyle), plot.width)
            let x = min(max(position.x + 4, plot.minX), max(plot.maxX - width, plot.minX))
            let y = chart.horizontal ? position.y - geometry.labelHeight / 2 : max(position.y - geometry.labelHeight - 4, plot.minY)
            let rect = CGRect(x: x, y: y, width: width, height: geometry.labelHeight)
            drawLines(text.lines(point.valueText, annotationStyle, width: width), style: annotationStyle, in: rect, key: key, link: nil, kind: .text, context: context)
        }

        var style = labelStyle
        style.alignment = .center
        for (index, point) in points.enumerated() where index % geometry.labelStride == 0 {
            if chart.horizontal {
                let bar = geometry.bar(index, value: point.value)
                let width = max(plot.minX - frame.minX - ChartGeometry.labelGap, 0)
                var labelStyle = style
                labelStyle.alignment = .right
                let bandHeight = plot.height / CGFloat(max(points.count, 1))
                let lines = text.lines(point.label, labelStyle, width: width)
                let height = min(lines.reduce(0) { $0 + $1.height }, bandHeight)
                let rect = CGRect(x: frame.minX, y: bar.midY - height / 2, width: width, height: height)
                drawLines(lines, style: labelStyle, in: rect, key: key, link: nil, kind: .text, context: context)
                continue
            }
            let band = geometry.band(index)
            let width = band.width * CGFloat(geometry.labelStride)
            // Centred under the band, kept inside the chart's frame.
            let minX = max(band.midX - width / 2, frame.minX), maxX = min(band.midX + width / 2, frame.maxX)
            let rect = CGRect(x: minX, y: plot.maxY + ChartGeometry.labelGap, width: max(maxX - minX, 0), height: geometry.labelHeight)
            let lines = text.lines(point.label, style, width: .greatestFiniteMagnitude).prefix(1)
            drawLines(Array(lines), style: style, in: rect, key: key, link: nil, kind: .text, context: context)
        }
    }

    /// Opacity of an area chart's fill (the line on top is opaque).
    static let areaOpacity: CGFloat = 0.25

    // MARK: Images

    private func drawImage(_ image: ImageContent, in frame: CGRect, key: String?, context: CGContext) {
        guard let cgImage = decoded(image) else {
            drawPlaceholder(frame, in: context)
            items.append(DrawnItem(kind: .imagePlaceholder, rect: frame, text: image.source, key: key))
            return
        }
        let natural = CGSize(width: cgImage.width, height: cgImage.height)
        let destination = Self.fit(natural, into: frame, mode: image.fit)
        context.saveGState()
        context.clip(to: frame)
        context.translateBy(x: destination.minX, y: destination.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: destination.size))
        context.restoreGState()
        items.append(DrawnItem(kind: .image, rect: frame, text: image.source, key: key))
    }

    private func decoded(_ image: ImageContent) -> CGImage? {
        guard let data = image.data else { return nil }
        if let cached = images[image.source] { return cached }
        guard let loaded = LoadedImage(data: data, maxPixels: .max, maxDrawDimension: image.maxDrawDimension),
              let cgImage = loaded.makeImage() else { return nil }
        images[image.source] = cgImage
        return cgImage
    }

    /// Destination rect for `objectFit` (contain / cover / fill / none), centred.
    static func fit(_ natural: CGSize, into frame: CGRect, mode: ImageContent.Fit) -> CGRect {
        guard natural.width > 0, natural.height > 0 else { return frame }
        let size: CGSize
        switch mode {
        case .fill:
            return frame
        case .none:
            size = natural
        case .contain, .cover:
            let scaleX = frame.width / natural.width
            let scaleY = frame.height / natural.height
            let scale = mode == .contain ? min(scaleX, scaleY) : max(scaleX, scaleY)
            size = CGSize(width: natural.width * scale, height: natural.height * scale)
        }
        return CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
    }

    /// Neutral grey box with a thin frame and a diagonal cross.
    private func drawPlaceholder(_ frame: CGRect, in context: CGContext) {
        context.saveGState()
        context.setFillColor(PDFColor("#f3f4f6")!.cgColor)
        context.fill(frame)
        context.setStrokeColor(PDFColor("#d1d5db")!.cgColor)
        context.setLineWidth(1)
        context.stroke(frame.insetBy(dx: 0.5, dy: 0.5))
        context.move(to: CGPoint(x: frame.minX, y: frame.minY))
        context.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
        context.move(to: CGPoint(x: frame.maxX, y: frame.minY))
        context.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
        context.strokePath()
        context.restoreGState()
    }
}

private extension CGRect {
    func inset(by insets: EdgeInsets) -> CGRect {
        CGRect(
            x: minX + insets.left, y: minY + insets.top,
            width: max(width - insets.horizontal, 0), height: max(height - insets.vertical, 0)
        )
    }
}

/// Errors from ``PDFRenderer``.
public enum PDFRenderError: Error, Sendable {
    /// Core Graphics could not create a PDF context.
    case contextUnavailable
}
