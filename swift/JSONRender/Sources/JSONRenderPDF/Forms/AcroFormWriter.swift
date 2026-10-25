import CoreGraphics
import Foundation
import JSONRenderSwiftUI

/// Adds a portable AcroForm to a Core Graphics-produced PDF with an incremental update.
///
/// PDFKit's `dataRepresentation()` writes widget annotations but no catalog `/AcroForm`,
/// field tree or radio parents, so forms are written here instead: the drawn PDF is kept
/// byte for byte and an update section is appended with the field/widget dictionaries,
/// appearance streams, the `/Helv` and `/ZaDb` fonts, a new catalog revision (with
/// `/AcroForm`), new revisions of pages that carry widgets (with `/Annots`), and an xref
/// section whose trailer points back with `/Prev`.
struct AcroFormWriter {
    let form: FormModel
    let placements: [FormWidgetPlacement]

    /// Field flag bits (PDF 32000-1 §12.7.3 / §12.7.4).
    enum Flag {
        static let readOnly = 1
        static let required = 2
        static let multiline = 4096
        static let password = 8192
        static let noToggleToOff = 16384
        static let radio = 32768
        static let combo = 131072
        static let edit = 262144
        static let multiSelect = 2097152
    }

    static let borderColor: PDFObject = .array([.real(0.612), .real(0.639), .real(0.686)])
    static let white: PDFObject = .array([.int(1), .int(1), .int(1)])

    struct Output {
        var data: Data
        /// IDs of the fields actually written (fields without a placed widget are omitted).
        var emittedFieldIDs: Set<Int>
    }

    func write(into base: Data) throws -> Output {
        let file = try PDFFileStructure(data: base)
        let pageNumbers = try file.pageNumbers()
        guard let (catalogNumber, _) = file.trailer["Root"]?.refValue else { throw PDFStructureError("no catalog") }

        var allocator = Allocator(next: file.size)
        var objects: [(Int, PDFObject)] = []
        let helv = allocator.take(), zadb = allocator.take()
        objects.append((helv, .dict([("Type", .name("Font")), ("Subtype", .name("Type1")),
                                     ("BaseFont", .name("Helvetica")), ("Encoding", .name("WinAnsiEncoding"))])))
        objects.append((zadb, .dict([("Type", .name("Font")), ("Subtype", .name("Type1")), ("BaseFont", .name("ZapfDingbats"))])))
        let fonts: PDFObject = .dict([("Helv", .ref(helv, 0)), ("ZaDb", .ref(zadb, 0))])
        let appearances = AppearanceBuilder(resources: .dict([("Font", fonts)]))

        // Placed widgets per field (first placement wins).
        var widgetsByField: [Int: [FormWidgetPlacement]] = [:]
        var seen: Set<FormWidgetRef> = []
        for placement in placements where placement.page < pageNumbers.count && seen.insert(placement.widget).inserted {
            widgetsByField[placement.widget.fieldID, default: []].append(placement)
        }

        // FieldSets with at least one placed descendant get a non-terminal field object.
        var fieldSetObjects: [Int: Int] = [:]
        func fieldSetObject(_ index: Int) -> Int {
            if let number = fieldSetObjects[index] { return number }
            let number = allocator.take()
            fieldSetObjects[index] = number
            if let parent = form.fieldSets[index].parent { _ = fieldSetObject(parent) }
            return number
        }
        var fieldSetKids: [Int: [PDFObject]] = [:]
        var topLevel: [PDFObject] = []
        var pageAnnots: [Int: [PDFObject]] = [:]
        var emitted: Set<Int> = []

        for field in form.fields {
            guard let widgets = widgetsByField[field.id], !widgets.isEmpty else { continue }
            let parentRef: PDFObject? = field.parent.map { .ref(fieldSetObject($0), 0) }
            let built = build(field, widgets: widgets, parent: parentRef, pages: pageNumbers, appearances: appearances, allocator: &allocator)
            objects += built.objects
            emitted.insert(field.id)
            for (page, annot) in built.annotations { pageAnnots[page, default: []].append(annot) }
            if let parent = field.parent {
                fieldSetKids[parent, default: []].append(.ref(built.fieldNumber, 0))
            } else {
                topLevel.append(.ref(built.fieldNumber, 0))
            }
        }
        guard !topLevel.isEmpty || !fieldSetObjects.isEmpty else {
            return Output(data: Self.repairingXref(base) ?? base, emittedFieldIDs: [])
        }

        for (index, number) in fieldSetObjects.sorted(by: { $0.key < $1.key }) {
            let set = form.fieldSets[index]
            let kids = fieldSetKids[index, default: []] + fieldSetObjects
                .filter { form.fieldSets[$0.key].parent == index }.sorted { $0.key < $1.key }.map { PDFObject.ref($0.value, 0) }
            objects.append((number, .dict([
                ("T", .text(set.name)), ("Kids", .array(kids)),
                ("Parent", set.parent.flatMap { fieldSetObjects[$0] }.map { .ref($0, 0) }),
            ])))
            if set.parent == nil { topLevel.append(.ref(number, 0)) }
        }

        let acroForm = allocator.take()
        objects.append((acroForm, .dict([
            ("Fields", .array(topLevel)),
            ("NeedAppearances", .bool(true)),
            ("DR", .dict([("Font", fonts)])),
            ("DA", .string(Array("/Helv 0 Tf 0 g".utf8))),
        ])))
        let catalog = try file.object(catalogNumber).setting("AcroForm", .ref(acroForm, 0))
        objects.append((catalogNumber, catalog))
        for (pageIndex, annots) in pageAnnots.sorted(by: { $0.key < $1.key }) {
            let number = pageNumbers[pageIndex]
            let page = try file.object(number)
            var existing: [PDFObject] = []
            if case .array(let items)? = try file.resolve(page["Annots"]) { existing = items }
            objects.append((number, page.setting("Annots", .array(existing + annots))))
        }
        let data = Self.appendUpdate(to: base, objects: objects, freed: file.unreferencedZeroOffsetObjects(), file: file, size: allocator.next)
        return Output(data: data, emittedFieldIDs: emitted)
    }

