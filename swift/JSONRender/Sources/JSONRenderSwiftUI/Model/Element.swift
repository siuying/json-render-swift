import Foundation

/// One element of a spec's flat element map.
public struct Element: Sendable, Hashable {
    /// Component type name from the catalog (e.g. `"TextField"`).
    public var type: String
    /// Raw props; values may be expressions.
    public var props: [String: JSONValue]
    /// Ordered child element keys.
    public var children: [String]
    /// Visibility condition; `nil` means always visible.
    public var visible: JSONValue?
    /// Event name → action bindings.
    public var on: [String: [ActionBinding]]
    /// State pointer → action bindings fired when the value at the pointer changes.
    public var watch: [String: [ActionBinding]]
    /// Renders `children` once per item of a state array (used by the PDF renderer).
    public var `repeat`: RepeatConfig?

    public init(
        type: String,
        props: [String: JSONValue] = [:],
        children: [String] = [],
        visible: JSONValue? = nil,
        on: [String: [ActionBinding]] = [:],
        watch: [String: [ActionBinding]] = [:],
        repeat: RepeatConfig? = nil
    ) {
        self.type = type
        self.props = props
        self.children = children
        self.visible = visible
        self.on = on
        self.watch = watch
        self.repeat = `repeat`
    }

    /// Tolerant decoding; `nil` only when `json` is not an object.
    public init?(json: JSONValue) {
        guard case .object(let members) = json else { return nil }
        self.init(
            type: members["type"]?.stringValue ?? "",
            props: members["props"]?.objectValue ?? [:],
            children: members["children"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            visible: members["visible"],
            on: Self.bindingMap(members["on"]),
            watch: Self.bindingMap(members["watch"]),
            repeat: RepeatConfig(json: members["repeat"])
        )
    }

    private static func bindingMap(_ json: JSONValue?) -> [String: [ActionBinding]] {
        guard let members = json?.objectValue else { return [:] }
        return members.compactMapValues { value in
            let bindings = ActionBinding.list(from: value)
            return bindings.isEmpty ? nil : bindings
        }
    }

    /// The validation config declared through `checks` / `validateOn` / `enabled` props.
    public var validationConfig: ValidationConfig? {
        let config = ValidationConfig(json: .object(props))
        return config.checks.isEmpty ? nil : config
    }
}
