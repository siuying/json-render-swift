import CoreGraphics
import Foundation
import JSONRenderSwiftUI

/// Layout of the fillable-form components. Widgets have fixed geometry; each field's
/// label and widget form one keep-together box so they always move between pages
/// together, and widgets never split.
extension DocumentBuilder {
    static let labelColor = PDFColor("#374151")!
    static let hintColor = PDFColor("#9ca3af")!
    static let fieldBorder = PDFColor("#9ca3af")!

    // MARK: FieldSet

    func fieldSet(_ element: ResolvedElement) -> LayoutNode {
        // FieldSets and fields share one namespace: a taken qualified name gets "#2", "#3"…
        // (descendants are then qualified under the suffixed name).
        let base = Self.fieldName(element)
        let scope = fieldSetStack.map { form.fieldSets[$0].name }
        var name = base
        var suffix = 2
        while usedFieldNames.contains((scope + [name]).joined(separator: ".")) {
            name = "\(base)#\(suffix)"
            suffix += 1
        }
        usedFieldNames.insert((scope + [name]).joined(separator: "."))
        form.fieldSets.append(FormFieldSetModel(name: name, parent: fieldSetStack.last))
        fieldSetStack.append(form.fieldSets.count - 1)
        defer { fieldSetStack.removeLast() }

        var nodes: [LayoutNode] = []
        if let label = element.string("label"), !label.isEmpty {
            var text = TextStyle()
            text.fontSize = fieldSetStack.count > 1 ? 10 : 11
            text.bold = true
            text.color = PDFColor("#111827")!
            nodes.append(textNode(label, text, key: "\(element.key)#label"))
        }
        nodes += children(element)
        var style = BoxStyle()
        style.gap = 6
        return LayoutNode(style: style, content: .container(nodes), breakBehavior: .keepTogetherIfSmall, key: element.key)
    }

    // MARK: Fields

    func formField(_ element: ResolvedElement) -> LayoutNode {
        guard let type = PDFFormFieldType(rawValue: element.type) else { return LayoutNode(content: .empty) }
        let field = registerField(element, type: type)
        let id = field.id
        switch type {
        case .checkbox:
            var box = LayoutNode(content: .formWidget(FormWidgetRef(fieldID: id, option: nil, kind: type)))
            box.style.width = .points(12)
            box.style.height = 12
            var row = BoxStyle()
            row.direction = .row
            row.gap = 6
            row.alignItems = .center
            return LayoutNode(style: row, content: .container([box, optionLabel(field.label ?? "")]), key: element.key)

        case .radioGroup:
            let options = field.info.options.enumerated().map { index, option -> LayoutNode in
                var dot = LayoutNode(content: .formWidget(FormWidgetRef(fieldID: id, option: index, kind: type)))
                dot.style.width = .points(12)
                dot.style.height = 12
                var row = BoxStyle()
                row.direction = .row
                row.gap = 6
                row.alignItems = .center
                return LayoutNode(style: row, content: .container([dot, optionLabel(option.label)]))
            }
            var group = BoxStyle()
            group.direction = field.direction
            group.gap = field.direction == .row ? 14 : 4
            group.wrap = field.direction == .row
            var choices = LayoutNode(style: group, content: .container(options))
            choices.breakBehavior = .keepTogether
            return labelled(field, element: element, widget: choices)

        case .textInput, .select, .listBox:
            var widget = LayoutNode(content: .formWidget(FormWidgetRef(fieldID: id, option: nil, kind: type)))
            widget.style.height = switch type {
            case .textInput: field.multiline ? CGFloat(field.lines) * 14 + 8 : 22
            case .listBox: CGFloat(field.lines) * 14 + 6
            default: 22
            }
            widget.style.width = element.number("width", in: 1...Self.length.upperBound).map { .points($0) }
            return labelled(field, element: element, widget: widget)
        }
    }

    /// Label (plus the placeholder as a grey hint) above the widget, kept together.
    private func labelled(_ field: FormFieldModel, element: ResolvedElement, widget: LayoutNode) -> LayoutNode {
        var nodes: [LayoutNode] = []
        let placeholder = element.string("placeholder").flatMap { $0.isEmpty ? nil : $0 }
        if field.label?.isEmpty == false || placeholder != nil {
            var label = TextStyle()
            label.fontSize = 9
            label.color = Self.labelColor
            var parts: [LayoutNode] = []
            if let text = field.label, !text.isEmpty { parts.append(textNode(text, label, key: nil)) }
            if let placeholder {
                var hint = label
                hint.color = Self.hintColor
                parts.append(textNode(placeholder, hint, key: nil))
            }
            var row = BoxStyle()
            row.direction = .row
            row.gap = 6
            row.alignItems = .end
            nodes.append(LayoutNode(style: row, content: .container(parts)))
        }
        nodes.append(widget)
        var style = BoxStyle()
        style.gap = 3
        return LayoutNode(style: style, content: .container(nodes), breakBehavior: .keepTogether, key: element.key)
    }

