import JSONRenderSwiftUI

/// What a workspace generates: a SwiftUI form or a PDF document. Each kind has its own
/// catalog, prompt rules, examples and copy; the streaming pipeline is shared.
enum GenerationKind: String, CaseIterable, Identifiable, Sendable {
    case form, document

    var id: Self { self }

    var title: String {
        switch self {
        case .form: "Form"
        case .document: "Document"
        }
    }

    var systemImage: String {
        switch self {
        case .form: "list.bullet.rectangle"
        case .document: "doc.richtext"
        }
    }

    /// The bridge catalog for prompts and validation.
    var catalog: JSONRenderBridge.Catalog {
        switch self {
        case .form: .swiftui
        case .document: .pdf
        }
    }

    /// Custom actions the app handles, announced to the model in the system prompt.
    var hostActions: Set<String> {
        switch self {
        case .form: ["log"]
        case .document: []
        }
    }

    var customRules: [String] {
        switch self {
        case .form:
            [#"The app also handles a custom action "log" with params { "message": string, "data"?: any }; it records an analytics event and shows a confirmation toast. Use it only for secondary buttons such as "Save draft", e.g. { "action": "log", "params": { "message": "Draft saved", "data": { "$state": "/form" } } }."#]
        case .document:
            []
        }
    }

    var examples: [ExampleSpec] {
        switch self {
        case .form: ExampleSpec.forms
        case .document: ExampleSpec.documents
        }
    }

    /// Recorded JSONL streams for "Replay stream" (`<id>.jsonl`); the first is the default.
    var replays: [ExampleSpec] {
        switch self {
        case .form:
            [ExampleSpec(id: "registration", title: "Replay registration", systemImage: "play.circle")]
        case .document:
            [
                ExampleSpec(id: "statement", title: "Replay bank statement", systemImage: "play.circle"),
                ExampleSpec(id: "application-form", title: "Replay fillable application", systemImage: "play.circle"),
            ]
        }
    }

    var suggestions: [String] {
        switch self {
        case .form:
            [
                "Sign-up form with password confirmation", "Event RSVP", "Customer feedback survey",
                "Shipping address", "Job application", "Restaurant reservation",
            ]
        case .document:
            [
                "Invoice for a web design project", "Fillable rental application form",
                "One-page resume for an iOS engineer",
                "Quarterly sales report", "Cover letter", "Meeting minutes", "Rental agreement summary",
            ]
        }
    }

    var emptyTitle: String {
        switch self {
        case .form: "Describe a form"
        case .document: "Describe a document"
        }
    }

    var emptyMessage: String {
        switch self {
        case .form:
            "The model streams a json-render spec and the form builds itself from native SwiftUI controls as it arrives."
        case .document:
            "The model streams a json-render spec and a native PDF renders from it while it arrives. Share it when it's done."
        }
    }

    var emptySymbol: String {
        switch self {
        case .form: "wand.and.sparkles"
        case .document: "doc.text.magnifyingglass"
        }
    }

    var newPrompt: String {
        switch self {
        case .form: "Describe a form…"
        case .document: "Describe a document…"
        }
    }

    var editPrompt: String { "Ask for a change…" }

    /// Lowercase noun for messages ("form", "document").
    var noun: String { rawValue }
}
