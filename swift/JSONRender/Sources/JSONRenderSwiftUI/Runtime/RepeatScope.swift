import Foundation

/// The scope inside a `repeat` element: the current item, its index and its absolute
/// state pointer (core `PropResolutionContext.repeatItem/repeatIndex/repeatBasePath`).
/// Enables `$item`, `$index` and `$bindItem` expressions and conditions.
public struct RepeatScope: Sendable, Hashable {
    public var item: JSONValue?
    public var index: Int?
    /// Absolute pointer of the current item, e.g. `/todos/0`.
    public var basePath: String?

    public init(item: JSONValue?, index: Int?, basePath: String?) {
        self.item = item
        self.index = index
        self.basePath = basePath
    }

    /// `resolveBindItemPath`: `""` is the item itself, `"field"` → `basePath/field`.
    func absolutePath(_ itemPath: String) -> String? {
        guard let basePath else { return nil }
        return itemPath.isEmpty ? basePath : basePath + "/" + itemPath
    }

    /// `$item` lookup: `""` is the whole item.
    func itemValue(_ itemPath: String) -> JSONValue? {
        guard let item else { return nil }
        return itemPath.isEmpty ? item : item.value(at: itemPath)
    }
}

/// `repeat: { statePath, key? }` on an element. `statePath` is a pointer or an
/// item-relative `{ "$item": "field" }` for nested repeats.
public struct RepeatConfig: Sendable, Hashable {
    public var statePath: JSONValue
    public var key: String?

    public init(statePath: JSONValue, key: String? = nil) {
        self.statePath = statePath
        self.key = key
    }

    init?(json: JSONValue?) {
        guard let json, let statePath = json["statePath"] else { return nil }
        self.init(statePath: statePath, key: json["key"]?.stringValue)
    }

    /// `resolveRepeatStatePath`: the absolute array pointer, or `nil` for `$item` paths
    /// outside a repeat scope.
    public func resolvedStatePath(in scope: RepeatScope?) -> String? {
        if case .string(let path) = statePath { return path }
        guard case .string(let itemPath)? = statePath["$item"], let base = scope?.basePath else { return nil }
        return itemPath.isEmpty || itemPath == "/" ? base : Self.join(base, itemPath)
    }

    /// The scopes for each item of the array at the resolved state path.
    public func scopes(state: some StateReading, in scope: RepeatScope?) -> [RepeatScope] {
        guard let path = resolvedStatePath(in: scope), let items = state.value(at: path)?.arrayValue else { return [] }
        return items.enumerated().map { index, item in
            RepeatScope(item: item, index: index, basePath: Self.join(path, String(index)))
        }
    }

    /// Identity of an item: its `key` field when present, else the index.
    public func identity(of scope: RepeatScope) -> String {
        if let key, let value = scope.item?[key], value != .null { return JS.toString(value) }
        return String(scope.index ?? 0)
    }

    /// core `joinStatePath`.
    static func join(_ base: String, _ child: String) -> String {
        let trimmed = child.hasPrefix("/") ? String(child.dropFirst()) : child
        return base.isEmpty || base == "/" ? "/" + trimmed : base + "/" + trimmed
    }
}
