import CoreGraphics
import Foundation
import JSONRenderSwiftUI

/// Reads the values of a filled PDF form back into JSON.
///
/// ```swift
/// let reader = try PDFFormReader(data: filledPDF)
/// let values = reader.values(for: result.formFields)          // validated against the render
/// let updates = PDFFormReader.stateUpdates(values, fields: result.formFields)
/// for update in updates { session.store.set(update.value, at: update.pointer) }
/// ```
///
/// Fields are found through the catalog's `/AcroForm` field tree and, for files whose
/// tree was dropped by an editor, through the pages' widget annotations. Values map to
/// JSON as text → string, checkbox → bool, radio/select → export value, multi-select
/// list → `[String]`.
///
/// The PDF is untrusted input. Traversal shares one operation budget across the field
/// tree, kid arrays and page annotations (plus depth and string-length limits), so a
/// small malicious file cannot cause unbounded work. ``values(for:)`` keeps only known
/// field names whose stored value has the expected PDF type: a checkbox must be on with
/// its own export state (or off), radio/choice tokens must be options, and text is cut to
/// the field's `maxLength`. Invalid values are dropped, never turned into a clearing value.
public struct PDFFormReader: Sendable {
    public enum ReadError: Error, Sendable {
        /// Not a readable PDF (or encrypted).
        case unreadable
    }

    /// A field's stored value, typed as found in the PDF.
    enum RawEntry: Sendable, Equatable {
        case text(String)
        /// Checkbox: the "on" state name, or `nil` when off.
        case checkbox(String?)
        /// Radio group: the selected state name, or `nil` when none is selected.
        case radio(String?)
        case choice([String], multiple: Bool)
        /// Present but of an unexpected type (e.g. a number as text value).
        case invalid
    }

    /// Raw values by fully qualified field name (unexpected value types are omitted).
    public let rawValues: [String: JSONValue]
    let entries: [String: RawEntry]

    static let maxDepth = 32
    static let maxStringLength = 100_000
    /// Operations (nodes visited, array entries and annotations inspected) per read.
    static let operationBudget = 200_000

    public init(data: Data) throws {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              !document.isEncrypted || document.isUnlocked else { throw ReadError.unreadable }
        var collector = Collector()
        collector.readTree(document)
        collector.readAnnotations(document)
        entries = collector.entries
        rawValues = collector.entries.compactMapValues(Self.json)
    }

    /// Every field's value, unvalidated.
    public func values() -> [String: JSONValue] { rawValues }

    /// Values of the given fields only, validated against their type, options and length.
    public func values(for fields: [PDFFormFieldInfo]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for field in fields {
            guard let entry = entries[field.name], let value = Self.validate(entry, for: field) else { continue }
            result[field.name] = value
        }
        return result
    }

    /// `(pointer, value)` pairs for fields bound to state, ready to write into a store.
    public static func stateUpdates(_ values: [String: JSONValue], fields: [PDFFormFieldInfo]) -> [(pointer: String, value: JSONValue)] {
        fields.compactMap { field in
            guard let pointer = field.pointer, let value = values[field.name] else { return nil }
            return (pointer, value)
        }
    }

    static func json(_ entry: RawEntry) -> JSONValue? {
        switch entry {
        case .text(let text): .string(text)
        case .checkbox(let on): .bool(on != nil)
        case .radio(let token): token.map(JSONValue.string) ?? .null
        case .choice(let items, let multiple): multiple ? .array(items.map(JSONValue.string)) : (items.first.map(JSONValue.string) ?? .null)
        case .invalid: nil
        }
    }

