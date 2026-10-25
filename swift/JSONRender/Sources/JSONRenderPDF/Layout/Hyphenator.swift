import Foundation

/// Liang hyphenation with the en-US TeX patterns, ported from `@react-pdf/hyphenate`
/// (react-pdf's default word hyphenation): words shorter than 5 UTF-16 units are not
/// split, at least two characters stay on each side, and punctuation attached to a word
/// never hyphenates.
final class Hyphenator: @unchecked Sendable {
    // Immutable after init; `@unchecked` only because of the class-based trie.

    private final class Node {
        var children: [UInt16: Node] = [:]
        var plain: [Entry] = []
        var anchored: [Entry] = []
    }

    private struct Entry {
        var levels: [UInt8]
        var anchorStart: Bool
        var anchorEnd: Bool
        var length: Int
    }

    private static let minWordLength = 5
    private let root = Node()
    private let lock = NSLock()
    private var cache: [String: [String]] = [:]

    static let enUS: Hyphenator? = {
        guard let url = Bundle.module.url(forResource: "hyphenation-en-us", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PatternFile.self, from: data) else { return nil }
        return Hyphenator(patterns: file.patterns)
    }()

    private struct PatternFile: Decodable {
        var patterns: [String]
    }

    init(patterns: [String]) {
        for pattern in patterns { add(pattern) }
    }

    /// `syllables(word)`: the word split at its hyphenation points.
    func syllables(_ word: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[word] { return cached }
        let parts = splitToken(word)
        cache[word] = parts
        return parts
    }

    // MARK: Patterns

    private func add(_ source: String) {
        var levels: [UInt8] = []
        var text: [UInt16] = []
        var anchorStart = false, anchorEnd = false, afterLevel = false
        let units = Array(source.utf16)
        for (index, unit) in units.enumerated() {
            if unit == 0x2E { // "."
                if index == 0 { anchorStart = true } else { anchorEnd = true }
                afterLevel = false
            } else if (0x30...0x39).contains(unit) {
                levels.append(UInt8(unit - 0x30))
                afterLevel = true
            } else {
                if !afterLevel { levels.append(0) }
                text.append(unit)
                afterLevel = false
            }
        }
        guard !text.isEmpty else { return }
        var node = root
        for unit in text {
            if let child = node.children[unit] {
                node = child
            } else {
                let child = Node()
                node.children[unit] = child
                node = child
            }
        }
        let entry = Entry(levels: levels, anchorStart: anchorStart, anchorEnd: anchorEnd, length: text.count)
        if anchorStart || anchorEnd { node.anchored.append(entry) } else { node.plain.append(entry) }
    }

    // MARK: Splitting

    private func splitWord(_ word: [UInt16]) -> [[UInt16]] {
        let length = word.count
        guard length >= Self.minWordLength else { return [word] }
        let lowered = Array(String(decoding: word, as: UTF16.self).lowercased().utf16)
        guard lowered.count == length else { return [word] }
        var levels = [UInt8](repeating: 0, count: length + 1)
        for start in 0..<length {
            var node = root
            for end in start..<length {
                guard let child = node.children[lowered[end]] else { break }
                node = child
                for entry in node.plain { apply(entry, at: start, to: &levels) }
                for entry in node.anchored {
                    if entry.anchorStart && start != 0 { continue }
                    if entry.anchorEnd && start + entry.length != length { continue }
                    apply(entry, at: start, to: &levels)
                }
            }
        }
        levels[0] = 0
        levels[1] = 0
        levels[length] = 0
        levels[length - 1] = 0
        var parts: [[UInt16]] = []
        var from = 0
        for index in 1...length where levels[index] % 2 == 1 {
            parts.append(Array(word[from..<index]))
            from = index
        }
        parts.append(Array(word[from...]))
        return parts
    }

    private func apply(_ entry: Entry, at start: Int, to levels: inout [UInt8]) {
        for (offset, level) in entry.levels.enumerated() where start + offset < levels.count {
            if level > levels[start + offset] { levels[start + offset] = level }
        }
    }

    /// `/\s|[!-@[-`{-~–-‼]/`: whitespace and ASCII punctuation end a word.
    private static func isNonLetter(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
             0x21...0x40, 0x5B...0x60, 0x7B...0x7E, 0x2013...0x203C:
            true
        default:
            false
        }
    }

    private func splitToken(_ token: String) -> [String] {
        let units = Array(token.utf16)
        func string(_ units: [UInt16]) -> String { String(decoding: units, as: UTF16.self) }
        guard units.contains(where: Self.isNonLetter) else { return splitWord(units).map(string) }
        var parts: [[UInt16]] = [[]]
        var index = 0
        while index < units.count {
            let isLetter = !Self.isNonLetter(units[index])
            var end = index + 1
            while end < units.count, !Self.isNonLetter(units[end]) == isLetter { end += 1 }
            let chunk = Array(units[index..<end])
            if isLetter {
                let chunkParts = splitWord(chunk)
                parts[parts.count - 1] += chunkParts[0]
                parts += chunkParts.dropFirst()
            } else {
                parts[parts.count - 1] += chunk
            }
            index = end
        }
        return parts.map(string)
    }
}
