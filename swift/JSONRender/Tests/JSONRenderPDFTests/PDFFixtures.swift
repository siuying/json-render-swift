import Foundation
import JSONRenderPDF
import JSONRenderSwiftUI

/// Files under the repository's `fixtures/` directory.
enum PDFFixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("fixtures")

    static let repositoryRoot = root.deletingLastPathComponent()

    /// One bridge for the whole test bundle (each bridge loads the full JS bundle).
    static let bridge: JSONRenderBridge? = try? JSONRenderBridge()

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    static func json(_ path: String) throws -> JSONValue {
        try JSONValue(jsonData: Data(contentsOf: url(path)))
    }

    static func spec(_ name: String) throws -> Spec {
        Spec(json: try json("pdf/\(name).json"))
    }

    /// Fixtures that only use the standard PDF catalog (others may target future catalogs).
    static var catalogSpecNames: [String] {
        specNames.filter { name in
            guard let spec = try? spec(name) else { return false }
            return spec.elements.values.allSatisfy { JSONRenderPDF.PDFRenderer.componentTypes.contains($0.type) }
        }
    }

    static let specNames: [String] = {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url("pdf").path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }()
}
