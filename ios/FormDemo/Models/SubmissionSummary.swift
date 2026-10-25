import Foundation
import JSONRenderSwiftUI

/// Builds a PDF document spec that summarises a submitted form: the form's title, the
/// submission date, one table row per submitted visible field (label → value) and page numbers.
///
/// Values come from the data the `submit` action sent, resolved exactly against the state
/// pointer that data came from (`dataRoot`, e.g. `/form` for `{"data": {"$state": "/form"}}`).
/// Fields outside that subtree weren't submitted and are left out. When the root is unknown,
/// the live state (which the action read its data from) is used. The live state also drives
/// visibility, labels and picker option lookup.
enum SubmissionSummary {
    /// Input types whose bound value is reported, with the prop holding the binding.
    private static let valueProps: [String: String] = [
        "TextField": "value", "SecureField": "value", "Stepper": "value", "Slider": "value",
        "Toggle": "isOn", "Picker": "selection", "DatePicker": "selection",
    ]

    struct Row: Equatable {
        var label: String
        var value: String
    }

    static func spec(form: Spec, data: JSONValue, dataRoot: String?, state: JSONValue, submittedAt date: Date) -> Spec {
        let root = form.rootElement
        let title = text(root?.props["title"], state: state) ?? "Form Submission"
        let subtitle = text(root?.props["subtitle"], state: state)
        let rows = rows(in: form, data: data, dataRoot: dataRoot, state: state)

        var elements: [String: JSONValue] = [
            "doc": element("Document", ["title": .string(title), "author": "Form Demo"], children: ["page"]),
            "title": element("Heading", ["text": .string(title), "level": "h1", "color": "#1a202c"]),
            "gap": element("Spacer", ["height": 6]),
            "submitted": element("Text", [
                "text": .string("Submitted \(date.formatted(date: .long, time: .shortened))"),
                "fontSize": 10, "color": "#718096",
            ]),
            "divider": element("Divider", ["color": "#e2e8f0", "thickness": 1, "marginTop": 12, "marginBottom": 12]),
            "fields": element("Table", [
                "columns": [
                    ["header": "Field", "width": "40%", "align": "left"],
                    ["header": "Value", "width": "60%", "align": "left"],
                ],
                "rows": .array(rows.map { [.string($0.label), .string($0.value)] }),
                "headerBackgroundColor": "#2d3748",
                "headerTextColor": "#ffffff",
                "borderColor": "#e2e8f0",
                "fontSize": 10,
                "striped": true,
            ]),
            "page-number": element("PageNumber", [
                "format": "Page {pageNumber} of {totalPages}", "fontSize": 9, "color": "#a0aec0", "align": "center",
            ]),
        ]
        var pageChildren: [String] = ["title"]
        if let subtitle {
            elements["subtitle"] = element("Text", ["text": .string(subtitle), "fontSize": 12, "color": "#4a5568"])
            pageChildren.append("subtitle")
        }
        pageChildren += ["gap", "submitted", "divider", "fields", "page-number"]
        elements["page"] = element("Page", [
            "size": "A4", "marginTop": 50, "marginBottom": 50, "marginLeft": 50, "marginRight": 50,
        ], children: pageChildren)

        return Spec(json: ["root": "doc", "elements": .object(elements)])
    }

    /// Visible input fields that were submitted, in document order, with display values.
    static func rows(in form: Spec, data: JSONValue, dataRoot: String?, state: JSONValue) -> [Row] {
        var rows: [Row] = []
        var visited: Set<String> = []
        func visit(_ key: String) {
            guard visited.insert(key).inserted, let element = form.elements[key],
                  Visibility.evaluate(element.visible, state: state) else { return }
            if let prop = valueProps[element.type],
               let pointer = Expressions.bindings(in: element.props)[prop] {
                let value = dataRoot.map { submittedValue(at: pointer, in: data, root: $0) } ?? state.value(at: pointer)
                if let value {
                    let label = label(element.props["label"], state: state) ?? key
                    rows.append(Row(label: label, value: display(value, for: element, state: state)))
                }
            }
            element.children.forEach(visit)
        }
        if let root = form.root { visit(root) }
        return rows
    }

