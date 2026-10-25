import Foundation
import JSONRenderSwiftUI

/// The kind of a fillable field (named after its catalog component).
public enum PDFFormFieldType: String, Sendable, Hashable, CaseIterable {
    case textInput = "TextInput"
    case checkbox = "Checkbox"
    case radioGroup = "RadioGroup"
    case select = "Select"
    case listBox = "ListBox"
}

/// A choice of a `RadioGroup`, `Select` or `ListBox`.
public struct PDFFormOption: Sendable, Hashable {
    public var label: String
    /// The export value written to the PDF and read back.
    public var value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// A fillable field in a rendered PDF (``PDFRenderResult/formFields``), in document order.
public struct PDFFormFieldInfo: Sendable, Hashable {
    /// Fully qualified field name: enclosing `FieldSet` names and the field name joined
    /// with "."; repeated names get a `#2`, `#3`… suffix.
    public var name: String
    public var type: PDFFormFieldType
    /// The value written into the PDF: string (text, radio, select; `nil` when empty),
    /// bool (checkbox) or `[String]` (multi-select list).
    public var value: JSONValue?
    /// The state pointer the value is bound to (`$state` / `$bindState` / `$bindItem`), if any.
    public var pointer: String?
    /// Choices of radio groups, selects and list boxes.
    public var options: [PDFFormOption]
    public var isRequired: Bool
    public var isReadOnly: Bool
    /// List boxes that allow several selected values.
    public var allowsMultipleSelection: Bool
    /// Selects that accept free text.
    public var isEditable: Bool
    /// Maximum characters of a text input.
    public var maxLength: Int?
    /// The checkbox "on" export value (default `"Yes"`).
    public var exportValue: String?

    public init(
        name: String, type: PDFFormFieldType, value: JSONValue? = nil, pointer: String? = nil,
        options: [PDFFormOption] = [], isRequired: Bool = false, isReadOnly: Bool = false,
        allowsMultipleSelection: Bool = false, isEditable: Bool = false, maxLength: Int? = nil,
        exportValue: String? = nil
    ) {
        self.name = name
        self.type = type
        self.value = value
        self.pointer = pointer
        self.options = options
        self.isRequired = isRequired
        self.isReadOnly = isReadOnly
        self.allowsMultipleSelection = allowsMultipleSelection
        self.isEditable = isEditable
        self.maxLength = maxLength
        self.exportValue = exportValue
    }
}

/// Internal model of one field, with layout and writer details.
struct FormFieldModel: Sendable {
    var id: Int
    var info: PDFFormFieldInfo
    /// The field's own `/T` (last name component, with any duplicate suffix).
    var partialName: String
    /// Index of the enclosing FieldSet in ``FormModel/fieldSets``.
    var parent: Int?
    var label: String?
    var multiline = false
    var lines = 1
    var password = false
    var alignment = TextStyle.Alignment.left
    var fontSize: CGFloat?
    var direction = BoxStyle.Direction.column
}

/// A FieldSet: a non-terminal field that scopes names.
struct FormFieldSetModel: Sendable {
    var name: String
    var parent: Int?
}

/// Every field and FieldSet of a document.
struct FormModel: Sendable {
    var fields: [FormFieldModel] = []
    var fieldSets: [FormFieldSetModel] = []

    var isEmpty: Bool { fields.isEmpty }
}
