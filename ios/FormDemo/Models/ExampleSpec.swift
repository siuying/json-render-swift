import Foundation
import JSONRenderSwiftUI

/// An offline example: a spec bundled from `fixtures/specs` (forms) or `fixtures/pdf` (documents).
struct ExampleSpec: Identifiable, Hashable, Sendable {
    /// Resource name without extension (`<id>.json`).
    let id: String
    let title: String
    let systemImage: String

    static let forms: [ExampleSpec] = [
        ExampleSpec(id: "registration", title: "Registration", systemImage: "person.crop.circle.badge.plus"),
        ExampleSpec(id: "event-rsvp", title: "Event RSVP", systemImage: "party.popper"),
        ExampleSpec(id: "feedback-survey", title: "Feedback Survey", systemImage: "star.bubble"),
        ExampleSpec(id: "shipping-address", title: "Shipping Address", systemImage: "shippingbox"),
        ExampleSpec(id: "sales-review", title: "Sales Review (charts)", systemImage: "chart.bar.xaxis"),
    ]

    static let documents: [ExampleSpec] = [
        ExampleSpec(id: "invoice", title: "Invoice", systemImage: "doc.text"),
        ExampleSpec(id: "report", title: "Quarterly Report", systemImage: "chart.bar.doc.horizontal"),
        ExampleSpec(id: "resume", title: "Resume", systemImage: "person.text.rectangle"),
        ExampleSpec(id: "letter", title: "Business Letter", systemImage: "envelope"),
        ExampleSpec(id: "statement", title: "Bank Statement", systemImage: "banknote"),
        ExampleSpec(id: "sales-report", title: "Sales Report (charts)", systemImage: "chart.line.uptrend.xyaxis"),
        ExampleSpec(id: "application-form", title: "Rental Application (fillable)", systemImage: "pencil.and.list.clipboard"),
    ]

    static func named(_ id: String, kind: GenerationKind) -> ExampleSpec? {
        kind.examples.first { $0.id == id }
    }

    func load(from bundle: Bundle = .main) throws -> Spec {
        try Spec(jsonData: Self.data(named: id, extension: "json", in: bundle))
    }

    /// The kind's default recorded stream.
    static func replayStream(for kind: GenerationKind, from bundle: Bundle = .main) throws -> String {
        try replayStream(named: kind.replays[0].id, from: bundle)
    }

    /// A recorded stream (`<id>.jsonl`).
    static func replayStream(named id: String, from bundle: Bundle = .main) throws -> String {
        String(decoding: try data(named: id, extension: "jsonl", in: bundle), as: UTF8.self)
    }

    private static func data(named name: String, extension ext: String, in bundle: Bundle) throws -> Data {
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw ExampleError.missingResource("\(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }
}

enum ExampleError: Error, LocalizedError {
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let name): "\(name) is missing from the app bundle."
        }
    }
}
