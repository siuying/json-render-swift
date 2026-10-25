import Foundation

/// Native port of `@json-render/core` `evaluateVisibility`.
///
/// Conditions: `true`/`false`, `{ "$state": ptr, eq|neq|gt|gte|lt|lte, not? }`,
/// arrays (implicit AND of single conditions), `{ "$and": [...] }`, `{ "$or": [...] }`.
/// Malformed conditions (which make core throw) evaluate to hidden.
public enum Visibility {
    /// `nil` (no condition) is visible.
    /// Inside a repeat, pass `scope` to enable `$item` / `$index` conditions.
    public static func evaluate(_ condition: JSONValue?, state: some StateReading, scope: RepeatScope? = nil) -> Bool {
        switch condition {
        case nil:
            return true
        case .bool(let visible)?:
            return visible
        case .array(let conditions)?:
            return conditions.allSatisfy { evaluateSingle($0, state: state, scope: scope) }
        case .object(let members)?:
            if members.keys.contains("$and") {
                guard case .array(let children)? = members["$and"] else { return false }
                return children.allSatisfy { evaluate($0, state: state, scope: scope) }
            }
            if members.keys.contains("$or") {
                guard case .array(let children)? = members["$or"] else { return false }
                return children.contains { evaluate($0, state: state, scope: scope) }
            }
            return evaluateSingle(condition!, state: state, scope: scope)
        default:
            return false
        }
    }

    private static func evaluateSingle(_ condition: JSONValue, state: some StateReading, scope: RepeatScope?) -> Bool {
        guard case .object(let cond) = condition else { return false }
        let value = leftHandSide(cond, state: state, scope: scope)
        let result: Bool
        if let rhs = cond["eq"] {
            result = strictEquals(value, rhs, cond: cond, state: state, scope: scope)
        } else if let rhs = cond["neq"] {
            result = !strictEquals(value, rhs, cond: cond, state: state, scope: scope)
        } else if let rhs = cond["gt"] {
            result = compare(value, comparisonValue(rhs, state: state), by: >)
        } else if let rhs = cond["gte"] {
            result = compare(value, comparisonValue(rhs, state: state), by: >=)
        } else if let rhs = cond["lt"] {
            result = compare(value, comparisonValue(rhs, state: state), by: <)
        } else if let rhs = cond["lte"] {
            result = compare(value, comparisonValue(rhs, state: state), by: <=)
        } else {
            result = JS.isTruthy(value)
        }
        return cond["not"] == .bool(true) ? !result : result
    }

    /// Repeat-scope sources (`$index`, `$item`) are absent outside a repeat.
    private static func leftHandSide(_ cond: [String: JSONValue], state: some StateReading, scope: RepeatScope?) -> JSONValue? {
        if cond.keys.contains("$index") { return scope?.index.map { .number(Double($0)) } }
        if cond.keys.contains("$item") {
            guard case .string(let itemPath)? = cond["$item"] else { return nil }
            return scope?.itemValue(itemPath)
        }
        guard case .string(let pointer)? = cond["$state"] else {
            // core: getByPath(state, undefined) returns the whole state model.
            return state.value(at: "")
        }
        return state.value(at: pointer)
    }

    /// `===` where containers read from the same state location are the same reference.
    private static func strictEquals(
        _ value: JSONValue?, _ rhs: JSONValue, cond: [String: JSONValue], state: some StateReading, scope: RepeatScope?
    ) -> Bool {
        let other = comparisonValue(rhs, state: state)
        var sameReference = false
        if case .string(let rhsPointer)? = rhs["$state"], !cond.keys.contains("$index") {
            // A repeat item is the state array's element itself, so `$item` has a location too.
            let lhsPointer: String? = cond.keys.contains("$item")
                ? cond["$item"]?.stringValue.flatMap { scope?.absolutePath($0) }
                : cond["$state"]?.stringValue ?? ""
            sameReference = JSONPointer.referencesSameContainer(lhsPointer, rhsPointer, in: state)
        }
        return JS.strictEquals(value, other, sameReference: sameReference)
    }

    private static func comparisonValue(_ value: JSONValue, state: some StateReading) -> JSONValue? {
        if case .string(let pointer)? = value["$state"] { return state.value(at: pointer) }
        return value
    }

    private static func compare(_ lhs: JSONValue?, _ rhs: JSONValue?, by op: (Double, Double) -> Bool) -> Bool {
        guard let a = JS.typeofNumber(lhs), let b = JS.typeofNumber(rhs) else { return false }
        return op(a, b)
    }
}
