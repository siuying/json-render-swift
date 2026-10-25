import Foundation

/// A validation function: `(value, resolvedArgs) -> valid`. `value == nil` means `undefined`.
public typealias ValidationFunction = @Sendable (_ value: JSONValue?, _ args: [String: JSONValue]) -> Bool

/// When a field validates (core `ValidationConfig.validateOn`).
public enum ValidateOn: String, Sendable, Hashable {
    case change, blur, submit
}

/// `{ type, args?, message }` (core `ValidationCheck`).
public struct ValidationCheck: Sendable, Hashable {
    public var type: String
    /// Raw args; values may be expressions (e.g. `{ "$state": "/form/password" }`).
    public var args: [String: JSONValue]
    public var message: String

    public init(type: String, args: [String: JSONValue] = [:], message: String) {
        self.type = type
        self.args = args
        self.message = message
    }

    /// Tolerant decoding from spec JSON; `nil` unless `type` is a string.
    public init?(json: JSONValue) {
        guard case .string(let type)? = json["type"] else { return nil }
        self.init(type: type, args: json["args"]?.objectValue ?? [:], message: json["message"]?.stringValue ?? "")
    }
}

/// `{ checks?, validateOn?, enabled? }` (core `ValidationConfig`).
public struct ValidationConfig: Sendable, Hashable {
    public var checks: [ValidationCheck]
    public var validateOn: ValidateOn?
    /// A visibility condition gating the whole config.
    public var enabled: JSONValue?

    public init(checks: [ValidationCheck] = [], validateOn: ValidateOn? = nil, enabled: JSONValue? = nil) {
        self.checks = checks
        self.validateOn = validateOn
        self.enabled = enabled
    }

    public init(json: JSONValue) {
        self.init(
            checks: json["checks"]?.arrayValue?.compactMap(ValidationCheck.init(json:)) ?? [],
            validateOn: json["validateOn"]?.stringValue.flatMap(ValidateOn.init(rawValue:)),
            enabled: json["enabled"]
        )
    }
}

public struct ValidationCheckResult: Sendable, Hashable {
    public var type: String
    public var valid: Bool
    public var message: String

    public init(type: String, valid: Bool, message: String) {
        self.type = type
        self.valid = valid
        self.message = message
    }
}

public struct ValidationResult: Sendable, Hashable {
    public var valid: Bool
    public var errors: [String]
    public var checks: [ValidationCheckResult]

    public init(valid: Bool, errors: [String], checks: [ValidationCheckResult] = []) {
        self.valid = valid
        self.errors = errors
        self.checks = checks
    }

    public static let passed = ValidationResult(valid: true, errors: [], checks: [])
}
