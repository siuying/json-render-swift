import Foundation

/// `{ action, params?, confirm?, onSuccess?, onError? }` (core `ActionBinding`).
public struct ActionBinding: Sendable, Hashable {
    public var action: String
    /// Raw params; values may be expressions and are resolved at dispatch time.
    public var params: [String: JSONValue]
    public var confirm: ActionConfirm?
    /// `{ set: {...} }` or `{ action, params? }`.
    public var onSuccess: JSONValue?
    /// `{ set: {...} }` (with `"$error.message"` substitution) or `{ action, params? }`.
    public var onError: JSONValue?

    public init(
        action: String,
        params: [String: JSONValue] = [:],
        confirm: ActionConfirm? = nil,
        onSuccess: JSONValue? = nil,
        onError: JSONValue? = nil
    ) {
        self.action = action
        self.params = params
        self.confirm = confirm
        self.onSuccess = onSuccess
        self.onError = onError
    }

    /// Tolerant decoding; `nil` unless `action` is a non-empty string.
    public init?(json: JSONValue) {
        guard case .string(let action)? = json["action"], !action.isEmpty else { return nil }
        self.init(
            action: action,
            params: json["params"]?.objectValue ?? [:],
            confirm: json["confirm"].flatMap(ActionConfirm.init(json:)),
            onSuccess: json["onSuccess"],
            onError: json["onError"]
        )
    }

    /// Decodes a single binding or an array of bindings.
    static func list(from json: JSONValue) -> [ActionBinding] {
        if case .array(let items) = json { return items.compactMap(ActionBinding.init(json:)) }
        return ActionBinding(json: json).map { [$0] } ?? []
    }
}

/// Confirmation dialog shown before an action runs (core `ActionConfirm`).
public struct ActionConfirm: Sendable, Hashable {
    public var title: String
    public var message: String
    public var confirmLabel: String?
    public var cancelLabel: String?
    /// `"default"` or `"danger"`.
    public var variant: String?

    public init(title: String, message: String, confirmLabel: String? = nil, cancelLabel: String? = nil, variant: String? = nil) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.variant = variant
    }

    public init?(json: JSONValue) {
        guard json.objectValue != nil else { return nil }
        self.init(
            title: json["title"]?.stringValue ?? "",
            message: json["message"]?.stringValue ?? "",
            confirmLabel: json["confirmLabel"]?.stringValue,
            cancelLabel: json["cancelLabel"]?.stringValue,
            variant: json["variant"]?.stringValue
        )
    }

    public var isDestructive: Bool { variant == "danger" }
}
