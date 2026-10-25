import SwiftUI

/// `Toggle` — `label`, `isOn`, `disabled`, `checks`, `validateOn`; emits `change`.
struct ToggleComponent: View {
    let context: ComponentContext

    var body: some View {
        let value = context.binding("isOn", finishesEditing: true)
        FieldContainer(context: context) {
            Toggle(
                context.props.string("label") ?? "",
                isOn: Binding(get: { value.wrappedValue == .bool(true) }, set: { value.wrappedValue = .bool($0) })
            )
            .disabled(context.isDisabled)
        }
    }
}

/// `Picker` — `label`, `selection`, `options` (`[{label, value}]`), `style`, `disabled`,
/// `checks`, `validateOn`; emits `change`. A selection matching no option (e.g. `""`)
/// shows a "Select…" placeholder row in list-like styles.
struct PickerComponent: View {
    let context: ComponentContext

    private struct Option {
        let label: String
        let value: JSONValue
    }

    var body: some View {
        let value = context.binding("selection", finishesEditing: true)
        let current = value.wrappedValue ?? .null
        let options = self.options
        let style = context.props.string("style")
        let label = context.props.string("label") ?? ""
        FieldContainer(context: context) {
            if showsFieldTitle { FieldTitle(text: label) }
            Picker(label, selection: Binding(get: { current }, set: { value.wrappedValue = $0 })) {
                if style != "segmented", !options.contains(where: { $0.value == current }) {
                    Text("Select…").tag(current)
                }
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].label).tag(options[index].value)
                }
            }
            .modifier(PickerStyleModifier(style: style))
            .disabled(context.isDisabled)
            .accessibilityLabel(label)
        }
    }

    /// Segmented pickers don't display their label (notably inside a Form), so a title is
    /// shown above them like text fields.
    var showsFieldTitle: Bool { context.props.string("style") == "segmented" }

    private var options: [Option] {
        (context.props.array("options") ?? []).compactMap { option in
            guard let value = option["value"], value.stringValue != nil || value.doubleValue != nil else { return nil }
            let label = option["label"].map { JS.toString($0) } ?? JS.toString(value)
            return Option(label: label, value: value)
        }
    }
}

private struct PickerStyleModifier: ViewModifier {
    let style: String?

    func body(content: Content) -> some View {
        switch style {
        case "segmented": content.pickerStyle(.segmented).labelsHidden()
        case "inline": content.pickerStyle(.inline)
        #if os(iOS)
        case "wheel": content.pickerStyle(.wheel)
        case "navigationLink": content.pickerStyle(.navigationLink)
        #endif
        case "menu": content.pickerStyle(.menu)
        default: content.pickerStyle(.automatic)
        }
    }
}
