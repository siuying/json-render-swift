import SwiftUI

/// Wraps an input control with its inline validation error (the first error, as a red
/// caption). Use it in custom input components so they show errors like the built-ins:
///
/// ```swift
/// FieldContainer(context: context) {
///     FieldTitle(text: context.props.string("label") ?? "")
///     RatingControl(value: context.binding("value", finishesEditing: true))
/// }
/// ```
public struct FieldContainer<Control: View>: View {
    let context: ComponentContext
    let control: Control

    public init(context: ComponentContext, @ViewBuilder control: () -> Control) {
        self.context = context
        self.control = control()
    }

    public var body: some View {
        let error = context.errors.first
        VStack(alignment: .leading, spacing: 6) {
            control
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: error)
        .accessibilityElement(children: .contain)
    }
}

/// A caption-style field title shown above text inputs (Form rows hide `TextField` labels).
public struct FieldTitle: View {
    let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        if !text.isEmpty {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

extension ComponentContext {
    /// String binding for text inputs: non-strings display JavaScript-style, writes are strings.
    func textBinding(_ prop: String) -> Binding<String> {
        let value = binding(prop)
        return Binding(
            get: {
                switch value.wrappedValue {
                case nil, .null?: ""
                case .string(let string)?: string
                case let other?: JS.toString(other)
                }
            },
            set: { value.wrappedValue = .string($0) }
        )
    }

    var isDisabled: Bool { props.bool("disabled") == true }
}
