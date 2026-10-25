import SwiftUI

extension ComponentRegistry {
    /// Native SwiftUI renderers for every component in the `@json-render/swift` catalog.
    public static let standard: ComponentRegistry = {
        var registry = ComponentRegistry()
        registry.register("Form") { FormComponent(context: $0) }
        registry.register("Section") { SectionComponent(context: $0) }
        registry.register("VStack") { VStackComponent(context: $0) }
        registry.register("HStack") { HStackComponent(context: $0) }
        registry.register("Text") { TextComponent(context: $0) }
        registry.register("LabeledContent") { LabeledContentComponent(context: $0) }
        registry.register("Divider") { _ in Divider() }
        registry.register("TextField") { TextFieldComponent(context: $0) }
        registry.register("SecureField") { SecureFieldComponent(context: $0) }
        registry.register("Toggle") { ToggleComponent(context: $0) }
        registry.register("Picker") { PickerComponent(context: $0) }
        registry.register("DatePicker") { DatePickerComponent(context: $0) }
        registry.register("Stepper") { StepperComponent(context: $0) }
        registry.register("Slider") { SliderComponent(context: $0) }
        registry.register("Button") { ButtonComponent(context: $0) }
        return registry
    }()
}
