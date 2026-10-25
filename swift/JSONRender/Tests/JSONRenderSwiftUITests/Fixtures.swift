import Foundation
@testable import JSONRenderSwiftUI

/// Loads files from the repository's `fixtures/` directory (relative to this source file).
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // JSONRenderSwiftUITests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // JSONRender
        .deletingLastPathComponent() // swift
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("fixtures")

    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func json(_ relativePath: String) throws -> JSONValue {
        try JSONValue(jsonData: Data(contentsOf: url(relativePath)))
    }

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    static func files(in directory: String, withExtension ext: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url(directory).path)) ?? []
        return names.filter { $0.hasSuffix("." + ext) }.sorted().map { "\(directory)/\($0)" }
    }

    /// Parity cases from `fixtures/parity/<name>.json`.
    static func parityCases(_ name: String) -> [ParityCase] {
        guard let cases = try? json("parity/\(name).json")["cases"]?.arrayValue else { return [] }
        return cases.map(ParityCase.init)
    }
}

/// One generated parity case; `CustomTestStringConvertible` keeps test names readable.
struct ParityCase: Sendable, CustomStringConvertible {
    let json: JSONValue
    var name: String { json["name"]?.stringValue ?? "?" }
    var description: String { name }
    var state: JSONValue { json["state"] ?? .object([:]) }
    subscript(key: String) -> JSONValue? { json[key] }
}
