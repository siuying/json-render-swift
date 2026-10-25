import Foundation
import OSLog

/// Native port of `@json-render/core` validation (`builtInValidationFunctions`,
/// `runValidationCheck`, `runValidation`).
public enum Validation {
    /// Exactly core's built-in check types.
    public static let builtInFunctions: [String: ValidationFunction] = [
        "required": { value, _ in isPresent(value) },
        "email": { value, _ in
            guard case .string(let string)? = value else { return false }
            return isEmail(string)
        },
        "minLength": { value, args in
            guard case .string(let string)? = value, let min = JS.typeofNumber(args["min"]) else { return false }
            return Double(JS.length(string)) >= min
        },
        "maxLength": { value, args in
            guard case .string(let string)? = value, let max = JS.typeofNumber(args["max"]) else { return false }
            return Double(JS.length(string)) <= max
        },
        "pattern": { value, args in
            guard case .string(let string)? = value, case .string(let pattern)? = args["pattern"] else { return false }
            return JSRegex.test(pattern, string)
        },
        "min": { value, args in
            guard let number = JS.typeofNumber(value), let min = JS.typeofNumber(args["min"]) else { return false }
            return number >= min
        },
        "max": { value, args in
            guard let number = JS.typeofNumber(value), let max = JS.typeofNumber(args["max"]) else { return false }
            return number <= max
        },
        "numeric": { value, _ in
            switch value {
            case .number(let number)?: !number.isNaN
            case .string(let string)?: !JS.trim(string).isEmpty && !JS.stringToNumber(string).isNaN
            default: false
            }
        },
        "url": { value, _ in
            guard case .string(let string)? = value else { return false }
            return URLSyntax.isValid(string)
        },
        "matches": { value, args in JS.strictEquals(value, args["other"]) },
        "equalTo": { value, args in JS.strictEquals(value, args["other"]) },
        "lessThan": { value, args in compare(value, args["other"], numbers: <, strings: JS.lessThan) },
        "greaterThan": { value, args in
            compare(value, args["other"], numbers: >, strings: { JS.lessThan($1, $0) })
        },
        "requiredIf": { value, args in
            guard JS.isTruthy(args["field"]) else { return true }
            return isPresent(value)
        },
    ]

    /// Runs one check; args are resolved as prop expressions. Unknown types pass.
    /// - Parameter valuePointer: where `value` was read from. When a `matches`/`equalTo`
    ///   `other` arg reads the same state container, the two are the same reference in
    ///   core and compare equal.
    public static func runCheck(
        _ check: ValidationCheck,
        value: JSONValue?,
        state: some StateReading,
        customFunctions: [String: ValidationFunction] = [:],
        valuePointer: String? = nil
    ) -> ValidationCheckResult {
        var resolvedArgs: [String: JSONValue] = [:]
        for (key, arg) in check.args {
            resolvedArgs[key] = Expressions.resolve(arg, state: state)
        }
        if check.type == "matches" || check.type == "equalTo",
           case .string(let otherPointer)? = check.args["other"]?["$state"],
           JSONPointer.referencesSameContainer(valuePointer, otherPointer, in: state)
        {
            return ValidationCheckResult(type: check.type, valid: true, message: check.message)
        }
        guard let function = builtInFunctions[check.type] ?? customFunctions[check.type] else {
            Logger.jsonRender.warning("Unknown validation function: \(check.type, privacy: .public)")
            return ValidationCheckResult(type: check.type, valid: true, message: check.message)
        }
        return ValidationCheckResult(type: check.type, valid: function(value, resolvedArgs), message: check.message)
    }

    /// Runs all checks of a config. A falsy-but-present `enabled` (e.g. `false`) does not
    /// disable validation — this mirrors core's `if (config.enabled)` guard.
    public static func run(
        _ config: ValidationConfig,
        value: JSONValue?,
        state: some StateReading,
        customFunctions: [String: ValidationFunction] = [:],
        valuePointer: String? = nil
    ) -> ValidationResult {
        if let enabled = config.enabled, JS.isTruthy(enabled), !Visibility.evaluate(enabled, state: state) {
            return .passed
        }
        let checks = config.checks.map {
            runCheck($0, value: value, state: state, customFunctions: customFunctions, valuePointer: valuePointer)
        }
        let errors = checks.filter { !$0.valid }.map(\.message)
        return ValidationResult(valid: errors.isEmpty, errors: errors, checks: checks)
    }

    // MARK: Helpers

    private static func isPresent(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: false
        case .string(let string)?: !JS.trim(string).isEmpty
        case .array(let items)?: !items.isEmpty
        default: true
        }
    }

    /// `/^[^\s@]+@[^\s@]+\.[^\s@]+$/` without a regex engine (JS `\s` semantics).
    private static func isEmail(_ string: String) -> Bool {
        let scalars = Array(string.unicodeScalars)
        guard !scalars.contains(where: JS.isWhitespace) else { return false }
        let parts = scalars.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        let domain = Array(parts[1])
        guard domain.count >= 3 else { return false }
        return domain[1..<(domain.count - 1)].contains(".")
    }

    /// Shared body of `lessThan` / `greaterThan`.
    private static func compare(
        _ value: JSONValue?,
        _ other: JSONValue?,
        numbers: (Double, Double) -> Bool,
        strings: (String, String) -> Bool
    ) -> Bool {
        func isBlank(_ v: JSONValue?) -> Bool { v == nil || v == .null || v == .string("") }
        if isBlank(value) || isBlank(other) { return false }
        switch (value, other) {
        case (.number(let a)?, .number(let b)?): return numbers(a, b)
        case (.string(let a)?, .string(let b)?): return strings(a, b)
        default:
            let a = JS.toNumber(value), b = JS.toNumber(other)
            return !a.isNaN && !b.isNaN && numbers(a, b)
        }
    }
}

extension Logger {
    static let jsonRender = Logger(subsystem: "JSONRenderSwiftUI", category: "runtime")
}
