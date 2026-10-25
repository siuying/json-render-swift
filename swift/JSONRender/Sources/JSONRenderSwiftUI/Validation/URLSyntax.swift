import Foundation

/// Approximates whether WHATWG `new URL(string)` (no base) succeeds, which is what
/// core's `url` check tests. Covers scheme, authority, host code points, IPv4/IPv6
/// literals and ports; IDNA (punycode) validation is not replicated.
enum URLSyntax {
    private static let specialSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp", "file"]

    static func isValid(_ input: String) -> Bool {
        // Strip leading/trailing C0 controls and spaces; remove tabs and newlines anywhere.
        let stripped = input.unicodeScalars
            .drop(while: { $0.value <= 0x20 })
            .reversed().drop(while: { $0.value <= 0x20 }).reversed()
            .filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        let text = String(String.UnicodeScalarView(stripped))

        guard let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon].lowercased()
        guard let first = scheme.unicodeScalars.first, first.isASCIILetter,
              scheme.unicodeScalars.allSatisfy({ $0.isASCIILetter || $0.isASCIIDigit || "+-.".unicodeScalars.contains($0) })
        else { return false }
        let rest = text[text.index(after: colon)...]

        if scheme == "file" { return isValidFileURL(rest) }
        if specialSchemes.contains(scheme) {
            let afterSlashes = rest.drop(while: { $0 == "/" || $0 == "\\" })
            let authority = afterSlashes.prefix(while: { !"/\\?#".contains($0) })
            return isValidAuthority(String(authority), special: true)
        }
        guard rest.hasPrefix("//") else { return true } // opaque path: always parses
        let authority = rest.dropFirst(2).prefix(while: { !"/?#".contains($0) })
        return isValidAuthority(String(authority), special: false)
    }

    /// `file:` URLs: a host follows only after exactly two slashes; it may be empty,
    /// `localhost`, a Windows drive letter, an IPv6 literal or a domain/IPv4 host.
    /// Credentials and ports are not allowed (`@` and `:` are forbidden host code points).
    private static func isValidFileURL(_ rest: Substring) -> Bool {
        let slashes = rest.prefix(while: { $0 == "/" || $0 == "\\" })
        guard slashes.count >= 2 else { return true }
        let afterSlashes = rest.dropFirst(2)
        let host = String(afterSlashes.prefix(while: { !"/\\?#".contains($0) }))
        if host.isEmpty { return true }
        let scalars = Array(host.unicodeScalars)
        if scalars.count == 2, scalars[0].isASCIILetter, scalars[1] == ":" || scalars[1] == "|" { return true }
        if host.hasPrefix("[") {
            guard host.hasSuffix("]") else { return false }
            return isValidIPv6(String(host.dropFirst().dropLast()))
        }
        return isValidDomain(host)
    }

    private static func isValidAuthority(_ authority: String, special: Bool) -> Bool {
        let hostAndPort = authority.lastIndex(of: "@").map { String(authority[authority.index(after: $0)...]) } ?? authority
        if hostAndPort.isEmpty { return !special }

        var host = hostAndPort
        var port: Substring?
        if hostAndPort.hasPrefix("[") {
            guard let close = hostAndPort.firstIndex(of: "]") else { return false }
            host = String(hostAndPort[...close])
            let tail = hostAndPort[hostAndPort.index(after: close)...]
            if !tail.isEmpty {
                guard tail.hasPrefix(":") else { return false }
                port = tail.dropFirst()
            }
        } else if let colon = hostAndPort.lastIndex(of: ":") {
            host = String(hostAndPort[..<colon])
            port = hostAndPort[hostAndPort.index(after: colon)...]
        }
        if let port, !port.isEmpty {
            guard port.allSatisfy(\.isASCIIDigit), let number = Int(port.prefix(6)), number <= 65_535 else { return false }
        }
        if host.isEmpty { return !special && port?.isEmpty != false }
        if host.hasPrefix("[") { return isValidIPv6(String(host.dropFirst().dropLast())) }
        return special ? isValidDomain(host) : isValidOpaqueHost(host)
    }

    private static func isValidOpaqueHost(_ host: String) -> Bool {
        !host.unicodeScalars.contains { forbiddenHost.contains($0) || $0.value <= 0x1F || $0.value == 0x7F }
    }

    private static func isValidDomain(_ host: String) -> Bool {
        let decoded = host.removingPercentEncoding ?? host
        guard !decoded.isEmpty else { return false }
        let forbidden = forbiddenHost.union(["%"])
        guard !decoded.unicodeScalars.contains(where: { forbidden.contains($0) || $0.value <= 0x1F || $0.value == 0x7F })
        else { return false }
        let labels = decoded.lowercased().split(separator: ".", omittingEmptySubsequences: false)
        let last = labels.last == "" && labels.count > 1 ? labels[labels.count - 2] : labels.last ?? ""
        if looksNumeric(last) { return isValidIPv4(Array(labels)) }
        return true
    }

    private static let forbiddenHost: Set<Unicode.Scalar> = [
        " ", "#", "/", ":", "<", ">", "?", "@", "[", "\\", "]", "^", "|",
    ]

    private static func looksNumeric(_ label: Substring) -> Bool {
        if !label.isEmpty, label.allSatisfy(\.isASCIIDigit) { return true }
        return label.hasPrefix("0x") && label.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func isValidIPv4(_ rawLabels: [Substring]) -> Bool {
        var labels = rawLabels
        if labels.count > 1, labels.last == "" { labels.removeLast() }
        guard labels.count <= 4 else { return false }
        var numbers: [Double] = []
        for label in labels {
            guard let number = ipv4Number(label) else { return false }
            numbers.append(number)
        }
        for number in numbers.dropLast() where number > 255 { return false }
        return numbers.last! < pow(256, Double(5 - numbers.count))
    }

    private static func ipv4Number(_ label: Substring) -> Double? {
        guard !label.isEmpty else { return nil }
        var digits = label
        var radix = 10.0
        if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
            digits = digits.dropFirst(2)
            radix = 16
        } else if digits.count > 1, digits.hasPrefix("0") {
            digits = digits.dropFirst()
            radix = 8
        }
        var value = 0.0
        for character in digits {
            guard let digit = character.hexDigitValue, Double(digit) < radix else { return nil }
            value = value * radix + Double(digit)
        }
        return value
    }

    private static func isValidIPv6(_ address: String) -> Bool {
        guard !address.isEmpty else { return false }
        var groups = address.components(separatedBy: ":")
        let compressions = address.components(separatedBy: "::").count - 1
        guard compressions <= 1 else { return false }
        if let last = groups.last, last.contains(".") {
            guard isValidIPv4(last.split(separator: ".", omittingEmptySubsequences: false)),
                  last.split(separator: ".").count == 4 else { return false }
            groups.removeLast()
            groups.append(contentsOf: ["0", "0"])
        }
        let nonEmpty = groups.filter { !$0.isEmpty }
        guard nonEmpty.allSatisfy({ $0.count <= 4 && $0.allSatisfy(\.isHexDigit) }) else { return false }
        return compressions == 1 ? nonEmpty.count < 8 : groups.count == 8
    }
}

private extension Unicode.Scalar {
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
