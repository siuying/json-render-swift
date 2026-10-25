import Foundation
import OSLog

/// `new RegExp(source).test(input)` (no flags) evaluated with ICU after translating the
/// JavaScript pattern language:
///
/// - `\d \w \s \b` and their negations use JavaScript's ASCII/JS-whitespace definitions
///   (ICU's are Unicode-aware, e.g. ICU `\d` matches Arabic-Indic digits).
/// - `.` excludes only JS line terminators; `$` matches only at the end of input.
/// - Annex B literals: identity escapes (`\a`, `\p`, `\e` are plain letters), `\v`, `\0`,
///   `[\b]`, lone `{ } ]`, `[` inside classes, `[]` and `[^]`.
/// - Syntax JavaScript rejects (inline flags `(?i)`, atomic `(?>…)`, possessive `a*+`,
///   trailing `\`, unterminated classes) fails the check, like core's invalid-pattern path.
///
/// Remaining differences: matching runs on code points rather than UTF-16 code units
/// (astral characters count as one `.`), and ICU only supports bounded look-behind and
/// back-references to existing groups (unsupported forms fail the check).
enum JSRegex {
    private static let word = "A-Za-z0-9_"
    private static let whitespace = "\\t\\n\\x{0B}\\f\\r \\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"
    private static let boundary = "(?:(?<=[\(word)])(?![\(word)])|(?<![\(word)])(?=[\(word)]))"
    private static let nonBoundary = "(?:(?<=[\(word)])(?=[\(word)])|(?<![\(word)])(?![\(word)]))"

