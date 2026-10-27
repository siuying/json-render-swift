import Foundation
import JSONRenderSwiftUI

/// Maps a SwiftUI form spec to a fillable PDF form spec (PDF catalog), seeded with the
/// submitted values.
///
/// | SwiftUI | PDF |
/// |---|---|
/// | `TextField` (multiline) | `TextInput` (`multiline`, `lines`) |
/// | `SecureField` | `TextInput` with `password` (never seeded) |
/// | `Toggle` | `Checkbox` |
/// | `Picker` segmented / inline / wheel | `RadioGroup` |
/// | `Picker` menu / navigationLink / default | `Select` |
/// | `DatePicker` | `TextInput` with a format hint |
/// | `Stepper`, `Slider` | `TextInput` |
/// | `Section` | `FieldSet` + `Heading` (+ footer `Text`) |
/// | `Text`, `LabeledContent` | `Text` |
/// | `BarChart`, `LineChart` | the same chart, with its data resolved |
///
/// Hidden elements and buttons are omitted.
struct FillablePDFMapper {
    let form: Spec
    /// The data the `submit` action sent (values are looked up here first).
    let data: JSONValue
    /// The state pointer `data` was read from (see ``SubmissionSummary/dataRoot(in:data:state:)``).
    let dataRoot: String?
    /// Live state: visibility, labels, options, and values of fields that weren't submitted.
    let state: JSONValue
    var timeZone: TimeZone = .current

    private var elements: [String: JSONValue] = [:]
    private var usedNames: Set<String> = []
    private var visited: Set<String> = []

    init(form: Spec, data: JSONValue, dataRoot: String?, state: JSONValue, timeZone: TimeZone = .current) {
        self.form = form
        self.data = data
        self.dataRoot = dataRoot
        self.state = state
        self.timeZone = timeZone
    }

    static func spec(form: Spec, data: JSONValue, dataRoot: String?, state: JSONValue, timeZone: TimeZone = .current) -> Spec {
        var mapper = FillablePDFMapper(form: form, data: data, dataRoot: dataRoot, state: state, timeZone: timeZone)
        return mapper.build()
    }

    // MARK: Document

    private mutating func build() -> Spec {
        let root = form.rootElement
        let title = SubmissionSummary.label(root?.props["title"], state: state) ?? "Form"
        var page: [String] = ["title"]
        add("title", "Heading", ["text": .string(title), "level": "h1", "color": "#111827"])
        if let subtitle = SubmissionSummary.label(root?.props["subtitle"], state: state) {
            add("subtitle", "Text", ["text": .string(subtitle), "fontSize": 11, "color": "#4b5563"])
            page.append("subtitle")
        }
        add("divider", "Divider", ["color": "#d1d5db", "thickness": 1, "marginTop": 8, "marginBottom": 10])
        page.append("divider")
        if let rootKey = form.root, let element = form.elements[rootKey] {
            page += element.type == "Form" ? element.children.flatMap { map($0) } : map(rootKey)
        }
        add("page-number", "PageNumber", [
            "format": "Page {pageNumber} of {totalPages}", "fontSize": 9, "color": "#9ca3af", "align": "center",
        ])
        page.append("page-number")
        add("page", "Page", [
            "size": "A4", "orientation": "portrait",
            "marginTop": 48, "marginBottom": 48, "marginLeft": 50, "marginRight": 50,
        ], children: page)
        add("doc", "Document", ["title": .string(title), "subject": "Fillable form"], children: ["page"])
        return Spec(json: ["root": "doc", "elements": .object(elements)])
    }

    // MARK: Elements

