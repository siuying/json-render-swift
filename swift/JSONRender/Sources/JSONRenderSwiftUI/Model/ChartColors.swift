import Foundation

/// Chart colors shared by the SwiftUI and PDF renderers: hex parsing and the default palette.
public enum ChartColors {
    /// The default palette, used in order (and cycled) for pie slices: blue, green, amber,
    /// red, violet.
    public static let palette = ["#2563eb", "#16a34a", "#f59e0b", "#dc2626", "#7c3aed"]

    /// The sRGB components (0...1) of `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
    public static func rgba(_ string: String?) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
        guard var digits = string?.trimmingCharacters(in: .whitespaces), digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let parsed = UInt64(digits, radix: 16) else { return nil }
        let value = digits.count == 6 ? parsed << 8 | 0xff : parsed
        return (
            Double(value >> 24 & 0xff) / 255, Double(value >> 16 & 0xff) / 255,
            Double(value >> 8 & 0xff) / 255, Double(value & 0xff) / 255
        )
    }

    /// The hex strings of a `colors` prop that parse, or ``palette`` when none do.
    public static func list(_ value: JSONValue?) -> [String] {
        let colors = (value?.arrayValue ?? []).compactMap(\.stringValue).filter { rgba($0) != nil }
        return colors.isEmpty ? palette : colors
    }
}