    /// For PDFs without a form: an update that only frees the xref slots Core Graphics
    /// marks in use at offset 0 (it does so on iOS after drawing CJK text), when the slots
    /// are provably unreferenced. `nil` when nothing needs repair or the file can't be read.
    static func repairingXref(_ base: Data) -> Data? {
        guard let file = try? PDFFileStructure(data: base) else { return nil }
        let freed = file.unreferencedZeroOffsetObjects()
        guard !freed.isEmpty else { return nil }
        return appendUpdate(to: base, objects: [], freed: freed, file: file, size: file.size)
    }

    // MARK: Fields

    private struct Allocator {
        var next: Int
        mutating func take() -> Int {
            defer { next += 1 }
            return next
        }
    }

    private struct BuiltField {
        var fieldNumber: Int
        var objects: [(Int, PDFObject)]
        var annotations: [(Int, PDFObject)]
    }

    private func build(
        _ field: FormFieldModel, widgets: [FormWidgetPlacement], parent: PDFObject?, pages: [Int],
        appearances: AppearanceBuilder, allocator: inout Allocator
    ) -> BuiltField {
        let info = field.info
        var flags = (info.isReadOnly ? Flag.readOnly : 0) | (info.isRequired ? Flag.required : 0)
        var objects: [(Int, PDFObject)] = []
        func widgetEntries(_ placement: FormWidgetPlacement) -> [(String, PDFObject?)] {
            let rect = placement.rect
            return [
                ("Type", .name("Annot")), ("Subtype", .name("Widget")),
                ("Rect", .rect([rect.minX, rect.minY, rect.maxX, rect.maxY])),
                ("F", .int(4)), ("P", .ref(pages[placement.page], 0)),
            ]
        }
        var fontSize = field.fontSize ?? 10
        if info.type == .listBox, let placement = widgets.first, !info.options.isEmpty {
            // Some viewers (PDFKit/Preview) draw every option without scrolling: size the
            // text so all options fit the box (rows ≈ 1.2 × font size), but not below 6 pt.
            let fitting = (placement.rect.height - 4) / (CGFloat(info.options.count) * AppearanceBuilder.listRowFactor)
            fontSize = max(6, min(fontSize, fitting))
        }
        let da: PDFObject = .string(Array("/Helv \(PDFObject.format(fontSize)) Tf 0 g".utf8))
        let tooltip = field.label.flatMap { $0.isEmpty ? nil : PDFObject.text($0) }

        switch info.type {
        case .radioGroup:
            flags |= Flag.radio | Flag.noToggleToOff
            let stateNames = ButtonStates.names(for: info.options.map(\.value))
            let selected = info.value?.stringValue.flatMap { value in info.options.firstIndex { $0.value == value } }
                .map { stateNames[$0] }
            let parentNumber = allocator.take()
            var kids: [PDFObject] = []
            var annotations: [(Int, PDFObject)] = []
            for placement in widgets {
                guard let index = placement.widget.option, info.options.indices.contains(index) else { continue }
                let token = stateNames[index]
                let number = allocator.take()
                let size = placement.rect.size
                let on = allocator.take(), off = allocator.take()
                objects.append((on, appearances.radio(size: size, on: true)))
                objects.append((off, appearances.radio(size: size, on: false)))
                objects.append((number, .dict(widgetEntries(placement) + [
                    ("Parent", .ref(parentNumber, 0)),
                    ("AS", .name(token == selected ? token : "Off")),
                    ("MK", .dict([("BC", Self.borderColor), ("BG", Self.white), ("CA", .string(Array("l".utf8)))])),
                    ("AP", .dict([("N", .dict([(token, .ref(on, 0)), ("Off", .ref(off, 0))]))])),
                    ("DA", .string(Array("/ZaDb 0 Tf 0 g".utf8))),
                ])))
                kids.append(.ref(number, 0))
                annotations.append((placement.page, .ref(number, 0)))
            }
            let value: PDFObject = .name(selected ?? "Off")
            objects.append((parentNumber, .dict([
                ("FT", .name("Btn")), ("T", .text(field.partialName)), ("TU", tooltip), ("Parent", parent),
                ("Ff", .int(flags)), ("V", value), ("DV", value), ("Kids", .array(kids)),
            ])))
            return BuiltField(fieldNumber: parentNumber, objects: objects, annotations: annotations)

        case .checkbox:
            let placement = widgets[0]
            let export = ButtonStates.checkboxOn(info.exportValue)
            let checked = info.value == .bool(true)
            let number = allocator.take(), on = allocator.take(), off = allocator.take()
            objects.append((on, appearances.checkbox(size: placement.rect.size, on: true)))
            objects.append((off, appearances.checkbox(size: placement.rect.size, on: false)))
            let state: PDFObject = .name(checked ? export : "Off")
            objects.append((number, .dict([
                ("FT", .name("Btn")), ("T", .text(field.partialName)), ("TU", tooltip), ("Parent", parent),
                ("Ff", flags == 0 ? nil : .int(flags)), ("V", state), ("DV", state), ("AS", state),
                ("MK", .dict([("BC", Self.borderColor), ("BG", Self.white), ("CA", .string(Array("4".utf8)))])),
                ("AP", .dict([("N", .dict([(export, .ref(on, 0)), ("Off", .ref(off, 0))]))])),
                ("DA", .string(Array("/ZaDb 0 Tf 0 g".utf8))),
            ] + widgetEntries(placement))))
            return BuiltField(fieldNumber: number, objects: objects, annotations: [(placement.page, .ref(number, 0))])

        case .textInput, .select, .listBox:
            let placement = widgets[0]
            let number = allocator.take(), appearance = allocator.take()
            var entries: [(String, PDFObject?)] = [("T", .text(field.partialName)), ("TU", tooltip), ("Parent", parent)]
            var value: PDFObject?
            switch info.type {
            case .textInput:
                if field.multiline { flags |= Flag.multiline }
                if field.password { flags |= Flag.password }
                value = info.value?.stringValue.map { .text($0) }
                entries += [("FT", .name("Tx")), ("MaxLen", info.maxLength.map { .int($0) }),
                            ("Q", .int(field.alignment == .center ? 1 : field.alignment == .right ? 2 : 0))]
                objects.append((appearance, appearances.text(field, size: placement.rect.size, fontSize: fontSize)))
            case .select:
                flags |= Flag.combo | (info.isEditable ? Flag.edit : 0)
                value = info.value?.stringValue.map { .text($0) }
                entries += [("FT", .name("Ch")), ("Opt", Self.options(info.options)),
                            ("I", info.value?.stringValue.flatMap { v in info.options.firstIndex { $0.value == v } }.map { .array([.int($0)]) })]
                objects.append((appearance, appearances.select(field, size: placement.rect.size, fontSize: fontSize)))
            default:
                if info.allowsMultipleSelection { flags |= Flag.multiSelect }
                let selected = Self.selectedValues(info)
                let indices = info.options.indices.filter { selected.contains(info.options[$0].value) }
                value = info.allowsMultipleSelection
                    ? (selected.isEmpty ? nil : .array(selected.map { .text($0) }))
                    : selected.first.map { .text($0) }
                entries += [("FT", .name("Ch")), ("Opt", Self.options(info.options)),
                            ("I", indices.isEmpty ? nil : .array(indices.map { .int($0) }))]
                objects.append((appearance, appearances.list(field, size: placement.rect.size, fontSize: fontSize)))
            }
            entries += [("Ff", flags == 0 ? nil : .int(flags)), ("V", value), ("DV", value), ("DA", da),
                        ("MK", .dict([("BC", Self.borderColor), ("BG", Self.white)])),
                        ("AP", .dict([("N", .ref(appearance, 0))]))]
            objects.append((number, .dict(entries + widgetEntries(placement))))
            return BuiltField(fieldNumber: number, objects: objects, annotations: [(placement.page, .ref(number, 0))])
        }
    }

