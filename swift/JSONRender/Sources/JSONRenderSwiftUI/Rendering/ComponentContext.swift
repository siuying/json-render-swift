import SwiftUI

/// Everything a component renderer needs to draw one element.
///
/// Props are already resolved against state. Inputs read and write their value through
/// ``binding(_:emitsChange:finishesEditing:)``, which targets the `$bindState` pointer
/// (or element-local storage when the prop is not bound).
@MainActor
public struct ComponentContext {
    /// Element key in the spec.
    public let key: String
    public let element: Element
    /// Resolved props.
    public let props: Props
    public let session: FormSession
    /// Prop name → bound state pointer (`$bindState`).
    public let bindings: [String: String]

    let ancestors: [String]
    let localValues: Binding<[String: JSONValue]>

    /// The element's child elements, rendered in order. Missing keys are skipped.
    public var children: ElementChildren {
        ElementChildren(keys: element.children, ancestors: ancestors + [key])
    }

    /// The validation field this element represents, if it has `checks` and a binding.
    public var field: FormField? {
        FormField(key: key, element: element)
    }

    /// Errors to show under the field (empty until validated).
    public var errors: [String] {
        guard let field else { return [] }
        return session.validation.field(field.path).errors
    }

    /// Two-way binding for a value prop.
    /// - Parameters:
    ///   - emitsChange: dispatch the element's `change` event after each write.
    ///   - finishesEditing: treat each write as the end of editing (validates
    ///     `validateOn: "blur"` fields); use for controls without a focus state.
    public func binding(_ prop: String, emitsChange: Bool = true, finishesEditing: Bool = false) -> Binding<JSONValue?> {
        let path = bindings[prop]
        let session = session
        let props = props
        let localValues = localValues
        return Binding(
            get: {
                if let path { return session.store.value(at: path) }
                return localValues.wrappedValue[prop] ?? props[prop]
            },
            set: { newValue in
                if let path {
                    session.store.set(newValue, at: path)
                } else {
                    localValues.wrappedValue[prop] = newValue ?? .null
                }
                if finishesEditing { didFinishEditing() }
                if emitsChange { emit("change") }
            }
        )
    }

    /// Dispatches the element's bindings for `event` (e.g. `"press"`, `"submit"`).
    public func emit(_ event: String) {
        guard element.on[event] != nil else { return }
        let session = session
        let key = key
        Task { await session.emit(event, from: key) }
    }

    /// Call when editing ends (focus leaves the field).
    public func didFinishEditing() {
        if let field { session.fieldDidBlur(field) }
    }
}
