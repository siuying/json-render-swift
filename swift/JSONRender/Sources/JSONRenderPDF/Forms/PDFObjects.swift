import Foundation

/// A minimal PDF object model: enough to read the classic cross-reference table, trailer,
/// catalog and page dictionaries of a Core Graphics-produced PDF and to serialize the
/// objects of an incremental update.
indirect enum PDFObject: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    /// A name, as raw bytes (without the leading "/").
    case name([UInt8])
    case string([UInt8])
    case array([PDFObject])
    /// Dictionary entries in their original order (keys as raw name bytes).
    case dict([(key: [UInt8], value: PDFObject)])
    case ref(Int, Int)
    /// A stream: its dictionary (without `/Length`, which is written automatically) and data.
    case stream([(key: [UInt8], value: PDFObject)], [UInt8])

    static func == (lhs: PDFObject, rhs: PDFObject) -> Bool {
        lhs.serialized() == rhs.serialized()
    }

    static func name(_ string: String) -> PDFObject { .name(Array(string.utf8)) }

    /// A PDF text string: PDFDocEncoding-compatible ASCII as a literal, else UTF-16BE with BOM.
    static func text(_ string: String) -> PDFObject {
        if string.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            return .string(Array(string.utf8))
        }
        var bytes: [UInt8] = [0xFE, 0xFF]
        for unit in string.utf16 { bytes += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        return .string(bytes)
    }

    static func dict(_ entries: [(String, PDFObject?)]) -> PDFObject {
        .dict(entries.compactMap { key, value in value.map { (Array(key.utf8), $0) } })
    }

    static func rect(_ values: [Double]) -> PDFObject { .array(values.map { .real($0) }) }

    subscript(key: String) -> PDFObject? {
        guard case .dict(let entries) = self else { return nil }
        let bytes = Array(key.utf8)
        return entries.first { $0.key == bytes }?.value
    }

    /// A copy of a dictionary with `key` set (or removed when `value` is nil).
    func setting(_ key: String, _ value: PDFObject?) -> PDFObject {
        guard case .dict(var entries) = self else { return self }
        let bytes = Array(key.utf8)
        entries.removeAll { $0.key == bytes }
        if let value { entries.append((bytes, value)) }
        return .dict(entries)
    }

    var refValue: (Int, Int)? {
        if case .ref(let number, let generation) = self { return (number, generation) }
        return nil
    }

    var nameValue: String? {
        if case .name(let bytes) = self { return String(decoding: bytes, as: UTF8.self) }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .real(let value) where value.isFinite && abs(value) < 1e15: Int(value)
        default: nil
        }
    }

    // MARK: Serialization

    func serialized() -> [UInt8] {
        var out: [UInt8] = []
        write(to: &out)
        return out
    }

    func write(to out: inout [UInt8]) {
        switch self {
        case .null: out += Array("null".utf8)
        case .bool(let value): out += Array((value ? "true" : "false").utf8)
        case .int(let value): out += Array(String(value).utf8)
        case .real(let value): out += Array(Self.format(value).utf8)
        case .name(let bytes): out += Self.encodeName(bytes)
        case .string(let bytes): out += Self.encodeString(bytes)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: " ")) }
                item.write(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .dict(let entries):
            Self.writeDict(entries, to: &out)
        case .ref(let number, let generation):
            out += Array("\(number) \(generation) R".utf8)
        case .stream(var entries, let data):
            entries.removeAll { $0.key == Array("Length".utf8) }
            entries.append((Array("Length".utf8), .int(data.count)))
            Self.writeDict(entries, to: &out)
            out += Array("\nstream\n".utf8)
            out += data
            out += Array("\nendstream".utf8)
        }
    }

    private static func writeDict(_ entries: [(key: [UInt8], value: PDFObject)], to out: inout [UInt8]) {
        out += Array("<<".utf8)
        for entry in entries {
            out.append(UInt8(ascii: " "))
            out += encodeName(entry.key)
            out.append(UInt8(ascii: " "))
            entry.value.write(to: &out)
        }
        out += Array(" >>".utf8)
    }

    static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let rounded = (value * 10_000).rounded() / 10_000
        if rounded == rounded.rounded() && abs(rounded) < 1e15 { return String(Int(rounded)) }
        return String(format: "%.4f", rounded).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    static func encodeName(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [UInt8(ascii: "/")]
        for byte in bytes {
            if byte > 0x20, byte < 0x7F, !Self.delimiters.contains(byte), byte != UInt8(ascii: "#") {
                out.append(byte)
            } else {
                out += Array(String(format: "#%02X", byte).utf8)
            }
        }
        return out
    }

    static func encodeString(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [UInt8(ascii: "(")]
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "\\"):
                out += [UInt8(ascii: "\\"), byte]
            case 0x0A: out += Array("\\n".utf8)
            case 0x0D: out += Array("\\r".utf8)
            case 0x20..<0x7F: out.append(byte)
            default: out += Array(String(format: "\\%03o", byte).utf8)
            }
        }
        out.append(UInt8(ascii: ")"))
        return out
    }

    static let delimiters: Set<UInt8> = Set("()<>[]{}/%".utf8)
}