    private static func display(_ value: JSONValue?, for element: Element, state: JSONValue) -> String {
        let empty = "—"
        switch (element.type, value) {
        case (_, nil), (_, .null?):
            return empty
        case ("SecureField", .string(let text)?):
            return text.isEmpty ? empty : "••••••••"
        case ("Toggle", .bool(let isOn)?):
            return isOn ? "Yes" : "No"
        case ("DatePicker", .string(let iso)?):
            return formattedDate(iso) ?? (iso.isEmpty ? empty : iso)
        case ("Picker", let selection?):
            let options = Expressions.resolve(element.props["options"], state: state)?.arrayValue ?? []
            if let option = options.first(where: { $0["value"] == selection }),
               let label = option["label"]?.stringValue {
                return label
            }
            return selection.stringValue.map { $0.isEmpty ? empty : $0 } ?? selection.jsonString()
        case (_, .string(let text)?):
            return text.isEmpty ? empty : text
        case (_, let other?):
            return other.jsonString()
        }
    }

    /// The value of the field bound to `pointer` in data read from the state at `root`
    /// (`""` = the whole state). `nil` when the field is outside `root` or absent.
    static func submittedValue(at pointer: String, in data: JSONValue, root: String) -> JSONValue? {
        if root.isEmpty { return data.value(at: pointer) }
        guard pointer == root || pointer.hasPrefix(root + "/") else { return nil }
        let relative = String(pointer.dropFirst(root.count))
        return relative.isEmpty ? data : data.value(at: relative)
    }

    /// The state pointer the submitted data was read from: the `$state` path of a `submit`
    /// binding's `data` param. With several submit bindings, the one whose current value
    /// equals `data`. `nil` when it can't be determined.
    static func dataRoot(in form: Spec, data: JSONValue, state: JSONValue) -> String? {
        var candidates: [String] = []
        for key in form.elements.keys.sorted() {
            guard let element = form.elements[key] else { continue }
            for binding in (element.on.values.flatMap { $0 } + element.watch.values.flatMap { $0 })
            where binding.action == "submit" {
                let source = binding.params["data"]
                if let path = (source?["$state"] ?? source?["$bindState"])?.stringValue, !candidates.contains(path) {
                    candidates.append(path)
                }
            }
        }
        if let match = candidates.first(where: { state.value(at: $0) == data }) { return match }
        if candidates.count == 1 { return candidates[0] }
        return data == state ? "" : nil
    }

    /// The label text. A `$template` label that ends with a placeholder usually shows the
    /// field's own value ("Guests: ${/form/guests}"), so that placeholder and the separator
    /// before it are dropped.
    static func label(_ value: JSONValue?, state: JSONValue) -> String? {
        if let template = value?["$template"]?.stringValue,
           template.hasSuffix("}"), let start = template.range(of: "${", options: .backwards) {
            let prefix = template[..<start.lowerBound]
            let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: ":-–—·|=").union(.whitespaces))
            if !trimmed.isEmpty, !trimmed.contains("${") { return trimmed }
        }
        return text(value, state: state)
    }

    /// `YYYY-MM-DD` as a long date; full ISO date-times as date and time (current time zone).
    static func formattedDate(_ iso: String) -> String? {
        if iso.count == 10 {
            var style = Date.ISO8601FormatStyle().year().month().day()
            style.timeZone = .gmt
            guard let date = try? style.parse(iso) else { return nil }
            var format = Date.FormatStyle(date: .long, time: .omitted)
            format.timeZone = .gmt
            return date.formatted(format)
        }
        guard let date = try? Date.ISO8601FormatStyle().parse(iso) else { return nil }
        return date.formatted(date: .long, time: .shortened)
    }

    private static func text(_ value: JSONValue?, state: JSONValue) -> String? {
        guard let text = Expressions.resolve(value, state: state)?.stringValue, !text.isEmpty else { return nil }
        return text
    }

    private static func element(_ type: String, _ props: [String: JSONValue], children: [String] = []) -> JSONValue {
        ["type": .string(type), "props": .object(props), "children": .array(children.map(JSONValue.string))]
    }
}
