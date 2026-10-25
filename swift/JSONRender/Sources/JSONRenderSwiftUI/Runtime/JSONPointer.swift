import Foundation

/// RFC 6901 JSON Pointer helpers with `@json-render/core` semantics
/// (`parseJsonPointer`, `getByPath`, `immutableSetByPath`).
public enum JSONPointer {
    /// Splits a pointer into unescaped reference tokens. A missing leading `/` is tolerated.
    public static func segments(_ pointer: String) -> [String] {
        let body = pointer.hasPrefix("/") ? String(pointer.dropFirst()) : pointer
        return body.split(separator: "/", omittingEmptySubsequences: false).map { token in
            token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }

    /// Escapes a single reference token.
    public static func escape(_ token: String) -> String {
        token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    /// Joins reference tokens into a pointer.
    public static func pointer(_ segments: [String]) -> String {
        segments.map { "/" + escape($0) }.joined()
    }

    /// `getByPath`: `nil` means the value is absent (`undefined`).
    public static func value(at pointer: String, in root: JSONValue?) -> JSONValue? {
        if pointer.isEmpty || pointer == "/" { return root }
        var current = root
        for segment in segments(pointer) {
            switch current {
            case nil, .null?:
                return nil
            case .array(let items)?:
                guard let index = JS.parseInt(segment), items.indices.contains(index) else { return nil }
                current = items[index]
            case .object(let members)?:
                guard let member = members[segment] else { return nil }
                current = member
            default:
                return nil
            }
        }
        return current
    }

    /// `immutableSetByPath`: returns `root` with `value` written at `pointer`,
    /// creating intermediate containers (arrays when the next token is numeric).
    /// Passing `nil` stores `null`-free absence: the member is removed.
    public static func setting(_ value: JSONValue?, at pointer: String, in root: JSONValue) -> JSONValue {
        let tokens = segments(pointer)
        guard !tokens.isEmpty else { return root }
        let base: JSONValue = root.objectValue != nil ? root : .object([:])
        return write(value, tokens: tokens[...], into: base) ?? root
    }

    private static func write(_ value: JSONValue?, tokens: ArraySlice<String>, into container: JSONValue) -> JSONValue? {
        guard let token = tokens.first else { return value }
        let rest = tokens.dropFirst()
        switch container {
        case .object(var members):
            if rest.isEmpty {
                members[token] = value
            } else {
                let child = intermediate(members[token], nextToken: rest.first!)
                guard let updated = write(value, tokens: rest, into: child) else { return nil }
                members[token] = updated
            }
            return .object(members)
        case .array(var items):
            if rest.isEmpty {
                if token == "-" {
                    items.append(value ?? .null)
                } else {
                    guard let index = JS.parseInt(token), index >= 0 else { return nil }
                    while items.count <= index { items.append(.null) }
                    items[index] = value ?? .null
                }
            } else {
                // Intermediate array access only works for canonical indices ("0", "12").
                guard let index = Int(token), String(index) == token, index >= 0 else { return nil }
                while items.count <= index { items.append(.null) }
                let child = intermediate(items[index], nextToken: rest.first!)
                guard let updated = write(value, tokens: rest, into: child) else { return nil }
                items[index] = updated
            }
            return .array(items)
        default:
            return nil
        }
    }

    private static func intermediate(_ existing: JSONValue?, nextToken: String) -> JSONValue {
        switch existing {
        case .array?, .object?: existing!
        default: isNumericToken(nextToken) ? .array([]) : .object([:])
        }
    }

    /// The canonical location a pointer resolves to (array tokens normalised the way
    /// `getByPath` reads them, so `/a/01` and `/a/1` coincide); `nil` when absent.
    /// Two pointers with the same location name the same JavaScript object in core.
    static func location(of pointer: String, in state: some StateReading) -> [String]? {
        if pointer.isEmpty || pointer == "/" { return [] }
        var canonical: [String] = []
        for token in segments(pointer) {
            switch state.value(at: self.pointer(canonical)) {
            case .array(let items)?:
                guard let index = JS.parseInt(token), items.indices.contains(index) else { return nil }
                canonical.append(String(index))
            case .object(let members)?:
                guard members[token] != nil else { return nil }
                canonical.append(token)
            default:
                return nil
            }
        }
        return canonical
    }

    /// Whether two pointers read the same container from `state` (core reference equality).
    static func referencesSameContainer(_ lhs: String?, _ rhs: String?, in state: some StateReading) -> Bool {
        guard let lhs, let rhs, let location = location(of: lhs, in: state) else { return false }
        switch state.value(at: lhs) {
        case .array?, .object?: return location == self.location(of: rhs, in: state)
        default: return false
        }
    }

    static func isNumericToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

extension JSONValue {
    /// Reads the value at a JSON Pointer (`getByPath` semantics).
    public func value(at pointer: String) -> JSONValue? {
        JSONPointer.value(at: pointer, in: self)
    }

    /// Returns a copy with `value` written at `pointer` (`immutableSetByPath` semantics).
    public func setting(_ value: JSONValue?, at pointer: String) -> JSONValue {
        JSONPointer.setting(value, at: pointer, in: self)
    }
}