/// Errors reading a PDF's structure.
struct PDFStructureError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Parses objects from PDF bytes (classic syntax only; no object or xref streams).
struct PDFParser {
    let bytes: [UInt8]
    var position: Int

    init(bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }

    static func isRegular(_ byte: UInt8) -> Bool {
        !isWhitespace(byte) && !PDFObject.delimiters.contains(byte)
    }

    mutating func skipWhitespace() {
        while position < bytes.count {
            if Self.isWhitespace(bytes[position]) {
                position += 1
            } else if bytes[position] == UInt8(ascii: "%") {
                while position < bytes.count, bytes[position] != 10, bytes[position] != 13 { position += 1 }
            } else {
                return
            }
        }
    }

    /// The next regular token (keyword or number) without consuming it.
    func peekToken(from start: Int) -> (String, Int)? {
        var parser = self
        parser.position = start
        parser.skipWhitespace()
        let begin = parser.position
        while parser.position < bytes.count, Self.isRegular(bytes[parser.position]) { parser.position += 1 }
        guard parser.position > begin else { return nil }
        return (String(decoding: bytes[begin..<parser.position], as: UTF8.self), parser.position)
    }

    mutating func expectKeyword(_ keyword: String) throws {
        guard let (token, end) = peekToken(from: position), token == keyword else {
            throw PDFStructureError("expected \(keyword) at \(position)")
        }
        position = end
    }

