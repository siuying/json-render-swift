import Foundation

/// JavaScript value semantics needed to match `@json-render/core` exactly.
/// `nil` stands for JavaScript `undefined`.
enum JS {
    /// `Boolean(value)`.
    static func isTruthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null: false
        case .bool(let bool): bool
        case .number(let number): number != 0 && !number.isNaN
        case .string(let string): !string.isEmpty
        case .array, .object: true
        }
    }

    /// `a === b`. Strings compare by UTF-16 code units. Arrays and objects compare by
    /// reference in JavaScript: pass `sameReference: true` when both operands were read
    /// from the same state location (core would see one object); otherwise containers
    /// are distinct and never equal.
    static func strictEquals(_ lhs: JSONValue?, _ rhs: JSONValue?, sameReference: Bool = false) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil), (.null?, .null?): true
        case (.bool(let a)?, .bool(let b)?): a == b
        case (.number(let a)?, .number(let b)?): a == b
        case (.string(let a)?, .string(let b)?): a.utf16.elementsEqual(b.utf16)
        case (.array?, .array?), (.object?, .object?): sameReference
        default: false
        }
    }

    /// `String(value)`.
    static func toString(_ value: JSONValue?) -> String {
        switch value {
        case nil: "undefined"
        case .null: "null"
        case .bool(let bool): bool ? "true" : "false"
        case .number(let number): numberToString(number)
        case .string(let string): string
        case .array(let items): items.map(arrayElementString).joined(separator: ",")
        case .object: "[object Object]"
        }
    }

    private static func arrayElementString(_ value: JSONValue) -> String {
        value == .null ? "" : toString(value)
    }

    /// `Number(value)` (the abstract ToNumber operation).
    static func toNumber(_ value: JSONValue?) -> Double {
        switch value {
        case nil: .nan
        case .null: 0
        case .bool(let bool): bool ? 1 : 0
        case .number(let number): number
        case .string(let string): stringToNumber(string)
        case .array, .object: stringToNumber(toString(value))
        }
    }

    static func typeofNumber(_ value: JSONValue?) -> Double? {
        if case .number(let number)? = value { return number }
        return nil
    }

    // MARK: Strings

    /// Characters removed by `String.prototype.trim` (WhiteSpace + LineTerminator).
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            true
        default:
            false
        }
    }

    /// `String.prototype.trim`.
    static func trim(_ string: String) -> String {
        let scalars = string.unicodeScalars
        guard let start = scalars.firstIndex(where: { !isWhitespace($0) }),
              let end = scalars.lastIndex(where: { !isWhitespace($0) }) else { return "" }
        return String(scalars[start...end])
    }

    /// `string.length` (UTF-16 code units).
    static func length(_ string: String) -> Int { string.utf16.count }

    /// `a < b` for strings (UTF-16 code unit order).
    static func lessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.lexicographicallyPrecedes(rhs.utf16)
    }

    // MARK: Numbers

    /// `parseInt(string, 10)`; `nil` when the result is `NaN`.
    static func parseInt(_ string: String) -> Int? {
        var scalars = Substring(trim(string)).unicodeScalars[...]
        var negative = false
        if let first = scalars.first, first == "+" || first == "-" {
            negative = first == "-"
            scalars = scalars.dropFirst()
        }
        let digits = scalars.prefix { ("0"..."9").contains($0) }
        guard !digits.isEmpty else { return nil }
        let magnitude = digits.reduce(0) { partial, digit in
            partial.multipliedReportingOverflow(by: 10).partialValue
                .addingReportingOverflow(Int(digit.value - 48)).partialValue
        }
        return negative ? -magnitude : magnitude
    }

    /// `parseFloat(string)`: the longest decimal-literal prefix after leading whitespace;
    /// `nil` when the result is `NaN`.
    static func parseFloat(_ string: String) -> Double? {
        let text = trim(string)
        for (prefix, value) in [("Infinity", Double.infinity), ("+Infinity", .infinity), ("-Infinity", -.infinity)]
        where text.hasPrefix(prefix) {
            return value
        }
        let chars = Array(text.utf8)
        func isDigit(_ index: Int) -> Bool { index < chars.count && chars[index] >= 48 && chars[index] <= 57 }
        var end = 0
        if end < chars.count, chars[end] == UInt8(ascii: "+") || chars[end] == UInt8(ascii: "-") { end += 1 }
        var mantissaDigits = 0
        while isDigit(end) { end += 1; mantissaDigits += 1 }
        if end < chars.count, chars[end] == UInt8(ascii: ".") {
            end += 1
            while isDigit(end) { end += 1; mantissaDigits += 1 }
        }
        guard mantissaDigits > 0 else { return nil }
        if end < chars.count, chars[end] == UInt8(ascii: "e") || chars[end] == UInt8(ascii: "E") {
            var exponentEnd = end + 1
            if exponentEnd < chars.count, chars[exponentEnd] == UInt8(ascii: "+") || chars[exponentEnd] == UInt8(ascii: "-") {
                exponentEnd += 1
            }
            if isDigit(exponentEnd) {
                while isDigit(exponentEnd) { exponentEnd += 1 }
                end = exponentEnd
            }
        }
        return Double(String(decoding: chars[..<end], as: UTF8.self))
    }

    /// StringToNumber: the conversion `Number("...")` performs.
    static func stringToNumber(_ string: String) -> Double {
        let text = trim(string)
        if text.isEmpty { return 0 }
        switch text {
        case "Infinity", "+Infinity": return .infinity
        case "-Infinity": return -.infinity
        default: break
        }
        let lower = text.lowercased()
        for (prefix, radix) in [("0x", 16.0), ("0o", 8.0), ("0b", 2.0)] where lower.hasPrefix(prefix) {
            let body = lower.dropFirst(2)
            guard !body.isEmpty else { return .nan }
            var result = 0.0
            for character in body {
                guard let digit = character.hexDigitValue, Double(digit) < radix else { return .nan }
                result = result * radix + Double(digit)
            }
            return result
        }
        guard isDecimalLiteral(text), let value = Double(text) else { return .nan }
        return value
    }

    /// `[+-]? (digits [. digits?] | . digits) ([eE] [+-]? digits)?`
    private static func isDecimalLiteral(_ text: String) -> Bool {
        var chars = Array(text.utf8)[...]
        func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
        func consumeDigits() -> Int {
            let count = chars.prefix(while: isDigit).count
            chars = chars.dropFirst(count)
            return count
        }
        if let first = chars.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
            chars = chars.dropFirst()
        }
        var mantissaDigits = consumeDigits()
        if chars.first == UInt8(ascii: ".") {
            chars = chars.dropFirst()
            mantissaDigits += consumeDigits()
        }
        guard mantissaDigits > 0 else { return false }
        if let first = chars.first, first == UInt8(ascii: "e") || first == UInt8(ascii: "E") {
            chars = chars.dropFirst()
            if let sign = chars.first, sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                chars = chars.dropFirst()
            }
            guard consumeDigits() > 0 else { return false }
        }
        return chars.isEmpty
    }

    /// `Number.prototype.toString()` (ECMA-262 Number::toString, radix 10).
    static func numberToString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value == 0 { return "0" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let sign = value < 0 ? "-" : ""
        let (digits, n) = shortestDigits(abs(value))
        let k = digits.count
        let body: String
        if k <= n && n <= 21 {
            body = digits + String(repeating: "0", count: n - k)
        } else if 0 < n && n <= 21 {
            body = String(digits.prefix(n)) + "." + String(digits.dropFirst(n))
        } else if -6 < n && n <= 0 {
            body = "0." + String(repeating: "0", count: -n) + digits
        } else {
            let exponent = n - 1
            let mantissa = k == 1 ? digits : String(digits.prefix(1)) + "." + String(digits.dropFirst(1))
            body = mantissa + "e" + (exponent < 0 ? "-" : "+") + String(abs(exponent))
        }
        return sign + body
    }

    /// Shortest round-trip decimal digits `d1…dk` and exponent `n` with
    /// `value = 0.d1…dk × 10^n`, derived from Swift's shortest-representation output.
    private static func shortestDigits(_ value: Double) -> (digits: String, exponent: Int) {
        let description = value.description
        let parts = description.split(separator: "e", maxSplits: 1)
        let mantissa = parts[0]
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let pieces = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerPart = String(pieces[0])
        let fractionPart = pieces.count > 1 ? String(pieces[1]) : ""
        var digits = Substring(integerPart + fractionPart)
        var pointPosition = integerPart.count + exponent
        while digits.first == "0" {
            digits = digits.dropFirst()
            pointPosition -= 1
        }
        while digits.last == "0" { digits = digits.dropLast() }
        return (String(digits), pointPosition)
    }
}

extension JSONValue {
    /// JavaScript `String(value)` (e.g. `1` → `"1"`, `[1, 2]` → `"1,2"`).
    public var javaScriptString: String { JS.toString(self) }

    /// JavaScript truthiness (`Boolean(value)`).
    public var isTruthy: Bool { JS.isTruthy(self) }
}
