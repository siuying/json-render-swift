import SwiftUI

/// `Form` — `title`, `subtitle`. A `Form` nested inside another renders its children inline.
struct FormComponent: View {
    let context: ComponentContext
    @Environment(\.jsonRenderInsideForm) private var insideForm

    var body: some View {
        if insideForm {
            context.children
        } else {
            Form {
                context.children
            }
            .environment(\.jsonRenderInsideForm, true)
            .navigationTitle(context.props.string("title") ?? "")
            .navigationSubtitle(context.props.string("subtitle") ?? "")
        }
    }
}

/// `Section` — `header`, `footer`.
struct SectionComponent: View {
    let context: ComponentContext

    var body: some View {
        Section {
            context.children
        } header: {
            if let header = context.props.string("header") { Text(header) }
        } footer: {
            if let footer = context.props.string("footer") { Text(footer) }
        }
    }
}

/// `VStack` — `spacing`, `alignment` (leading/center/trailing).
struct VStackComponent: View {
    let context: ComponentContext

    var body: some View {
        VStack(alignment: alignment, spacing: context.props.double("spacing").map { CGFloat($0) }) {
            context.children
        }
    }

    private var alignment: HorizontalAlignment {
        switch context.props.string("alignment") {
        case "leading": .leading
        case "trailing": .trailing
        default: .center
        }
    }
}

/// `HStack` — `spacing`, `alignment` (top/center/bottom).
struct HStackComponent: View {
    let context: ComponentContext

    var body: some View {
        HStack(alignment: alignment, spacing: context.props.double("spacing").map { CGFloat($0) }) {
            context.children
        }
    }

    private var alignment: VerticalAlignment {
        switch context.props.string("alignment") {
        case "top": .top
        case "bottom": .bottom
        default: .center
        }
    }
}