    /// PDF element keys for a SwiftUI element (empty when hidden or not mapped).
    private mutating func map(_ key: String) -> [String] {
        guard visited.insert(key).inserted, let element = form.elements[key],
              Visibility.evaluate(element.visible, state: state) else { return [] }
        let props = element.props
        let id = "f-\(key)"
        switch element.type {
        case "Form":
            return element.children.flatMap { map($0) }
        case "Section":
            var children: [String] = []
            if let header = text(props["header"]) {
                add("\(id)-header", "Heading", ["text": .string(header), "level": "h3", "color": "#111827"])
                children.append("\(id)-header")
            }
            children += element.children.flatMap { map($0) }
            if let footer = text(props["footer"]) {
                add("\(id)-footer", "Text", ["text": .string(footer), "fontSize": 9, "color": "#6b7280"])
                children.append("\(id)-footer")
            }
            guard !children.isEmpty else { return [] }
            add("\(id)-body", "Column", ["gap": 8], children: children)
            add(id, "FieldSet", ["name": .string(uniqueName(key))], children: ["\(id)-body"])
            add("\(id)-gap", "Spacer", ["height": 14])
            return [id, "\(id)-gap"]
        case "VStack", "HStack":
            let children = element.children.flatMap { map($0) }
            guard !children.isEmpty else { return [] }
            add(id, "Column", ["gap": 8], children: children)
            return [id]
        case "Text":
            guard let content = text(props["content"]) else { return [] }
            let style = props["style"]?.stringValue
            let isHeadline = ["largeTitle", "title", "title2", "headline"].contains(style)
            add(id, "Text", [
                "text": .string(content),
                "fontSize": isHeadline ? 12 : (style == "caption" || style == "footnote" ? 9 : 10),
                "fontWeight": isHeadline ? "bold" : .null,
                "color": style == "caption" || style == "footnote" ? "#6b7280" : "#111827",
            ])
            return [id]
        case "LabeledContent":
            let label = text(props["label"]) ?? ""
            let value = text(props["value"]).map { ": \($0)" } ?? ""
            add(id, "Text", ["text": .string(label + value), "fontSize": 10, "color": "#111827"])
            return [id]
        case "Divider":
            add(id, "Divider", ["color": "#e5e7eb", "thickness": 1, "marginTop": 4, "marginBottom": 4])
            return [id]
        case "Button":
            return []
        case "BarChart", "LineChart":
            // The PDF spec has no state: inline the resolved records.
            var chart = Expressions.resolveProps(props, state: state)
            chart["data"] = .array(ChartData.records(from: chart["data"]))
            add(id, element.type, chart)
            return [id]
        default:
            if let field = field(element, key: key) {
                add(id, field.type, field.props)
                return [id]
            }
            return element.children.flatMap { map($0) }
        }
    }

    // MARK: Fields

    private mutating func field(_ element: Element, key: String) -> (type: String, props: [String: JSONValue])? {
        let props = element.props
        let bindings = Expressions.bindings(in: props)
        let label = SubmissionSummary.label(props["label"], state: state) ?? key
        let checks = element.validationConfig?.checks ?? []
        let isRequired = checks.contains { $0.type == "required" }

        func value(_ prop: String) -> JSONValue? {
            guard let pointer = bindings[prop] else { return Expressions.resolve(props[prop], state: state) }
            let submitted = dataRoot.flatMap { SubmissionSummary.submittedValue(at: pointer, in: data, root: $0) }
            return submitted ?? state.value(at: pointer)
        }
        func name(_ prop: String) -> String {
            uniqueName(bindings[prop].flatMap { $0.split(separator: "/").last.map(String.init) } ?? key)
        }

        switch element.type {
        case "TextField":
            let multiline = props["multiline"]?.boolValue == true
            let maxLength = checks.first { $0.type == "maxLength" }?.args["max"]?.intValue
            return ("TextInput", [
                "name": .string(name("value")), "label": .string(label),
                "value": stringValue(value("value")).map(JSONValue.string) ?? .null,
                "placeholder": text(props["placeholder"]).map(JSONValue.string) ?? .null,
                "required": .bool(isRequired),
                "maxLength": maxLength.map { .number(Double($0)) } ?? .null,
                "multiline": .bool(multiline),
                "lines": multiline ? .number(Double(min(max(props["lineLimit"]?.intValue ?? 3, 2), 8))) : .null,
            ])
        case "SecureField":
            // Secrets are never written into the file.
            return ("TextInput", [
                "name": .string(name("value")), "label": .string(label),
                "required": .bool(isRequired), "password": true,
            ])
        case "Toggle":
            let mustBeOn = checks.contains { $0.type == "matches" && $0.args["other"] == .bool(true) }
            return ("Checkbox", [
                "name": .string(name("isOn")), "label": .string(label),
                "checked": .bool(value("isOn")?.boolValue == true),
                "required": .bool(isRequired || mustBeOn),
            ])
        case "Picker":
            let options = (Expressions.resolve(props["options"], state: state)?.arrayValue ?? []).compactMap { option -> JSONValue? in
                guard let token = option["value"].flatMap(stringValue) else { return nil }
                let optionLabel = option["label"].flatMap(stringValue) ?? token
                return ["label": .string(optionLabel), "value": .string(token)]
            }
            let tokens = Set(options.compactMap { $0["value"]?.stringValue })
            let selected = stringValue(value("selection")).flatMap { tokens.contains($0) ? JSONValue.string($0) : nil } ?? .null
            let style = props["style"]?.stringValue
            var mapped: [String: JSONValue] = [
                "name": .string(name("selection")), "label": .string(label),
                "options": .array(options), "value": selected, "required": .bool(isRequired),
            ]
            if ["segmented", "inline", "wheel"].contains(style) {
                // Vertical: the renderer can mis-wrap short labels ("Yes") in horizontal groups.
                mapped["direction"] = "vertical"
                return ("RadioGroup", mapped)
            }
            return ("Select", mapped)
        case "DatePicker":
            let components = props["components"]?.stringValue ?? "date"
            let hint = switch components {
            case "hourAndMinute": "HH:MM"
            case "dateAndTime": "YYYY-MM-DD HH:MM"
            default: "YYYY-MM-DD"
            }
            return ("TextInput", [
                "name": .string(name("selection")), "label": .string("\(label) (\(hint))"),
                "value": stringValue(value("selection")).flatMap { formatDate($0, components: components) }.map(JSONValue.string) ?? .null,
                "required": .bool(isRequired), "maxLength": .number(Double(hint.count)), "width": 160,
            ])
        case "Stepper", "Slider":
            let range = [props["minimum"], props["maximum"]].compactMap { $0?.doubleValue }
            return ("TextInput", [
                "name": .string(name("value")), "label": .string(label),
                "value": stringValue(value("value")).map(JSONValue.string) ?? .null,
                "placeholder": range.count == 2 ? .string("\(JSONValue.number(range[0]))–\(JSONValue.number(range[1]))") : .null,
                "required": .bool(isRequired), "align": "right", "width": 120,
            ])
        default:
            return nil
        }
    }

