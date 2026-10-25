import SwiftUI

/// `Stepper` — `label`, `value`, `minimum`, `maximum`, `step`, `disabled`, `checks`;
/// emits `change`. Put the live value in the label with `$template`.
struct StepperComponent: View {
    let context: ComponentContext

    var body: some View {
        let props = context.props
        let range = NumberRange(minimum: props.double("minimum"), maximum: props.double("maximum"))
        let value = context.binding("value", finishesEditing: true)
        FieldContainer(context: context) {
            Stepper(
                props.string("label") ?? "",
                value: Binding(
                    get: { range.clamp(value.wrappedValue?.doubleValue ?? range.lower ?? 0) },
                    set: { value.wrappedValue = .number($0) }
                ),
                in: range.closed,
                step: NumberRange.validStep(props.double("step")) ?? 1
            )
            .disabled(context.isDisabled)
        }
    }
}

/// `Slider` — `label`, `value`, `minimum`, `maximum`, `step`, `showValue`, `disabled`,
/// `checks`; emits `change` when a drag ends.
struct SliderComponent: View {
    let context: ComponentContext

    var body: some View {
        let props = context.props
        let lower = props.double("minimum") ?? 0
        let upper = max(props.double("maximum") ?? 1, lower)
        let step = NumberRange.validStep(props.double("step"))
        let value = context.binding("value", emitsChange: false)
        let current = min(max(value.wrappedValue?.doubleValue ?? lower, lower), upper)
        let binding = Binding<Double>(
            get: { current },
            set: { newValue in
                let snapped = step.map { lower + ((newValue - lower) / $0).rounded() * $0 } ?? newValue
                value.wrappedValue = .number(min(max(snapped, lower), upper))
            }
        )
        FieldContainer(context: context) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(props.string("label") ?? "")
                    Spacer()
                    if props.bool("showValue") == true {
                        Text(current, format: .number.precision(.fractionLength(0...2)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Group {
                    if let step, lower < upper {
                        Slider(value: binding, in: lower...upper, step: step, onEditingChanged: editingChanged)
                    } else {
                        Slider(value: binding, in: lower...upper, onEditingChanged: editingChanged)
                    }
                }
                .disabled(context.isDisabled || lower == upper)
            }
        }
    }

    private func editingChanged(_ editing: Bool) {
        guard !editing else { return }
        context.didFinishEditing()
        context.emit("change")
    }
}

/// Optional bounds normalised so ranges never trap (`maximum < minimum` drops the maximum).
struct NumberRange {
    let lower: Double?
    let upper: Double?

    init(minimum: Double?, maximum: Double?) {
        lower = minimum
        if let minimum, let maximum, maximum < minimum {
            upper = nil
        } else {
            upper = maximum
        }
    }

    var closed: ClosedRange<Double> {
        (lower ?? -Double.greatestFiniteMagnitude)...(upper ?? Double.greatestFiniteMagnitude)
    }

    func clamp(_ value: Double) -> Double {
        min(max(value, closed.lowerBound), closed.upperBound)
    }

    static func validStep(_ step: Double?) -> Double? {
        step.flatMap { $0 > 0 ? $0 : nil }
    }
}