    static func options(_ options: [PDFFormOption]) -> PDFObject {
        .array(options.map { .array([.text($0.value), .text($0.label)]) })
    }

    static func selectedValues(_ info: PDFFormFieldInfo) -> [String] {
        switch info.value {
        case .array(let items)?: items.compactMap(\.stringValue)
        case .string(let value)?: [value]
        default: []
        }
    }

    // MARK: Update section

    static func appendUpdate(
        to base: Data, objects: [(Int, PDFObject)], freed: [Int], file: PDFFileStructure, size: Int
    ) -> Data {
        var out = Array(base)
        if out.last != 10 { out.append(10) }
        var offsets: [Int: Int] = [:]
        for (number, object) in objects.sorted(by: { $0.0 < $1.0 }) {
            offsets[number] = out.count
            out += Array("\(number) 0 obj\n".utf8)
            object.write(to: &out)
            out += Array("\nendobj\n".utf8)
        }
        let xref = out.count
        // Free entries form a linked list starting at object 0.
        let free = freed.filter { offsets[$0] == nil }.sorted()
        var entries: [Int: String] = [0: String(format: "%010d 65535 f \n", free.first ?? 0)]
        for (index, number) in free.enumerated() {
            entries[number] = String(format: "%010d 00001 f \n", index + 1 < free.count ? free[index + 1] : 0)
        }
        for (number, offset) in offsets { entries[number] = String(format: "%010d 00000 n \n", offset) }
        out += Array("xref\n".utf8)
        let numbers = entries.keys.sorted()
        var index = 0
        while index < numbers.count {
            var end = index
            while end + 1 < numbers.count, numbers[end + 1] == numbers[end] + 1 { end += 1 }
            out += Array("\(numbers[index]) \(end - index + 1)\n".utf8)
            for number in numbers[index...end] { out += Array(entries[number]!.utf8) }
            index = end + 1
        }
        let trailer = PDFObject.dict([
            ("Size", .int(size)), ("Root", file.trailer["Root"]), ("Info", file.trailer["Info"]),
            ("ID", file.trailer["ID"]), ("Prev", .int(file.startXref)),
        ])
        out += Array("trailer\n".utf8)
        trailer.write(to: &out)
        out += Array("\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return Data(out)
    }
}

/// Appearance streams (Form XObjects) for widgets.
struct AppearanceBuilder {
    let resources: PDFObject
    /// List row height as a multiple of the font size.
    static let listRowFactor: CGFloat = 1.2