    // MARK: Helpers

    /// Adds an element with every prop of its catalog entry present (`null` when unset),
    /// because the PDF catalog's props are required-but-nullable.
    private mutating func add(_ key: String, _ type: String, _ props: [String: JSONValue], children: [String] = []) {
        var full: [String: JSONValue] = [:]
        for prop in Self.catalogProps[type] ?? [] { full[prop] = .null }
        full.merge(props) { _, new in new }
        elements[key] = ["type": .string(type), "props": .object(full), "children": .array(children.map(JSONValue.string))]
    }

    /// A field name unique in the document, made of letters, digits, `_` and `-`.
    private mutating func uniqueName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        var base = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        if base.isEmpty { base = "field" }
        var name = base
        var index = 2
        while !usedNames.insert(name).inserted {
            name = "\(base)\(index)"
            index += 1
        }
        return name
    }

    private func text(_ value: JSONValue?) -> String? {
        guard let resolved = Expressions.resolve(value, state: state).flatMap(stringValue), !resolved.isEmpty else { return nil }
        return resolved
    }

    /// Strings as-is, numbers and booleans as JavaScript would print them.
    private func stringValue(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let string)?: string
        case let other? where other.doubleValue != nil || other.boolValue != nil: other.jsonString()
        default: nil
        }
    }

    private func formatDate(_ iso: String, components: String) -> String? {
        if components == "date" { return iso.count >= 10 ? String(iso.prefix(10)) : nil }
        guard let date = try? Date.ISO8601FormatStyle().parse(iso) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = components == "hourAndMinute" ? "HH:mm" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Every prop of the PDF catalog components this mapper emits.
    static let catalogProps: [String: [String]] = [
        "Document": ["title", "author", "subject"],
        "Page": ["size", "orientation", "marginTop", "marginBottom", "marginLeft", "marginRight", "backgroundColor"],
        "Heading": ["text", "level", "color", "align"],
        "Text": ["text", "fontSize", "color", "align", "fontWeight", "fontStyle", "lineHeight"],
        "Column": ["gap", "alignItems", "justifyContent", "padding", "flex"],
        "Divider": ["color", "thickness", "marginTop", "marginBottom"],
        "Spacer": ["height"],
        "PageNumber": ["format", "fontSize", "color", "align"],
        "BarChart": ["title", "data", "xKey", "yKey", "aggregate", "color", "height"],
        "LineChart": ["title", "data", "xKey", "yKey", "aggregate", "color", "height"],
        "FieldSet": ["name", "label"],
        "TextInput": [
            "name", "label", "value", "placeholder", "required", "readOnly", "maxLength", "multiline", "lines",
            "password", "align", "fontSize", "width",
        ],
        "Checkbox": ["name", "label", "checked", "required", "readOnly", "exportValue"],
        "RadioGroup": ["name", "label", "options", "value", "direction", "required", "readOnly"],
        "Select": ["name", "label", "options", "value", "editable", "required", "readOnly", "width"],
    ]
}
