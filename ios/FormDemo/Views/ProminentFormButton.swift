import JSONRenderSwiftUI
import SwiftUI

/// Custom component override for `Button` with `style: "borderedProminent"`:
/// a full-width Liquid Glass call to action. When it is the only row of its section it
/// replaces the row background, so it reads as the form's primary action.
///
/// Registered with `.jsonRenderComponent("Button")`; other button styles fall back to
/// the SDK's standard renderer.
struct ProminentFormButton: View {
    let context: ComponentContext

    var body: some View {
        let props = context.props
        let label = props.string("label") ?? ""
        Button(role: props.string("role") == "destructive" ? .destructive : nil) {
            context.emit("press")
        } label: {
            HStack(spacing: 8) {
                if isRunning {
                    ProgressView()
                }
                if let systemImage = props.string("systemImage") {
                    Label(label, systemImage: systemImage)
                } else {
                    Text(label)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(props.bool("disabled") == true || isRunning)
        .modifier(StandaloneRow(isEnabled: isAloneInSection))
    }

    private var isAloneInSection: Bool {
        guard let parent = context.session.spec?.elements.values.first(where: { $0.children.contains(context.key) }) else {
            return false
        }
        return parent.type == "Section" && parent.children.count == 1
    }

    /// True while one of the button's `press` actions is running (e.g. an async submit handler).
    private var isRunning: Bool {
        let actions = context.element.on["press"]?.map(\.action) ?? []
        return actions.contains { context.session.runningActions.contains($0) }
    }
}

private struct StandaloneRow: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        } else {
            content
        }
    }
}
