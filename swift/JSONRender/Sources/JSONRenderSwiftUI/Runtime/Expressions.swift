import Foundation

/// Native port of `@json-render/core` prop expression resolution
/// (`resolvePropValue`, `resolveElementProps`, `resolveBindings`, `resolveActionParam`).
///
/// Supported: `$state`, `$bindState`, `$cond`/`$then`/`$else`, `$template`, and inside a
/// ``RepeatScope`` `$item`, `$index`, `$bindItem`. Outside a repeat scope those resolve to
/// absent (`nil`), as in core. `$computed` is not supported and resolves to absent.
public enum Expressions {
    /// Resolves a value that may contain expressions. `nil` means `undefined`.
    public static func resolve(_ value: JSONValue?, state: some StateReading, scope: RepeatScope? = nil) -> JSONValue? {
        var undefinedPaths: [String] = []
        return resolve(value, state: state, scope: scope, at: "", undefinedPaths: &undefinedPaths)
    }

    /// `resolveElementProps`: resolves every prop; absent results are dropped.
    public static func resolveProps(
        _ props: [String: JSONValue], state: some StateReading, scope: RepeatScope? = nil
    ) -> [String: JSONValue] {
        var undefinedPaths: [String] = []
        return resolveMembers(props, state: state, scope: scope, at: "", undefinedPaths: &undefinedPaths)
    }

    /// Resolution that also reports the pointers (relative to the result) of every nested
    /// value core resolves to `undefined` — dropped from objects, `null` in arrays.
    static func resolve(
        _ value: JSONValue?, state: some StateReading, scope: RepeatScope? = nil, at pointer: String,
        undefinedPaths: inout [String]
    ) -> JSONValue? {
        guard let value else { return nil }
        guard case .object(let members) = value else {
            guard case .array(let items) = value else { return value }
            return .array(items.enumerated().map { index, item in
                let itemPointer = pointer + "/\(index)"
                guard let resolved = resolve(item, state: state, scope: scope, at: itemPointer, undefinedPaths: &undefinedPaths)
                else {
                    undefinedPaths.append(itemPointer)
                    return .null
                }
                return resolved
            })
        }
        if case .string(let path)? = members["$state"] {
            return state.value(at: path)
        }
        if case .string(let itemPath)? = members["$item"] {
            return scope?.itemValue(itemPath)
        }
        if members["$index"] == .bool(true) {
            return scope?.index.map { .number(Double($0)) }
        }
        if case .string(let path)? = members["$bindState"] {
            return state.value(at: path)
        }
        if case .string(let itemPath)? = members["$bindItem"] {
            return scope?.absolutePath(itemPath).flatMap { state.value(at: $0) }
        }
        if let condition = members["$cond"], members.keys.contains("$then"), members.keys.contains("$else") {
            let branch = Visibility.evaluate(condition, state: state, scope: scope) ? members["$then"] : members["$else"]
            return resolve(branch, state: state, scope: scope, at: pointer, undefinedPaths: &undefinedPaths)
        }
        if case .string? = members["$computed"] { return nil }
        if case .string(let template)? = members["$template"] {
            return .string(interpolate(template, state: state, scope: scope))
        }
        return .object(resolveMembers(members, state: state, scope: scope, at: pointer, undefinedPaths: &undefinedPaths))
    }

    private static func resolveMembers(
        _ members: [String: JSONValue], state: some StateReading, scope: RepeatScope?, at pointer: String,
        undefinedPaths: inout [String]
    ) -> [String: JSONValue] {
        var resolved: [String: JSONValue] = [:]
        for (key, member) in members {
            let memberPointer = pointer + "/" + JSONPointer.escape(key)
            if let value = resolve(member, state: state, scope: scope, at: memberPointer, undefinedPaths: &undefinedPaths) {
                resolved[key] = value
            } else {
                undefinedPaths.append(memberPointer)
            }
        }
        return resolved
    }

    /// `resolveBindings`: prop name → state pointer for `$bindState` props.
    public static func bindings(in props: [String: JSONValue]) -> [String: String] {
        bindings(in: props, scope: nil)
    }

    /// `resolveBindings` inside a repeat scope: `$bindItem` props bind to the item's
    /// absolute pointer.
    public static func bindings(in props: [String: JSONValue], scope: RepeatScope?) -> [String: String] {
        props.compactMapValues { value in
            if case .string(let pointer)? = value["$bindState"] { return pointer }
            if case .string(let itemPath)? = value["$bindItem"] { return scope?.absolutePath(itemPath) }
            return nil
        }
    }

    /// `resolveActionParam`: inside a repeat scope `{ "$item": "field" }` resolves to the
    /// field's absolute state pointer (for `setState`/`removeState`) and `$index` to the index.
    public static func resolveActionParam(
        _ value: JSONValue?, state: some StateReading, scope: RepeatScope? = nil
    ) -> JSONValue? {
        if case .string(let itemPath)? = value?["$item"] {
            return scope?.absolutePath(itemPath).map(JSONValue.string)
        }
        if value?["$index"] == .bool(true) {
            return scope?.index.map { .number(Double($0)) }
        }
        return resolve(value, state: state, scope: scope)
    }

    /// `$template` interpolation of `${/absolute/path}` and `${bareName}` references. Bare
    /// names read the current repeat item first, then `/<name>` in state.
    public static func interpolate(_ template: String, state: some StateReading, scope: RepeatScope? = nil) -> String {
        replacePlaceholders(in: template) { reference in
            if !reference.hasPrefix("/"), let item = scope?.item,
               let fromItem = item.value(at: reference), fromItem != .null {
                return JS.toString(fromItem)
            }
            let pointer = reference.hasPrefix("/") ? reference : "/" + reference
            guard let value = state.value(at: pointer), value != .null else { return "" }
            return JS.toString(value)
        }
    }

    /// Core's `interpolateString` (used for confirm dialog title/message): `${path}` is
    /// read as a `$state` pointer verbatim.
    static func interpolateConfirm(_ template: String, state: some StateReading) -> String {
        replacePlaceholders(in: template) { reference in
            guard let value = state.value(at: reference), value != .null else { return "" }
            return JS.toString(value)
        }
    }

    /// Equivalent of `template.replace(/\$\{([^}]+)\}/g, replacer)`.
    private static func replacePlaceholders(in template: String, replacer: (String) -> String) -> String {
        var output = ""
        var rest = template[...]
        while let start = rest.range(of: "${") {
            output += rest[..<start.lowerBound]
            let afterOpen = rest[start.upperBound...]
            guard let close = afterOpen.firstIndex(of: "}") else {
                output += rest[start.lowerBound...]
                return output
            }
            if close == afterOpen.startIndex {
                // `${}` does not match; emit "$" and keep scanning from the next character.
                output += "$"
                rest = rest[rest.index(after: start.lowerBound)...]
                continue
            }
            output += replacer(String(afterOpen[..<close]))
            rest = afterOpen[afterOpen.index(after: close)...]
        }
        output += rest
        return output
    }
}