    mutating func parseObject(depth: Int = 0) throws -> PDFObject {
        guard depth < 64 else { throw PDFStructureError("nesting too deep") }
        skipWhitespace()
        guard position < bytes.count else { throw PDFStructureError("unexpected end") }
        let byte = bytes[position]
        switch byte {
        case UInt8(ascii: "/"):
            position += 1
            var name: [UInt8] = []
            while position < bytes.count, Self.isRegular(bytes[position]) {
                if bytes[position] == UInt8(ascii: "#"), position + 2 < bytes.count,
                   let value = UInt8(String(decoding: bytes[(position + 1)...(position + 2)], as: UTF8.self), radix: 16) {
                    name.append(value)
                    position += 3
                } else {
                    name.append(bytes[position])
                    position += 1
                }
            }
            return .name(name)
        case UInt8(ascii: "("):
            return .string(try parseLiteralString())
        case UInt8(ascii: "<"):
            if position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "<") {
                position += 2
                var entries: [(key: [UInt8], value: PDFObject)] = []
                while true {
                    skipWhitespace()
                    guard position + 1 < bytes.count else { throw PDFStructureError("unterminated dictionary") }
                    if bytes[position] == UInt8(ascii: ">"), bytes[position + 1] == UInt8(ascii: ">") {
                        position += 2
                        break
                    }
                    guard case .name(let key) = try parseObject(depth: depth + 1) else {
                        throw PDFStructureError("dictionary key is not a name")
                    }
                    entries.append((key, try parseObject(depth: depth + 1)))
                }
                return .dict(entries)
            }
            return .string(try parseHexString())
        case UInt8(ascii: "["):
            position += 1
            var items: [PDFObject] = []
            while true {
                skipWhitespace()
                guard position < bytes.count else { throw PDFStructureError("unterminated array") }
                if bytes[position] == UInt8(ascii: "]") {
                    position += 1
                    break
                }
                items.append(try parseObject(depth: depth + 1))
            }
            return .array(items)
        default:
            guard let (token, end) = peekToken(from: position) else { throw PDFStructureError("bad token at \(position)") }
            position = end
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: break
            }
            if let integer = Int(token) {
                // `n g R` reference?
                if let (second, afterSecond) = peekToken(from: position), let generation = Int(second),
                   let (third, afterThird) = peekToken(from: afterSecond), third == "R" {
                    _ = afterSecond
                    position = afterThird
                    return .ref(integer, generation)
                }
                return .int(integer)
            }
            if let real = Double(token) { return .real(real) }
            throw PDFStructureError("unexpected token \(token)")
        }
    }

    private mutating func parseLiteralString() throws -> [UInt8] {
        position += 1
        var depth = 1
        var out: [UInt8] = []
        while position < bytes.count {
            let byte = bytes[position]
            position += 1
            switch byte {
            case UInt8(ascii: "\\"):
                guard position < bytes.count else { break }
                let next = bytes[position]
                position += 1
                switch next {
                case UInt8(ascii: "n"): out.append(10)
                case UInt8(ascii: "r"): out.append(13)
                case UInt8(ascii: "t"): out.append(9)
                case UInt8(ascii: "b"): out.append(8)
                case UInt8(ascii: "f"): out.append(12)
                case 10: break
                case 13: if position < bytes.count, bytes[position] == 10 { position += 1 }
                case UInt8(ascii: "0")...UInt8(ascii: "7"):
                    var value = Int(next - 48)
                    for _ in 0..<2 {
                        guard position < bytes.count, (48...55).contains(bytes[position]) else { break }
                        value = value * 8 + Int(bytes[position] - 48)
                        position += 1
                    }
                    out.append(UInt8(value & 0xFF))
                default: out.append(next)
                }
            case UInt8(ascii: "("):
                depth += 1
                out.append(byte)
            case UInt8(ascii: ")"):
                depth -= 1
                if depth == 0 { return out }
                out.append(byte)
            default:
                out.append(byte)
            }
        }
        throw PDFStructureError("unterminated string")
    }

    private mutating func parseHexString() throws -> [UInt8] {
        position += 1
        var digits: [UInt8] = []
        while position < bytes.count, bytes[position] != UInt8(ascii: ">") {
            if let value = Character(UnicodeScalar(bytes[position])).hexDigitValue { digits.append(UInt8(value)) }
            position += 1
        }
        guard position < bytes.count else { throw PDFStructureError("unterminated hex string") }
        position += 1
        if digits.count % 2 == 1 { digits.append(0) }
        return stride(from: 0, to: digits.count, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
    }
}

/// The cross-reference table, trailer and object access of an existing PDF.
struct PDFFileStructure {
    let bytes: [UInt8]
    let offsets: [Int: Int]
    let trailer: PDFObject
    let startXref: Int

    init(data: Data) throws {
        bytes = Array(data)
        guard let marker = Self.lastRange(of: Array("startxref".utf8), in: bytes) else {
            throw PDFStructureError("no startxref")
        }
        var parser = PDFParser(bytes: bytes, position: marker + 9)
        guard case .int(let start) = try parser.parseObject() else { throw PDFStructureError("bad startxref") }
        startXref = start
        var offsets: [Int: Int] = [:]
        var trailer: PDFObject?
        var next: Int? = start
        var visited: Set<Int> = []
        while let section = next, visited.insert(section).inserted, visited.count < 32 {
            let (sectionOffsets, sectionTrailer) = try Self.readSection(bytes, at: section)
            for (number, offset) in sectionOffsets where offsets[number] == nil { offsets[number] = offset }
            if trailer == nil { trailer = sectionTrailer }
            next = sectionTrailer["Prev"]?.intValue
        }
        guard let trailer else { throw PDFStructureError("no trailer") }
        self.offsets = offsets.filter { $0.value >= 0 }
        self.trailer = trailer
    }

