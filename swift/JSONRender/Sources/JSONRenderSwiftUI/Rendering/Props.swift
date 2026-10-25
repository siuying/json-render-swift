import Foundation

/// An element's resolved props with typed, null-tolerant accessors
/// (LLMs often emit `null` for unset props; it reads as absent).
public struct Props: Sendable, Hashable {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue]) {
        self.values = values
    }

    /// The value for `key`; `nil` when absent or `null`.
    public subscript(key: String) -> JSONValue? {
        guard let value = values[key], value != .null else { return nil }
        return value
    }

    /// Strings as-is; numbers and booleans converted like JavaScript `String(value)`.
    public func string(_ key: String) -> String? {
        switch self[key] {
        case .string(let string)?: string
        case let value? where value.doubleValue != nil || value.boolValue != nil: JS.toString(value)
        default: nil
        }
    }

    public func double(_ key: String) -> Double? {
        self[key]?.doubleValue.flatMap { $0.isFinite ? $0 : nil }
    }

    /// Rounded to the nearest integer, clamped to ±2³¹ (never traps on huge values).
    public func int(_ key: String) -> Int? {
        double(key).map { Int(min(max($0.rounded(), -2_147_483_648), 2_147_483_647)) }
    }

    public func bool(_ key: String) -> Bool? {
        self[key]?.boolValue
    }

    public func array(_ key: String) -> [JSONValue]? {
        self[key]?.arrayValue
    }

    /// A string prop parsed as an enum; unknown values read as absent.
    public func `enum`<T: RawRepresentable>(_ key: String, as type: T.Type = T.self) -> T? where T.RawValue == String {
        string(key).flatMap(T.init(rawValue:))
    }
}
