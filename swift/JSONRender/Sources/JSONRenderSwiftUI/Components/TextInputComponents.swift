import SwiftUI

/// `TextField` — `label`, `placeholder`, `value`, `keyboard`, `contentType`,
/// `autocapitalization`, `multiline`, `lineLimit`, `disabled`, `checks`, `validateOn`;
/// emits `submit` and `change`. Leaving the field (focus loss) counts as blur.
struct TextFieldComponent: View {
    let context: ComponentContext
    @FocusState private var isFocused: Bool

    var body: some View {
        let props = context.props
        let label = props.string("label") ?? ""
        let multiline = props.bool("multiline") == true
        FieldContainer(context: context) {
            FieldTitle(text: label)
            TextField(
                label,
                text: context.textBinding("value"),
                prompt: props.string("placeholder").map { Text($0) },
                axis: multiline ? .vertical : .horizontal
            )
            .modifier(LineLimitModifier(multiline: multiline, lineLimit: props.int("lineLimit")))
            .textInputTraits(
                keyboard: props.string("keyboard"),
                contentType: props.string("contentType"),
                autocapitalization: props.string("autocapitalization")
            )
            .focused($isFocused)
            .onSubmit { context.emit("submit") }
            .disabled(context.isDisabled)
        }
        .onChange(of: isFocused) { wasFocused, focused in
            if wasFocused && !focused { context.didFinishEditing() }
        }
    }
}

/// `SecureField` — `label`, `placeholder`, `value`, `contentType`, `disabled`, `checks`,
/// `validateOn`; emits `submit` and `change`.
struct SecureFieldComponent: View {
    let context: ComponentContext
    @FocusState private var isFocused: Bool

    var body: some View {
        let props = context.props
        let label = props.string("label") ?? ""
        FieldContainer(context: context) {
            FieldTitle(text: label)
            SecureField(label, text: context.textBinding("value"), prompt: props.string("placeholder").map { Text($0) })
                .textInputTraits(keyboard: nil, contentType: props.string("contentType"), autocapitalization: "never")
                .focused($isFocused)
                .onSubmit { context.emit("submit") }
                .disabled(context.isDisabled)
        }
        .onChange(of: isFocused) { wasFocused, focused in
            if wasFocused && !focused { context.didFinishEditing() }
        }
    }
}

private struct LineLimitModifier: ViewModifier {
    let multiline: Bool
    let lineLimit: Int?

    func body(content: Content) -> some View {
        if let lineLimit, lineLimit > 0 {
            content.lineLimit(multiline ? 1...lineLimit : lineLimit...lineLimit)
        } else if multiline {
            content.lineLimit(3...)
        } else {
            content
        }
    }
}
