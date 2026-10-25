import Foundation

/// A json-render spec: a flat element map plus optional initial state.
///
/// `Spec` is a tolerant, parsed view over the raw JSON document so that partially
/// streamed specs (missing root, half-filled elements, dangling children) decode
/// without failing. The raw document is preserved in ``json`` for round-tripping
/// (fields the SDK does not model, such as `repeat` or `slots`, survive).
public struct Spec: Sendable, Hashable {
    /// The raw spec document.
    public let json: JSONValue
    /// Root element key; `nil` until the stream has provided one.
    public let root: String?
    /// Elements by key. Entries that are not objects are skipped.
    public let elements: [String: Element]
    /// Initial state (`spec.state`), if present.
    public let state: JSONValue?

    public init(json: JSONValue) {
        self.json = json
        root = json["root"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        var elements: [String: Element] = [:]
        for (key, value) in json["elements"]?.objectValue ?? [:] {
            if let element = Element(json: value) { elements[key] = element }
        }
        self.elements = elements
        if let state = json["state"], state.objectValue != nil {
            self.state = state
        } else {
            self.state = nil
        }
    }

    public init(jsonString: String) throws {
        self.init(json: try JSONValue(jsonString: jsonString))
    }

    public init(jsonData: Data) throws {
        self.init(json: try JSONValue(jsonData: jsonData))
    }

    /// An empty spec (useful as the starting point of a stream).
    public static let empty = Spec(json: .object([:]))

    /// The root element, when both the key and the element are present.
    public var rootElement: Element? {
        root.flatMap { elements[$0] }
    }
}

extension Spec: Codable {
    public init(from decoder: Decoder) throws {
        self.init(json: try JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}
