import Foundation

/// A JSON document value: `null | bool | number | string | array | object`.
///
/// Numbers are stored as `Double`, matching JavaScript's single number type so
/// runtime semantics line up with `@json-render/core`. "Absent" (JavaScript
/// `undefined`) is modelled as `Optional<JSONValue>.none` throughout the SDK.
///
/// Equality follows JavaScript: strings compare by UTF-16 code units, so `"é"` and
/// `"e\u{301}"` differ (Swift `String ==` would treat them as equal). Object keys are
/// still stored in a Swift `Dictionary`, so keys differing only by Unicode normalization
/// collide.
public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Equality

extension JSONValue: Hashable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.string(a), .string(b)): a.utf16.elementsEqual(b.utf16)
        case let (.array(a), .array(b)): a.count == b.count && zip(a, b).allSatisfy { $0 == $1 }
        case let (.object(a), .object(b)): a.count == b.count && a.allSatisfy { key, value in b[key] == value }
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .bool(let value):
            hasher.combine(1)
            hasher.combine(value)
        case .number(let value):
            hasher.combine(2)
            hasher.combine(value)
        case .string(let value):
            hasher.combine(3)
            hasher.combine(value.utf16.count)
            for unit in value.utf16 { hasher.combine(unit) }
        case .array(let items):
            hasher.combine(4)
            hasher.combine(items.count)
            for item in items { hasher.combine(item) }
        case .object(let members):
            hasher.combine(5)
            hasher.combine(members.count)
            // Order-independent combination of the entries.
            var entries = 0
            for (key, value) in members {
                var entry = Hasher()
                entry.combine(key)
                entry.combine(value)
                entries ^= entry.finalize()
            }
            hasher.combine(entries)
        }
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Serialization helpers

extension JSONValue {
    /// Parses a JSON document. Fragments (bare strings, numbers…) are allowed.
    public init(jsonString: String) throws {
        try self.init(jsonData: Data(jsonString.utf8))
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: jsonData)
    }

    /// Serializes to JSON with sorted keys. Compact by default; `prettyPrinted` uses
    /// two-space indentation, `"key": value` and `[]`/`{}` for empty containers.
    /// Numbers print like JavaScript (`1`, `1.5`, `1e+21`); non-finite numbers print `null`.
    public func jsonString(prettyPrinted: Bool = false) -> String {
        var output = ""
        write(to: &output, indent: prettyPrinted ? "" : nil)
        return output
    }

    /// `indent == nil` writes compact JSON.
    private func write(to output: inout String, indent: String?) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let value):
            output += value.isFinite ? JS.numberToString(value) : "null"
        case .string(let value):
            Self.writeString(value, to: &output)
        case .array(let items):
            writeContainer(items, open: "[", close: "]", to: &output, indent: indent) { item, output, indent in
                item.write(to: &output, indent: indent)
            }
        case .object(let members):
            let entries = members.sorted { $0.key < $1.key }
            writeContainer(entries, open: "{", close: "}", to: &output, indent: indent) { entry, output, indent in
                Self.writeString(entry.key, to: &output)
                output += indent == nil ? ":" : ": "
                entry.value.write(to: &output, indent: indent)
            }
        }
    }

    private func writeContainer<Element>(
        _ elements: [Element], open: String, close: String, to output: inout String, indent: String?,
        writeElement: (Element, inout String, String?) -> Void
    ) {
        guard !elements.isEmpty else {
            output += open + close
            return
        }
        output += open
        let inner = indent.map { $0 + "  " }
        for (index, element) in elements.enumerated() {
            if index > 0 { output += "," }
            if let inner { output += "\n" + inner }
            writeElement(element, &output, inner)
        }
        if let indent { output += "\n" + indent }
        output += close
    }

    /// `JSON.stringify` string escaping.
    private static func writeString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Accessors

extension JSONValue {
    public var isNull: Bool { self == .null }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        guard case .number(let value) = self, value.isFinite, value.rounded() == value,
              abs(value) < 9_007_199_254_740_992 else { return nil }
        return Int(value)
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Object member lookup; `nil` for non-objects and missing keys.
    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Array element lookup; `nil` for non-arrays and out-of-range indices.
    public subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { jsonString() }
}
