import CoreGraphics
import Foundation

/// An sRGB color parsed from a spec color string: `#rgb`, `#rgba`, `#rrggbb`,
/// `#rrggbbaa`, `rgb(…)` / `rgba(…)`, `transparent` or a basic CSS color name.
struct PDFColor: Sendable, Hashable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1

    static let black = PDFColor(red: 0, green: 0, blue: 0)

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// `nil` for unparseable strings (the property then falls back to its default).
    init?(_ string: String?) {
        guard let raw = string?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        if raw.hasPrefix("#") {
            guard let color = Self.hex(String(raw.dropFirst())) else { return nil }
            self = color
        } else if raw.hasPrefix("rgb") {
            guard let color = Self.functional(raw) else { return nil }
            self = color
        } else if let named = Self.named[raw] {
            self = named
        } else {
            return nil
        }
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    private static func hex(_ digits: String) -> PDFColor? {
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        let expanded: String
        switch digits.count {
        case 3, 4: expanded = digits.map { "\($0)\($0)" }.joined()
        case 6, 8: expanded = digits
        default: return nil
        }
        let bytes = stride(from: 0, to: expanded.count, by: 2).map { offset -> CGFloat in
            let start = expanded.index(expanded.startIndex, offsetBy: offset)
            return CGFloat(UInt8(expanded[start..<expanded.index(start, offsetBy: 2)], radix: 16) ?? 0) / 255
        }
        return PDFColor(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes.count == 4 ? bytes[3] : 1)
    }

    private static func functional(_ string: String) -> PDFColor? {
        guard let open = string.firstIndex(of: "("), let close = string.lastIndex(of: ")"), open < close else { return nil }
        let parts = string[string.index(after: open)..<close]
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        func channel(_ text: String) -> CGFloat? {
            if text.hasSuffix("%") { return Double(text.dropLast()).map { CGFloat($0) / 100 } }
            return Double(text).map { CGFloat($0) / 255 }
        }
        guard let r = channel(parts[0]), let g = channel(parts[1]), let b = channel(parts[2]) else { return nil }
        var alpha: CGFloat = 1
        if parts.count > 3 {
            let text = parts[3]
            alpha = text.hasSuffix("%") ? CGFloat(Double(text.dropLast()) ?? 100) / 100 : CGFloat(Double(text) ?? 1)
        }
        return PDFColor(red: r, green: g, blue: b, alpha: alpha)
    }

    private static let named: [String: PDFColor] = [
        "transparent": PDFColor(red: 0, green: 0, blue: 0, alpha: 0),
        "black": .black,
        "white": PDFColor(red: 1, green: 1, blue: 1),
        "gray": PDFColor(red: 0.5, green: 0.5, blue: 0.5),
        "grey": PDFColor(red: 0.5, green: 0.5, blue: 0.5),
        "lightgray": PDFColor(red: 0.827, green: 0.827, blue: 0.827),
        "darkgray": PDFColor(red: 0.663, green: 0.663, blue: 0.663),
        "red": PDFColor(red: 1, green: 0, blue: 0),
        "green": PDFColor(red: 0, green: 0.502, blue: 0),
        "blue": PDFColor(red: 0, green: 0, blue: 1),
        "navy": PDFColor(red: 0, green: 0, blue: 0.502),
        "orange": PDFColor(red: 1, green: 0.647, blue: 0),
        "yellow": PDFColor(red: 1, green: 1, blue: 0),
        "purple": PDFColor(red: 0.502, green: 0, blue: 0.502),
        "teal": PDFColor(red: 0, green: 0.502, blue: 0.502),
    ]
}