    func stream(_ size: CGSize, _ content: String) -> PDFObject {
        .stream([
            (Array("Type".utf8), .name("XObject")), (Array("Subtype".utf8), .name("Form")),
            (Array("BBox".utf8), .rect([0, 0, Double(size.width), Double(size.height)])),
            (Array("Resources".utf8), resources),
        ], Array(content.utf8))
    }

    /// ZapfDingbats check mark (✔, glyph "4") centred in the box.
    func checkbox(size: CGSize, on: Bool) -> PDFObject {
        guard on else { return stream(size, "q Q") } // non-empty: some editors drop empty streams
        let fontSize = min(size.width, size.height) * 0.8
        let x = (size.width - 0.846 * fontSize) / 2, y = (size.height - 0.692 * fontSize) / 2
        return stream(size, "q 0 g BT /ZaDb \(f(fontSize)) Tf \(f(x)) \(f(y)) Td (4) Tj ET Q")
    }

    /// A filled dot for the selected radio button.
    func radio(size: CGSize, on: Bool) -> PDFObject {
        guard on else { return stream(size, "q Q") } // non-empty: some editors drop empty streams
        let cx = size.width / 2, cy = size.height / 2, r = min(size.width, size.height) / 4, k = r * 0.5523
        let path = "\(f(cx + r)) \(f(cy)) m \(f(cx + r)) \(f(cy + k)) \(f(cx + k)) \(f(cy + r)) \(f(cx)) \(f(cy + r)) c "
            + "\(f(cx - k)) \(f(cy + r)) \(f(cx - r)) \(f(cy + k)) \(f(cx - r)) \(f(cy)) c "
            + "\(f(cx - r)) \(f(cy - k)) \(f(cx - k)) \(f(cy - r)) \(f(cx)) \(f(cy - r)) c "
            + "\(f(cx + k)) \(f(cy - r)) \(f(cx + r)) \(f(cy - k)) \(f(cx + r)) \(f(cy)) c f"
        return stream(size, "q 0 g \(path) Q")
    }

