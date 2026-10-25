import CoreGraphics
import CoreText
import Foundation

/// One laid-out line of a text block.
struct TextLine {
    var line: CTLine
    /// Top of the line box, relative to the text block's content top.
    var y: CGFloat
    var height: CGFloat
    /// Baseline offset from the top of the line box.
    var baseline: CGFloat
    /// Advance width without trailing whitespace (used for alignment and links).
    var width: CGFloat
    /// The characters of the line (with a trailing "-" when hyphenated).
    var text: String
}

/// Text measurement, line breaking and line construction matching react-pdf.
///
/// - Metrics follow react-pdf's standard-font model: `StandardFont` reports ascent 900
///   and descent −200, so a line box is `1.1 × size` (or `lineHeight × size`) with the
///   baseline `0.9 × size` below its top and any extra leading below.
/// - Advances and pair kerning are the Adobe AFM values pdfkit uses. They are applied to
///   Core Text's Helvetica glyphs as per-character kerning, so drawing lands exactly
///   where the measurement says.
/// - Line breaking is textkit's: paragraphs end after each newline, words are split into
///   en-US hyphenation syllables and broken with Knuth & Plass (``LineBreaker``); lines
///   that still overflow have their spaces shrunk.
final class TextEngine {
    private static let ascent: CGFloat = 0.9
    private static let naturalLineHeight: CGFloat = 1.1

    private var fonts: [String: CTFont] = [:]

    private static func fontName(_ style: TextStyle) -> String {
        switch (style.bold, style.italic) {
        case (true, true): "Helvetica-BoldOblique"
        case (true, false): "Helvetica-Bold"
        case (false, true): "Helvetica-Oblique"
        case (false, false): "Helvetica"
        }
    }

    func font(_ style: TextStyle) -> CTFont {
        let name = Self.fontName(style)
        let key = "\(name)@\(style.fontSize)"
        if let font = fonts[key] { return font }
        let font = CTFontCreateWithName(name as CFString, max(style.fontSize, 0.1), nil)
        fonts[key] = font
        return font
    }

    func lineBox(_ style: TextStyle) -> (height: CGFloat, baseline: CGFloat) {
        let size = style.fontSize
        return ((style.lineHeight ?? Self.naturalLineHeight) * size, Self.ascent * size)
    }

    // MARK: Attributed strings

