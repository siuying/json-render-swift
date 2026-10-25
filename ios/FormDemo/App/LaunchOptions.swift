import Foundation

/// Launch arguments for deterministic demos and screenshots:
///
/// - `-mode form|document`: initial mode (default `form`)
/// - `-example <id>`: load an offline form (`registration`, `event-rsvp`, …)
/// - `-pdf-example <id>`: load an offline document (`invoice`, `report`, `resume`, `letter`, `statement`)
/// - `-replay [id]`: play a recorded stream of the initial mode (default: its first;
///   documents also have `application-form`)
/// - `-tab ui|json|jsonl`: initial tab of the initial mode
/// - `-validate`: run form validation right after loading (shows the inline errors)
/// - `-submit`: open the submission sheet with the current form state (skips the submit
///   action and its validation; the sheet says so)
/// - `-submit-pdf`: like `-submit`, showing the "Export as PDF" summary
/// - `-submit-fillable`: like `-submit`, showing the fillable PDF export
/// - `-settings`: open Settings
/// - `-read-values`: open "Read filled values" once the document has rendered
/// - `-demo-fill`: type sample values into the document's text fields first (screenshots)
/// - `-demo <id>`: run the scripted walkthrough `<id>.demo.json` (Debug builds; screen recordings)
struct LaunchOptions: Equatable {
    var mode: GenerationKind = .form
    var example: String?
    var pdfExample: String?
    /// `nil`: no replay; `""`: the mode's default stream.
    var replay: String?
    var tab: ViewMode?
    var validate = false
    var submit = false
    var submitPDF = false
    var submitFillable = false
    var settings = false
    var readValues = false
    var demoFill = false
    var demo: String?

    static var current: LaunchOptions {
        LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
    }

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        mode = value(after: "-mode").flatMap(GenerationKind.init(rawValue:)) ?? .form
        example = value(after: "-example")
        pdfExample = value(after: "-pdf-example")
        tab = value(after: "-tab").flatMap(ViewMode.init(rawValue:))
        if arguments.contains("-replay") {
            replay = value(after: "-replay").flatMap { $0.hasPrefix("-") ? nil : $0 } ?? ""
        }
        validate = arguments.contains("-validate")
        submitPDF = arguments.contains("-submit-pdf")
        submitFillable = arguments.contains("-submit-fillable")
        submit = arguments.contains("-submit") || submitPDF || submitFillable
        settings = arguments.contains("-settings")
        readValues = arguments.contains("-read-values")
        demoFill = arguments.contains("-demo-fill")
        demo = value(after: "-demo")
    }
}