    static func validate(_ entry: RawEntry, for field: PDFFormFieldInfo) -> JSONValue? {
        switch (field.type, entry) {
        case (.textInput, .text(var text)):
            let limit = min(field.maxLength ?? maxStringLength, maxStringLength)
            if text.count > limit { text = String(text.prefix(limit)) }
            return .string(text)
        case (.checkbox, .checkbox(let on)):
            guard let on else { return .bool(false) }
            return on == ButtonStates.checkboxOn(field.exportValue) ? .bool(true) : nil
        case (.radioGroup, .radio(let token?)):
            let names = ButtonStates.names(for: field.options.map(\.value))
            return names.firstIndex(of: token).map { .string(field.options[$0].value) }
        case (.select, .choice(let items, _)):
            guard items.count == 1, let token = items.first else { return nil }
            if field.options.contains(where: { $0.value == token }) { return .string(token) }
            return field.isEditable && token.count <= maxStringLength ? .string(token) : Optional<JSONValue>.none
        case (.listBox, .choice(let items, _)):
            let tokens = Set(field.options.map(\.value))
            guard items.allSatisfy(tokens.contains) else { return nil }
            if field.allowsMultipleSelection { return .array(items.map(JSONValue.string)) }
            guard items.count <= 1 else { return nil }
            return items.first.map(JSONValue.string)
        default:
            return nil
        }
    }

    // MARK: Traversal

    private struct Collector {
        var entries: [String: RawEntry] = [:]
        var visited: Set<Int> = []
        var budget = PDFFormReader.operationBudget

        /// Spends one unit of work; `false` once the budget is exhausted.
        mutating func spend() -> Bool {
            guard budget > 0 else { return false }
            budget -= 1
            return true
        }

        mutating func readTree(_ document: CGPDFDocument) {
            guard let catalog = document.catalog, let acroForm = PDFDict(catalog)?.dict("AcroForm"),
                  let fields = acroForm.array("Fields") else { return }
            for index in 0..<fields.count {
                guard spend() else { return }
                if let field = fields.dict(at: index) { visit(field, prefix: nil, inherited: Inherited(), depth: 0) }
            }
        }

        /// Widgets not reachable from `/AcroForm` (e.g. after an editor dropped the tree).
        mutating func readAnnotations(_ document: CGPDFDocument) {
            guard document.numberOfPages > 0 else { return }
            for number in 1...document.numberOfPages {
                guard spend() else { return }
                guard let pageDict = document.page(at: number)?.dictionary, let annots = PDFDict(pageDict)?.array("Annots") else { continue }
                for index in 0..<annots.count {
                    guard spend() else { return }
                    guard let widget = annots.dict(at: index), widget.name("Subtype") == "Widget" else { continue }
                    // Climb to the top of the field hierarchy, then visit from there.
                    var top = widget
                    var depth = 0
                    while let parent = top.dict("Parent"), depth < PDFFormReader.maxDepth, spend() {
                        top = parent
                        depth += 1
                    }
                    visit(top, prefix: nil, inherited: Inherited(), depth: 0)
                }
            }
        }

        struct Inherited {
            var type: String?
            var flags = 0
            var value: PDFValue?
        }

        mutating func visit(_ node: PDFDict, prefix: String?, inherited: Inherited, depth: Int) {
            guard depth < PDFFormReader.maxDepth, spend(), visited.insert(node.identity).inserted else { return }
            let partial = node.text("T")
            let name = [prefix, partial].compactMap { $0 }.joined(separator: ".")
            var context = inherited
            if let type = node.name("FT") { context.type = type }
            if let flags = node.int("Ff") { context.flags = flags }
            if let value = node.value("V") { context.value = value }

            // Kids that are fields (have /T) make this a non-terminal node; kids without /T are widgets.
            var widgets: [PDFDict] = []
            var fieldKids: [PDFDict] = []
            if let kids = node.array("Kids") {
                for index in 0..<kids.count {
                    guard spend() else { break }
                    guard let kid = kids.dict(at: index) else { continue }
                    if kid.text("T") != nil { fieldKids.append(kid) } else { widgets.append(kid) }
                }
            }
            if !fieldKids.isEmpty {
                // A non-terminal field (FieldSet): only its descendants carry values.
                for kid in fieldKids { visit(kid, prefix: name.isEmpty ? nil : name, inherited: context, depth: depth + 1) }
                return
            }
            guard !name.isEmpty, entries[name] == nil, let entry = terminalEntry(node, widgets: widgets, context: context) else { return }
            entries[name] = entry
        }

