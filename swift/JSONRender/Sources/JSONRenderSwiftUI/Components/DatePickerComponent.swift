import SwiftUI

/// `DatePicker` — `label`, `selection` (ISO-8601 string), `components`
/// (date/hourAndMinute/dateAndTime), `minimum`, `maximum`, `style`, `disabled`, `checks`,
/// `validateOn`; emits `change`. An empty selection displays today until the user picks.
struct DatePickerComponent: View {
    let context: ComponentContext

    var body: some View {
        let props = context.props
        let dateOnly = (props.string("components") ?? "date") == "date"
        let value = context.binding("selection", finishesEditing: true)
        let selection = Binding<Date>(
            get: { value.wrappedValue?.stringValue.flatMap { ISODate.parse($0) } ?? .now },
            set: { value.wrappedValue = .string(dateOnly ? ISODate.formatDate($0) : ISODate.formatDateTime($0)) }
        )
        let label = props.string("label") ?? ""
        let minimum = props.string("minimum").flatMap { ISODate.parse($0) }
        let maximum = props.string("maximum").flatMap { ISODate.parse($0) }
        FieldContainer(context: context) {
            Group {
                switch (minimum, maximum) {
                case let (min?, max?) where min <= max:
                    DatePicker(label, selection: selection, in: min...max, displayedComponents: components)
                case let (min?, nil):
                    DatePicker(label, selection: selection, in: min..., displayedComponents: components)
                case let (nil, max?):
                    DatePicker(label, selection: selection, in: ...max, displayedComponents: components)
                default:
                    DatePicker(label, selection: selection, displayedComponents: components)
                }
            }
            .modifier(DatePickerStyleModifier(style: props.string("style")))
            .disabled(context.isDisabled)
        }
    }

    private var components: DatePickerComponents {
        switch context.props.string("components") {
        case "hourAndMinute": [.hourAndMinute]
        case "dateAndTime": [.date, .hourAndMinute]
        default: [.date]
        }
    }
}

private struct DatePickerStyleModifier: ViewModifier {
    let style: String?

    func body(content: Content) -> some View {
        switch style {
        case "compact": content.datePickerStyle(.compact)
        case "graphical": content.datePickerStyle(.graphical)
        #if os(iOS)
        case "wheel": content.datePickerStyle(.wheel)
        #endif
        default: content.datePickerStyle(.automatic)
        }
    }
}