    /// A checkbox/radio option label at its natural width (an auto-sized row child shrinks,
    /// wrapping at spaces, only when the row is overfull); never hyphenated.
    private func optionLabel(_ text: String) -> LayoutNode {
        var style = TextStyle()
        style.fontSize = 10
        style.color = PDFColor("#111827")!
        style.hyphenate = false
        return textNode(text, style, key: nil)
    }

    // MARK: Field model

    /// Normalizes props into a field (react-pdf / parity-fixture semantics) and assigns a
    /// unique fully qualified name.
    private func registerField(_ element: ResolvedElement, type: PDFFormFieldType) -> FormFieldModel {
        let base = Self.fieldName(element)
        let scope = fieldSetStack.map { form.fieldSets[$0].name }
        var partial = base
        var qualified = (scope + [partial]).joined(separator: ".")
        var suffix = 2
        while usedFieldNames.contains(qualified) {
            partial = "\(base)#\(suffix)"
            qualified = (scope + [partial]).joined(separator: ".")
            suffix += 1
        }
        usedFieldNames.insert(qualified)

        let options = Self.options(element.props["options"])
        let multiSelect = type == .listBox && element.bool("multiSelect") == true
        let valueProp = type == .checkbox ? "checked" : "value"
        var info = PDFFormFieldInfo(
            name: qualified, type: type,
            value: Self.normalizedValue(element.props[valueProp], type: type, multiSelect: multiSelect),
            pointer: element.pointers[valueProp],
            options: type == .textInput || type == .checkbox ? [] : options,
            isRequired: element.bool("required") == true,
            isReadOnly: element.bool("readOnly") == true,
            allowsMultipleSelection: multiSelect,
            isEditable: type == .select && element.bool("editable") == true,
            maxLength: type == .textInput ? element.number("maxLength", in: 1...100_000).map { Int($0) } : nil,
            exportValue: type == .checkbox ? (element.string("exportValue").flatMap { $0.isEmpty ? nil : $0 } ?? "Yes") : nil
        )
        if type == .listBox, info.options.isEmpty == false, case .array? = info.value, !multiSelect { info.value = nil }
        var field = FormFieldModel(
            id: form.fields.count, info: info, partialName: partial, parent: fieldSetStack.last,
            label: element.string("label").map { EmojiStripper.strip($0) }
        )
        field.multiline = element.bool("multiline") == true
        field.password = element.bool("password") == true
        field.alignment = alignment(element.string("align"))
        field.fontSize = element.number("fontSize", in: 4...72)
        field.lines = switch type {
        case .textInput: field.multiline ? Int(element.number("lines", in: 1...40) ?? 3) : 1
        case .listBox: Int(element.number("rows", in: 1...40) ?? CGFloat(min(max(options.count, 1), 6)))
        default: 1
        }
        field.direction = element.string("direction") == "horizontal" ? .row : .column
        form.fields.append(field)
        return field
    }

    static func fieldName(_ element: ResolvedElement) -> String {
        let name = element.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (element.key.isEmpty ? "field" : element.key) : name
    }

    static func options(_ json: JSONValue?) -> [PDFFormOption] {
        var seen: Set<String> = []
        return (json?.arrayValue ?? []).compactMap { option in
            let value: String
            switch option["value"] {
            case .string(let string)?: value = string
            case .number?: value = option["value"]!.javaScriptString
            default: return nil
            }
            guard seen.insert(value).inserted else { return nil }
            let label = option["label"].flatMap { $0 == .null ? nil : ($0.stringValue ?? $0.javaScriptString) } ?? value
            return PDFFormOption(label: label, value: value)
        }
    }

    /// Text/radio/select: non-empty string (numbers stringified) or `nil`; checkbox:
    /// `checked === true`; list box: `[String]` when multi-select, else a string.
    static func normalizedValue(_ value: JSONValue?, type: PDFFormFieldType, multiSelect: Bool) -> JSONValue? {
        func string(_ value: JSONValue?) -> String? {
            switch value {
            case .string(let string)?: string.isEmpty ? nil : string
            case .number?, .bool?: value!.javaScriptString
            default: nil
            }
        }
        switch type {
        case .checkbox:
            return .bool(value == .bool(true))
        case .listBox where multiSelect:
            let items = value?.arrayValue.map { $0.compactMap(string) } ?? string(value).map { [$0] } ?? []
            return .array(items.map(JSONValue.string))
        case .listBox:
            if let first = value?.arrayValue?.first { return string(first).map(JSONValue.string) }
            return string(value).map(JSONValue.string)
        default:
            return string(value).map(JSONValue.string)
        }
    }
}