        func terminalEntry(_ node: PDFDict, widgets: [PDFDict], context: Inherited) -> RawEntry? {
            switch context.type {
            case "Tx":
                switch context.value {
                case nil: return .text("")
                case .text(let text)?: return .text(String(text.prefix(PDFFormReader.maxStringLength)))
                default: return .invalid
                }
            case "Btn":
                // State precedence: /V (as a name or, as PDFKit writes after an edit, a
                // string — on the widget for radio kids), then the widgets' /AS.
                func token(_ value: PDFValue?) -> String? {
                    switch value {
                    case .name(let name)?: name
                    case .text(let text)?: text
                    default: nil
                    }
                }
                let states = ([node] + widgets).compactMap { $0.name("AS") }
                // Some editors (PDFKit before OS 27) move /Ff from the radio parent to its kids.
                let flags = widgets.compactMap { $0.int("Ff") }.reduce(context.flags, |)
                if flags & 65536 != 0 { return nil } // push button
                func on(_ token: String?) -> String? {
                    guard let token, token != ButtonStates.off, !token.isEmpty else { return nil }
                    return token
                }
                if flags & AcroFormWriter.Flag.radio != 0 {
                    let kidValues = widgets.compactMap { token($0.value("V")) }
                    if !kidValues.isEmpty { return .radio(kidValues.lazy.compactMap(on).first) }
                    if let value = context.value {
                        guard let value = token(value) else { return .invalid }
                        return .radio(on(value))
                    }
                    return .radio(states.lazy.compactMap(on).first)
                }
                if let value = context.value {
                    guard let value = token(value) else { return .invalid }
                    return .checkbox(on(value))
                }
                return .checkbox(states.lazy.compactMap(on).first)
            case "Ch":
                let multiple = context.flags & AcroFormWriter.Flag.multiSelect != 0
                switch context.value {
                case nil: return .choice([], multiple: multiple)
                case .text(let text)?: return .choice([text], multiple: multiple)
                case .texts(let items)?: return .choice(items, multiple: multiple)
                default: return .invalid
                }
            default:
                return nil
            }
        }
    }
}

/// A field value as stored in the PDF.
enum PDFValue {
    case text(String)
    case texts([String])
    case name(String)
    /// Present with another type (number, dictionary, an array of non-strings, ...).
    case other
}

/// Safe accessors over a `CGPDFDictionaryRef`.
struct PDFDict {
    let ref: CGPDFDictionaryRef

    init?(_ ref: CGPDFDictionaryRef?) {
        guard let ref else { return nil }
        self.ref = ref
    }

    var identity: Int { unsafeBitCast(ref, to: Int.self) }

    func dict(_ key: String) -> PDFDict? {
        var value: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(ref, key, &value) ? PDFDict(value) : nil
    }

    func array(_ key: String) -> PDFArray? {
        var value: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(ref, key, &value) ? value.map(PDFArray.init) : nil
    }

    func name(_ key: String) -> String? {
        var value: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(ref, key, &value), let value else { return nil }
        return String(cString: value)
    }

    func int(_ key: String) -> Int? {
        var value: CGPDFInteger = 0
        return CGPDFDictionaryGetInteger(ref, key, &value) ? Int(value) : nil
    }

    func text(_ key: String) -> String? {
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(ref, key, &value), let value,
              let string = CGPDFStringCopyTextString(value) as String? else { return nil }
        return String(string.prefix(PDFFormReader.maxStringLength))
    }

    /// The value under `key`; `nil` when absent or `null`.
    func value(_ key: String) -> PDFValue? {
        if let text = text(key) { return .text(text) }
        if let name = name(key) { return .name(name) }
        if let array = array(key) {
            var items: [String] = []
            for index in 0..<min(array.count, 1_000) {
                var string: CGPDFStringRef?
                guard CGPDFArrayGetString(array.ref, index, &string), let string,
                      let text = CGPDFStringCopyTextString(string) as String? else { return .other }
                items.append(String(text.prefix(PDFFormReader.maxStringLength)))
            }
            return .texts(items)
        }
        var object: CGPDFObjectRef?
        guard CGPDFDictionaryGetObject(ref, key, &object), let object, CGPDFObjectGetType(object) != .null else { return nil }
        return .other
    }
}

struct PDFArray {
    let ref: CGPDFArrayRef

    var count: Int { CGPDFArrayGetCount(ref) }

    func dict(at index: Int) -> PDFDict? {
        var value: CGPDFDictionaryRef?
        return CGPDFArrayGetDictionary(ref, index, &value) ? PDFDict(value) : nil
    }
}