    static func test(_ source: String, _ input: String) -> Bool {
        guard let pattern = icuPattern(source), let regex = try? NSRegularExpression(pattern: pattern) else {
            Logger.jsonRender.warning("pattern check: unsupported or invalid pattern \(source, privacy: .public)")
            return false
        }
        return regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) != nil
    }

    /// The equivalent ICU pattern, or `nil` when JavaScript would throw or the syntax is unsupported.
    static func icuPattern(_ source: String) -> String? {
        var translator = Translator(chars: Array(source.unicodeScalars))
        return translator.run()
    }

    private struct Translator {
        let chars: [Unicode.Scalar]
        var index = 0
        var output = ""

        init(chars: [Unicode.Scalar]) {
            self.chars = chars
        }

        func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            index + offset < chars.count ? chars[index + offset] : nil
        }

        mutating func run() -> String? {
            var lastWasQuantifier = false
            while let c = peek() {
                index += 1
                var isQuantifier = false
                switch c {
                case "\\":
                    guard let escaped = escape(inClass: false) else { return nil }
                    output += escaped
                case "[":
                    guard let set = characterClass() else { return nil }
                    output += set
                case ".":
                    output += "[^\\n\\r\\x{2028}\\x{2029}]"
                case "$":
                    output += "\\z"
                case "(":
                    guard groupOpening() else { return nil }
                case "*", "+", "?":
                    if c == "+", lastWasQuantifier { return nil } // possessive: a JS syntax error
                    output.unicodeScalars.append(c)
                    // A `?` after a quantifier makes it lazy and ends it.
                    isQuantifier = !(c == "?" && lastWasQuantifier)
                case "{":
                    if let interval = interval() {
                        if lastWasQuantifier { return nil }
                        output += interval
                        isQuantifier = true
                    } else {
                        output += "\\{"
                    }
                case "}", "]":
                    output += "\\" + String(c)
                default:
                    output.unicodeScalars.append(c)
                }
                lastWasQuantifier = isQuantifier
            }
            return output
        }

        /// `(` followed by an optional group modifier JavaScript accepts.
        mutating func groupOpening() -> Bool {
            output += "("
            guard peek() == "?" else { return true }
            switch (peek(1), peek(2)) {
            case (":"?, _), ("="?, _), ("!"?, _), ("<"?, "="?), ("<"?, "!"?):
                return true
            case ("<"?, let first?) where first.properties.isIDStart || first == "_" || first == "$":
                return true // named group; ICU accepts the same syntax
            default:
                return false
            }
        }

        /// `{n}`, `{n,}`, `{n,m}` starting at the current index (after `{`).
        mutating func interval() -> String? {
            var cursor = index
            var text = "{"
            func digits() -> String {
                var result = ""
                while cursor < chars.count, ("0"..."9").contains(chars[cursor]) {
                    result.unicodeScalars.append(chars[cursor])
                    cursor += 1
                }
                return result
            }
            let lower = digits()
            guard !lower.isEmpty else { return nil }
            text += lower
            if cursor < chars.count, chars[cursor] == "," {
                cursor += 1
                text += "," + digits()
            }
            guard cursor < chars.count, chars[cursor] == "}" else { return nil }
            index = cursor + 1
            return text + "}"
        }

        /// A `[...]` class starting after `[`.
        mutating func characterClass() -> String? {
            var negated = false
            if peek() == "^" {
                negated = true
                index += 1
            }
            if peek() == "]" {
                index += 1
                return negated ? "[\\s\\S]" : "(?!)" // `[^]` matches anything, `[]` nothing
            }
            var body = ""
            while let c = peek() {
                index += 1
                switch c {
                case "]":
                    return "[" + (negated ? "^" : "") + body + "]"
                case "\\":
                    guard let escaped = escape(inClass: true) else { return nil }
                    body += escaped
                case "-":
                    body += "-"
                default:
                    body += Self.literal(c, inClass: true)
                }
            }
            return nil // unterminated class
        }

        /// Translates the escape after a `\`.
        mutating func escape(inClass: Bool) -> String? {
            guard let c = peek() else { return nil } // trailing backslash
            index += 1
            switch c {
            case "d": return inClass ? "0-9" : "[0-9]"
            case "D": return "[^0-9]"
            case "w": return inClass ? word : "[\(word)]"
            case "W": return "[^\(word)]"
            case "s": return inClass ? whitespace : "[\(whitespace)]"
            case "S": return "[^\(whitespace)]"
            case "b": return inClass ? "\\x{08}" : boundary
            case "B": return inClass ? "B" : nonBoundary
            case "f", "n", "r", "t": return "\\" + String(c)
            case "v": return "\\x{0B}"
            case "0" where !(peek().map { ("0"..."9").contains($0) } ?? false):
                return "\\x{00}"
            case "1"..."9":
                if inClass { return nil } // legacy octal in classes is not supported
                var reference = String(c)
                while let next = peek(), ("0"..."9").contains(next) {
                    reference.unicodeScalars.append(next)
                    index += 1
                }
                return "\\" + reference
            case "c":
                if let letter = peek(), letter.isASCIILetter {
                    index += 1
                    return "\\c" + String(letter)
                }
                return "\\\\c"
            case "x":
                if let hex = hexDigits(2) { return "\\x{\(hex)}" }
                return "x"
            case "u":
                if let hex = hexDigits(4) { return "\\x{\(hex)}" }
                return "u" // without the `u` flag, `\u{…}` is a literal "u"
            case "k" where !inClass && chars.contains("<") && peek() == "<":
                return "\\k"
            default:
                return Self.literal(c, inClass: inClass) // identity escape
            }
        }

        mutating func hexDigits(_ count: Int) -> String? {
            guard index + count <= chars.count else { return nil }
            let digits = chars[index..<(index + count)]
            guard digits.allSatisfy({ $0.properties.isASCIIHexDigit }) else { return nil }
            index += count
            return String(String.UnicodeScalarView(digits))
        }

        /// A character matched literally; ASCII punctuation is escaped for ICU.
        static func literal(_ c: Unicode.Scalar, inClass: Bool) -> String {
            let isPunctuation = c.value > 0x20 && c.value < 0x7F && !c.isASCIILetter && !("0"..."9").contains(c)
            return isPunctuation ? "\\" + String(c) : String(c)
        }
    }
}

private extension Unicode.Scalar {
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
}