    /// Current value as text (wrapped when multiline, bullets for passwords).
    func text(_ field: FormFieldModel, size: CGSize, fontSize: CGFloat) -> PDFObject {
        var value = field.info.value?.stringValue ?? ""
        if field.password { value = String(repeating: "*", count: value.count) }
        let lines = field.multiline ? wrap(value, width: size.width - 4, fontSize: fontSize) : [value]
        return stream(size, textContent(lines, size: size, fontSize: fontSize, alignment: field.alignment, multiline: field.multiline))
    }

    /// The selected option's label (or the typed value of an editable select).
    func select(_ field: FormFieldModel, size: CGSize, fontSize: CGFloat) -> PDFObject {
        let value = field.info.value?.stringValue
        let label = field.info.options.first { $0.value == value }?.label ?? value ?? ""
        let text = textContent([label], size: CGSize(width: size.width - 14, height: size.height), fontSize: fontSize,
                               alignment: .left, multiline: false)
        // A small chevron marks the control as a drop-down.
        let x = size.width - 12, y = size.height / 2
        let chevron = " q 0.42 0.45 0.5 rg \(f(x)) \(f(y + 2)) m \(f(x + 7)) \(f(y + 2)) l \(f(x + 3.5)) \(f(y - 2.5)) l f Q"
        return stream(size, text + chevron)
    }

