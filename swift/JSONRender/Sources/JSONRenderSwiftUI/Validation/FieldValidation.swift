import Foundation
import Observation

/// Validation state of one field, keyed by its bound state pointer
/// (mirrors `FieldValidationState` in the React/RN `ValidationProvider`).
@MainActor
@Observable
public final class FieldValidation {
    public let path: String
    /// The user has interacted with (focused and left) the field.
    public internal(set) var touched = false
    /// Validation has run at least once since the last reset.
    public internal(set) var validated = false
    public internal(set) var result: ValidationResult?

    init(path: String) {
        self.path = path
    }

    /// Errors to display: empty until the field has been validated.
    public var errors: [String] {
        validated ? result?.errors ?? [] : []
    }

    public var isValid: Bool { result?.valid ?? true }

    func record(_ result: ValidationResult) {
        touched = true
        validated = true
        if self.result != result { self.result = result }
    }

    func reset() {
        touched = false
        validated = false
        result = nil
    }
}

/// Per-field validation states. Each field is its own observable object, so a
/// change to one field's errors only re-renders that field.
@MainActor
public final class ValidationStore {
    private var fields: [String: FieldValidation] = [:]

    init() {}

    /// The state for `path` (created on first access).
    public func field(_ path: String) -> FieldValidation {
        if let field = fields[path] { return field }
        let field = FieldValidation(path: path)
        fields[path] = field
        return field
    }

    /// Fields that carry any state (touched, validated or a result).
    var fieldsWithState: [FieldValidation] {
        fields.values.filter { $0.touched || $0.validated || $0.result != nil }
    }

    /// Clears validation for fields at or below `path` (all fields when `nil`).
    func reset(under path: String? = nil) {
        let prefix = path.map { JSONPointer.segments($0) }
        for field in fields.values {
            if let prefix, !JSONPointer.segments(field.path).starts(with: prefix) { continue }
            field.reset()
        }
    }
}
