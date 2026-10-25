#if DEBUG
import Foundation
import JSONRenderPDF
import JSONRenderSwiftUI
import UIKit

/// A scripted walkthrough for screen recordings (`-demo <id>` loads `<id>.demo.json` from
/// `DemoStreams/`). Prompts are typed into the prompt bar and answered by recorded streams
/// through the real pipeline; then form values are typed into state and the form is submitted.
/// The submitted form's fillable PDF is also written to `tmp/demo-fillable.pdf` in the app container.
/// Debug builds only.
struct DemoScript: Decodable {
    struct Step: Decodable {
        /// Pause, in seconds.
        var wait: Double?
        /// Typed into the prompt bar, then answered by `stream` (`<stream>.jsonl`).
        var prompt: String?
        var stream: String?
        /// A state pointer typed into character by character (`text`, after the current value when `append`).
        var type: String?
        var text: String?
        var append: Bool?
        /// A state pointer set to `value` at once (toggles, pickers, steppers).
        var set: String?
        var value: JSONValue?
        /// The field bound to this pointer loses focus (runs `validateOn: blur` checks).
        var blur: String?
        /// Scrolls the form to its `top` or `bottom`.
        var scroll: String?
        /// Validates and submits `/form`, opening the submission sheet on this tab.
        var submit: SubmissionSheet.Tab?
    }

    var steps: [Step]

    static func named(_ id: String, in bundle: Bundle = .main) throws -> DemoScript {
        guard let url = bundle.url(forResource: "\(id).demo", withExtension: "json") else {
            throw ExampleError.missingResource("\(id).demo.json")
        }
        return try JSONDecoder().decode(DemoScript.self, from: Data(contentsOf: url))
    }

    @MainActor
    func run(
        controller: GenerationController,
        setPrompt: (String) -> Void,
        openSubmission: (SubmissionSheet.Tab) -> Void
    ) async throws {
        for step in steps {
            // A new form gets a new session, so look the store up per step.
            let store = controller.session.store
            if let wait = step.wait { try await Task.sleep(for: .seconds(wait)) }
            if let prompt = step.prompt, let stream = step.stream {
                for count in 1...prompt.count {
                    setPrompt(String(prompt.prefix(count)))
                    try await Task.sleep(for: .milliseconds(28))
                }
                try await Task.sleep(for: .milliseconds(500))
                setPrompt("")
                await controller.replay(try ExampleSpec.replayStream(named: stream), as: prompt).value
            }
            if let path = step.type, let text = step.text {
                let start = step.append == true ? (store.value(at: path)?.stringValue ?? "") : ""
                for count in 1...text.count {
                    store.set(.string(start + text.prefix(count)), at: path)
                    try await Task.sleep(for: .milliseconds(70))
                }
            }
            if let path = step.set, let value = step.value { store.set(value, at: path) }
            if let path = step.blur, let field = controller.session.visibleFields.first(where: { $0.path == path }) {
                controller.session.fieldDidBlur(field)
            }
            if let edge = step.scroll { Self.scroll(toBottom: edge == "bottom") }
            if let tab = step.submit, controller.session.validateAll() {
                openSubmission(tab)
                controller.showSubmission(store.value(at: "/form"), dataRoot: "/form")
                if let fillable = controller.submission?.fillable {
                    let url = FileManager.default.temporaryDirectory.appending(path: "demo-fillable.pdf")
                    try await PDFRenderer().render(fillable).write(to: url)
                }
            }
        }
    }

    /// Scrolls the tallest scroll view in the key window (the rendered form), animated.
    @MainActor
    private static func scroll(toBottom: Bool) {
        let window = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        func scrollViews(in view: UIView) -> [UIScrollView] {
            let own = (view as? UIScrollView).map { [$0] } ?? []
            return own + view.subviews.flatMap(scrollViews)
        }
        guard let window,
              let view = scrollViews(in: window).max(by: { $0.contentSize.height < $1.contentSize.height })
        else { return }
        let insets = view.adjustedContentInset
        let bottom = max(-insets.top, view.contentSize.height - view.bounds.height + insets.bottom)
        view.setContentOffset(CGPoint(x: 0, y: toBottom ? bottom : -insets.top), animated: true)
    }
}

extension SubmissionSheet.Tab: Decodable {}
#endif