    /// Visible options, with selected rows highlighted.
    func list(_ field: FormFieldModel, size: CGSize, fontSize: CGFloat) -> PDFObject {
        let selected = Set(AcroFormWriter.selectedValues(field.info))
        let rowHeight = fontSize * Self.listRowFactor
        var content = "/Tx BMC q 1 1 \(f(size.width - 2)) \(f(size.height - 2)) re W n "
        for (index, option) in field.info.options.enumerated() {
            let top = size.height - 3 - CGFloat(index) * rowHeight
            guard top - rowHeight > -rowHeight else { break }
            if selected.contains(option.value) {
                content += "0.6 0.75 0.85 rg 1 \(f(top - rowHeight)) \(f(size.width - 2)) \(f(rowHeight)) re f "
            }
            content += "BT /Helv \(f(fontSize)) Tf 0 g 3 \(f(top - rowHeight + (rowHeight - fontSize * 0.7) / 2)) Td (\(escape(option.label))) Tj ET "
        }
        return stream(size, content + "Q EMC")
    }

    private func textContent(_ lines: [String], size: CGSize, fontSize: CGFloat, alignment: TextStyle.Alignment, multiline: Bool) -> String {
        var content = "/Tx BMC q 1 1 \(f(size.width - 2)) \(f(size.height - 2)) re W n BT /Helv \(f(fontSize)) Tf 0 g "
        let leading = fontSize * 1.15
        for (index, line) in lines.enumerated() {
            let width = Self.width(line, fontSize: fontSize)
            let x: CGFloat = switch alignment {
            case .left: 2
            case .center: (size.width - width) / 2
            case .right: size.width - 2 - width
            }
            let y = multiline
                ? size.height - 2 - fontSize * 0.9 - CGFloat(index) * leading
                : (size.height - fontSize * 0.7) / 2
            content += "1 0 0 1 \(f(max(x, 2))) \(f(y)) Tm (\(escape(line))) Tj "
        }
        return content + "ET Q EMC"
    }

    private func wrap(_ text: String, width: CGFloat, fontSize: CGFloat) -> [String] {
        var lines: [String] = []
        for paragraph in text.components(separatedBy: .newlines) {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if !line.isEmpty, Self.width(candidate, fontSize: fontSize) > width {
                    lines.append(line)
                    line = String(word)
                } else {
                    line = candidate
                }
            }
            lines.append(line)
        }
        return lines
    }

    static func width(_ text: String, fontSize: CGFloat) -> CGFloat {
        let metrics = HelveticaMetrics.shared?.fonts["Helvetica"]
        let total = text.unicodeScalars.reduce(0.0) { $0 + (metrics?.width($1) ?? 556) }
        return CGFloat(total) * fontSize / 1000
    }

    /// A WinAnsi literal-string body (characters outside WinAnsi become "?").
    private func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "(", ")", "\\": out += "\\" + String(scalar)
            case _ where scalar.value >= 0x20 && scalar.value < 0x7F: out.unicodeScalars.append(scalar)
            default:
                if let byte = Self.winAnsi(scalar) { out += String(format: "\\%03o", byte) } else { out += "?" }
            }
        }
        return out
    }

    private static func winAnsi(_ scalar: Unicode.Scalar) -> UInt8? {
        if (0xA0...0xFF).contains(scalar.value) { return UInt8(scalar.value) }
        let table: [UInt32: UInt8] = [
            0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87,
            0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C, 0x017D: 0x8E, 0x2018: 0x91,
            0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98,
            0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B, 0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
        ]
        return table[scalar.value]
    }

    private func f(_ value: CGFloat) -> String { PDFObject.format(Double(value)) }
}