    private static func readSection(_ bytes: [UInt8], at offset: Int) throws -> ([Int: Int], PDFObject) {
        var parser = PDFParser(bytes: bytes, position: offset)
        try parser.expectKeyword("xref") // xref streams are not supported
        var offsets: [Int: Int] = [:]
        while true {
            guard let (token, _) = parser.peekToken(from: parser.position) else { throw PDFStructureError("bad xref") }
            if token == "trailer" {
                try parser.expectKeyword("trailer")
                return (offsets, try parser.parseObject())
            }
            guard case .int(let first) = try parser.parseObject(), case .int(let count) = try parser.parseObject(),
                  count >= 0, count < 10_000_000 else { throw PDFStructureError("bad xref subsection") }
            for index in 0..<count {
                guard case .int(let entryOffset) = try parser.parseObject(), case .int = try parser.parseObject(),
                      let (kind, end) = parser.peekToken(from: parser.position) else { throw PDFStructureError("bad xref entry") }
                parser.position = end
                // Free entries are kept (as -1) so they shadow older sections' in-use entries.
                offsets[first + index] = kind == "n" ? entryOffset : -1
            }
        }
    }

    private static func lastRange(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        var index = haystack.count - needle.count
        while index >= 0 {
            if haystack[index] == needle[0], Array(haystack[index..<(index + needle.count)]) == needle { return index }
            index -= 1
        }
        return nil
    }

    var size: Int { trailer["Size"]?.intValue ?? ((offsets.keys.max() ?? 0) + 1) }

    /// Objects the xref marks in use at offset 0 (no object can live there) that nothing
    /// references: no `N 0 R` anywhere in the file (a byte search, so a false match only
    /// makes this more conservative).
    func unreferencedZeroOffsetObjects() -> [Int] {
        offsets.filter { $0.value == 0 && $0.key > 0 }.map(\.key).sorted().filter { !isReferenced($0) }
    }

    private func isReferenced(_ number: Int) -> Bool {
        let needle = Array("\(number) 0 R".utf8)
        guard bytes.count >= needle.count else { return false }
        var index = 0
        while index <= bytes.count - needle.count {
            if bytes[index] == needle[0], Array(bytes[index..<(index + needle.count)]) == needle,
               index == 0 || !(48...57).contains(bytes[index - 1]) {
                return true
            }
            index += 1
        }
        return false
    }

    func object(_ number: Int) throws -> PDFObject {
        guard let offset = offsets[number], offset < bytes.count else { throw PDFStructureError("object \(number) missing") }
        var parser = PDFParser(bytes: bytes, position: offset)
        guard case .int(let found) = try parser.parseObject(), found == number, case .int = try parser.parseObject() else {
            throw PDFStructureError("object \(number) header")
        }
        try parser.expectKeyword("obj")
        return try parser.parseObject()
    }

    func resolve(_ object: PDFObject?) throws -> PDFObject? {
        guard let object else { return nil }
        if let (number, _) = object.refValue { return try self.object(number) }
        return object
    }

    /// Page object numbers in document order.
    func pageNumbers() throws -> [Int] {
        guard let (catalog, _) = trailer["Root"]?.refValue,
              let (pagesRoot, _) = try object(catalog)["Pages"]?.refValue else { throw PDFStructureError("no page tree") }
        var pages: [Int] = []
        var visited: Set<Int> = []
        func visit(_ number: Int, depth: Int) throws {
            guard depth < 32, visited.insert(number).inserted else { return }
            let node = try object(number)
            if node["Type"]?.nameValue == "Page" {
                pages.append(number)
                return
            }
            guard case .array(let kids)? = try resolve(node["Kids"]) else { return }
            for kid in kids { if let (child, _) = kid.refValue { try visit(child, depth: depth + 1) } }
        }
        try visit(pagesRoot, depth: 0)
        return pages
    }
}
