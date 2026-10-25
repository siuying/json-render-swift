import SwiftUI

/// `Text` — `content`, `style`, `color`.
struct TextComponent: View {
    let context: ComponentContext

    var body: some View {
        Text(context.props.string("content") ?? "")
            .font(font)
            .foregroundStyle(color)
    }

    private var font: Font? {
        switch context.props.string("style") {
        case "largeTitle": .largeTitle
        case "title": .title
        case "title2": .title2
        case "headline": .headline
        case "subheadline": .subheadline
        case "body": .body
        case "callout": .callout
        case "caption": .caption
        case "footnote": .footnote
        default: nil
        }
    }

    private var color: AnyShapeStyle {
        switch context.props.string("color") {
        case "secondary": AnyShapeStyle(.secondary)
        case "accent": AnyShapeStyle(.tint)
        case "red": AnyShapeStyle(.red)
        case "orange": AnyShapeStyle(.orange)
        case "green": AnyShapeStyle(.green)
        case "blue": AnyShapeStyle(.blue)
        default: AnyShapeStyle(.primary)
        }
    }
}

/// `LabeledContent` — `label`, `value`.
struct LabeledContentComponent: View {
    let context: ComponentContext

    var body: some View {
        LabeledContent(context.props.string("label") ?? "", value: context.props.string("value") ?? "")
    }
}

/// `Button` — `label`, `systemImage`, `role`, `style`, `disabled`; emits `press`.
/// Disabled with a spinner while one of its `press` host actions is running.
struct ButtonComponent: View {
    let context: ComponentContext

    var body: some View {
        let props = context.props
        let label = props.string("label") ?? ""
        Button(role: role) {
            context.emit("press")
        } label: {
            HStack(spacing: 8) {
                if isRunning { ProgressView() }
                if let systemImage = props.string("systemImage") {
                    Label(label, systemImage: systemImage)
                } else {
                    Text(label)
                }
            }
        }
        .modifier(ButtonStyleModifier(style: props.string("style")))
        .disabled(props.bool("disabled") == true || isRunning)
    }

    private var role: ButtonRole? {
        switch context.props.string("role") {
        case "cancel": .cancel
        case "destructive": .destructive
        default: nil
        }
    }

    private var isRunning: Bool {
        let actions = context.element.on["press"]?.map(\.action) ?? []
        return actions.contains { context.session.runningActions.contains($0) }
    }
}

private struct ButtonStyleModifier: ViewModifier {
    let style: String?

    func body(content: Content) -> some View {
        switch style {
        case "borderedProminent": content.buttonStyle(.borderedProminent)
        case "bordered": content.buttonStyle(.bordered)
        case "borderless": content.buttonStyle(.borderless)
        case "plain": content.buttonStyle(.plain)
        default: content.buttonStyle(.automatic)
        }
    }
}