    func attributedString(_ text: String, _ style: TextStyle) -> NSMutableAttributedString {
        let ctFont = font(style)
        let string = NSMutableAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color.cgColor,
        ])
        let key = NSAttributedString.Key(kCTKernAttributeName as String)
        let (afm, coreText) = advances(text, style)
        var offset = 0
        for scalar in text.unicodeScalars {
            let length = scalar.utf16.count
            // Kern so Core Text's advance equals the AFM advance (incl. pair kerning).
            let kern = afm[offset].map { $0 - coreText[offset] } ?? 0
            string.addAttribute(key, value: kern, range: NSRange(location: offset, length: length))
            offset += length
        }
        return string
    }

    /// Per-UTF-16-unit advances (set on a scalar's first unit): the AFM width plus pair
    /// kerning with the next character (`nil` outside the AFM), and Core Text's advance.
    private func advances(_ text: String, _ style: TextStyle) -> (afm: [CGFloat?], coreText: [CGFloat]) {
        let units = Array(text.utf16)
        var afm = [CGFloat?](repeating: nil, count: units.count)
        var coreText = [CGFloat](repeating: 0, count: units.count)
        guard !units.isEmpty else { return (afm, coreText) }
        let ctFont = font(style)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        CTFontGetGlyphsForCharacters(ctFont, units, &glyphs, units.count)
        var sizes = [CGSize](repeating: .zero, count: units.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &sizes, units.count)
        coreText = sizes.map(\.width)
        let metrics = HelveticaMetrics.shared?.fonts[Self.fontName(style)]
        let scalars = Array(text.unicodeScalars)
        let scale = style.fontSize / 1000
        var offset = 0
        for (index, scalar) in scalars.enumerated() {
            if scalar == "\n" || scalar == "\r" {
                afm[offset] = 0
            } else if let width = metrics?.width(scalar) {
                let pair = index + 1 < scalars.count ? metrics?.kern(scalar, scalars[index + 1]) ?? 0 : 0
                afm[offset] = CGFloat(width + pair) * scale
            }
            offset += scalar.utf16.count
        }
        return (afm, coreText)
    }

    /// Layout advances per UTF-16 unit (AFM where known, else Core Text).
    private func layoutAdvances(_ text: String, _ style: TextStyle) -> [CGFloat] {
        let (afm, coreText) = advances(text, style)
        return zip(afm, coreText).map { $0 ?? $1 }
    }

    private func width(_ text: String, _ style: TextStyle) -> CGFloat {
        layoutAdvances(text, style).reduce(0, +)
    }

    // MARK: Line breaking

    /// Breaks `text` into lines at most `width` wide.
    func lines(_ text: String, _ style: TextStyle, width: CGFloat) -> [TextLine] {
        // No room for any glyph: draw nothing rather than overflow the box.
        guard !text.isEmpty, width.isFinite, width >= 0.5 else { return [] }
        let (lineHeight, baseline) = lineBox(style)
        let lineWidth = width
        var lines: [TextLine] = []
        for paragraph in Self.paragraphs(text) {
            // A hair of tolerance so text measured at its max-content width never wraps.
            for (display, measured) in breakParagraph(paragraph, style, width: lineWidth + 0.01) {
                let (line, drawnWidth) = makeLine(display, style, maxWidth: lineWidth, measured: measured)
                lines.append(TextLine(
                    line: line, y: CGFloat(lines.count) * lineHeight, height: lineHeight,
                    baseline: baseline, width: drawnWidth, text: display
                ))
            }
        }
        return lines
    }

    /// Widest hard-broken line (max-content width).
    func maxContentWidth(_ text: String, _ style: TextStyle) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return Self.paragraphs(text).map { paragraph in
            width(String(paragraph.reversed().drop(while: Self.isTrailingSpace).reversed()), style)
        }.max() ?? 0
    }

    /// textkit `splitParagraphs`: break after every newline (it stays with its paragraph).
    static func paragraphs(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character.isNewline {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty || result.isEmpty { result.append(current) }
        return result
    }

    private static func isTrailingSpace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character.isNewline
    }

    /// Lines of one paragraph as (display text, AFM width before any space shrinking).
    private func breakParagraph(_ paragraph: String, _ style: TextStyle, width: CGFloat) -> [(String, CGFloat)] {
        let units = Array(paragraph.utf16)
        let advances = layoutAdvances(paragraph, style)
        var prefix = [CGFloat](repeating: 0, count: units.count + 1)
        for index in units.indices { prefix[index + 1] = prefix[index] + advances[index] }
        let advance: (Int, Int) -> CGFloat = { prefix[$1] - prefix[$0] }

        let nodes = LineBreaker.nodes(syllables: syllables(paragraph, hyphenate: style.hyphenate, advance: advance, width: width), width: advance)
        let breaks = LineBreaker.breaks(nodes, lineWidth: width)

        var result: [(String, CGFloat)] = []
        var start = 0
        func emit(_ end: Int, hyphenated: Bool) {
            var trimmed = end
            while trimmed > start, [0x20, 0x09, 0x0A, 0x0D].contains(units[trimmed - 1]) { trimmed -= 1 }
            let body = String(decoding: units[start..<trimmed], as: UTF16.self)
            let display = hyphenated ? body + "-" : body
            result.append((display, advance(start, trimmed) + (hyphenated ? self.width("-", style) : 0)))
            start = end
        }
        for index in breaks where index != nodes.count - 1 {
            if case .penalty = nodes[index], index > 0 {
                emit(nodes[index - 1].end, hyphenated: true)
            } else {
                emit(nodes[index].end, hyphenated: false)
            }
        }
        emit(units.count, hyphenated: false)
        return result
    }

    /// textkit `wrapWords`: tokens split on runs of spaces (kept as glue tokens), words
    /// split into hyphenation syllables. A syllable wider than the line is cut into
    /// fitting pieces so text never overflows its box (react-pdf would overflow).
    private func syllables(_ paragraph: String, hyphenate: Bool, advance: (Int, Int) -> CGFloat, width: CGFloat) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in paragraph {
            if let last = current.last, (last == " ") != (character == " ") {
                tokens.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }

        var result: [String] = []
        var offset = 0
        for token in tokens {
            let parts = token.first == " " || !hyphenate ? [token] : (Hyphenator.enUS?.syllables(token) ?? [token])
            for part in parts {
                let length = part.utf16.count
                if advance(offset, offset + length) > width, part.count > 1 {
                    result += splitToFit(part, start: offset, advance: advance, width: width)
                } else {
                    result.append(part)
                }
                offset += length
            }
        }
        return result
    }

    private func splitToFit(_ part: String, start: Int, advance: (Int, Int) -> CGFloat, width: CGFloat) -> [String] {
        var pieces: [String] = []
        var piece = ""
        var pieceStart = start
        var offset = start
        for character in part {
            let length = character.utf16.count
            if !piece.isEmpty, advance(pieceStart, offset + length) + LineBreaker.hyphenWidth > width {
                pieces.append(piece)
                piece = ""
                pieceStart = offset
            }
            piece.append(character)
            offset += length
        }
        if !piece.isEmpty { pieces.append(piece) }
        return pieces
    }

    /// A drawable line. An overflowing line (Knuth & Plass may pick a line up to its
    /// shrink limit) has its spaces narrowed evenly to fit, like textkit's justification.
    private func makeLine(_ display: String, _ style: TextStyle, maxWidth: CGFloat, measured: CGFloat) -> (CTLine, CGFloat) {
        let attributed = attributedString(display, style)
        let overflow = measured - maxWidth
        let spaces = display.utf16.enumerated().filter { $0.element == 0x20 }.map(\.offset)
        if overflow > 0.01, !spaces.isEmpty {
            let key = NSAttributedString.Key(kCTKernAttributeName as String)
            let delta = overflow / CGFloat(spaces.count)
            for offset in spaces {
                let current = attributed.attribute(key, at: offset, effectiveRange: nil) as? CGFloat ?? 0
                attributed.addAttribute(key, value: current - delta, range: NSRange(location: offset, length: 1))
            }
        }
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
        return (line, max(width, 0))
    }
}
