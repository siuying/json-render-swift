import Foundation

/// An input element that participates in validation: it declares `checks` and binds
/// its value with `$bindState`. Validation state is keyed by ``path``.
public struct FormField: Sendable, Hashable {
    /// Element key in the spec.
    public var key: String
    /// The bound state pointer (validation key).
    public var path: String
    public var config: ValidationConfig

    /// Effective trigger; the contract default is `submit`.
    public var validateOn: ValidateOn { config.validateOn ?? .submit }

    /// Props that carry an input's value binding, in priority order.
    static let valueProps = ["value", "isOn", "selection"]

    public init?(key: String, element: Element) {
        guard let config = element.validationConfig, let path = Self.boundPath(of: element) else { return nil }
        self.key = key
        self.path = path
        self.config = config
    }

    /// The `$bindState` pointer of the element's value prop.
    static func boundPath(of element: Element) -> String? {
        let bindings = Expressions.bindings(in: element.props)
        for prop in valueProps {
            if let path = bindings[prop] { return path }
        }
        return bindings.sorted(by: { $0.key < $1.key }).first?.value
    }

    /// Fields reachable from the root, in document order: through visible elements only
    /// (what validation covers), or through every element when `includeHidden`.
    static func fields(in spec: Spec, state: JSONValue, includeHidden: Bool = false) -> [FormField] {
        visibleElements(in: spec, state: state, includeHidden: includeHidden)
            .compactMap { FormField(key: $0.key, element: $0.element) }
    }

    /// Elements reachable from the root whose own and ancestors' `visible` conditions pass
    /// (i.e. the elements a renderer mounts). Cycles and dangling keys are skipped.
    static func visibleElements(
        in spec: Spec, state: JSONValue, includeHidden: Bool = false
    ) -> [(key: String, element: Element)] {
        guard let root = spec.root else { return [] }
        var result: [(key: String, element: Element)] = []
        var visited: Set<String> = []
        func visit(_ key: String) {
            guard visited.insert(key).inserted, let element = spec.elements[key],
                  includeHidden || Visibility.evaluate(element.visible, state: state) else { return }
            result.append((key, element))
            element.children.forEach(visit)
        }
        visit(root)
        return result
    }
}
