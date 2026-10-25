import Foundation
import JSONRenderSwiftUI
import Observation

/// Provider and model settings, read once when a generation starts.
struct GenerationOptions: Sendable, Equatable {
    var provider: Provider = .openAI
    var model: String
    var reasoningEffort: String?
}

/// A short-lived note shown at the top of the workspace.
struct Toast: Equatable {
    var message: String
    var systemImage = "checkmark.circle.fill"
}

/// Drives one workspace: streams JSONL from the model (or a replay) through the SDK's
/// stream compiler into the current spec, then validates the result against the kind's
/// catalog. Forms render through a ``FormSession``; documents keep the bare spec.
@MainActor
@Observable
final class GenerationController {

    enum Activity: Equatable {
        case idle
        case generating(prompt: String)
        case replaying
    }

    let kind: GenerationKind
    /// The rendered form (forms only). Replaced by a fresh session for new forms; kept for refinements.
    private(set) var session = FormSession()
    /// The current document spec (documents only).
    private var documentSpec: Spec?
    /// Incremented whenever the spec is replaced rather than updated (load, clear, new
    /// generation), so previews drop cached documents even if the new spec is equal.
    private(set) var revision = 0
    /// Raw model output of the latest stream (the JSONL tab).
    private(set) var rawJSONL = ""
    private(set) var activity: Activity = .idle
    /// Patches applied by the current or latest stream.
    private(set) var patchCount = 0
    /// Dismissible error banner.
    var errorMessage: String?
    /// Dismissible validation banner for the latest spec.
    var issues: [SpecValidation.Issue] = []
    /// Set when the latest spec failed validation and `autoFixSpec` repaired it.
    private(set) var didAutoFix = false
    /// Data passed to the `submit` action (presented as a sheet).
    var submission: Submission?
    /// Short-lived note: the custom `log` action, or "Continued on <model>" after a fallback.
    var toast: Toast?

    @ObservationIgnored private let generators: @Sendable (Provider) -> any TextGenerating
    @ObservationIgnored private let options: @MainActor () -> GenerationOptions
    @ObservationIgnored private var bridgeInstance: JSONRenderBridge?
    @ObservationIgnored private var systemPrompt: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Increments per run so a cancelled run never touches newer state.
    @ObservationIgnored private var runID = 0
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    /// - Parameter generators: the client for each provider (chosen per run from `options`).
    init(
        kind: GenerationKind = .form,
        generators: @escaping @Sendable (Provider) -> any TextGenerating,
        options: @escaping @MainActor () -> GenerationOptions
    ) {
        self.kind = kind
        self.generators = generators
        self.options = options
    }

    /// One client for every provider (tests).
    convenience init(
        kind: GenerationKind = .form,
        generator: any TextGenerating,
        options: @escaping @MainActor () -> GenerationOptions
    ) {
        self.init(kind: kind, generators: { _ in generator }, options: options)
    }

    var spec: Spec? {
        switch kind {
        case .form: session.spec
        case .document: documentSpec
        }
    }

    var isStreaming: Bool { activity != .idle }
    var hasSpec: Bool { spec?.root != nil }

    // MARK: Commands

    /// Generates a new spec, or refines the current one (edit mode) when one is shown.
    @discardableResult
    func generate(_ prompt: String) -> Task<Void, Never> {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = hasSpec ? spec : nil
        // Forms send the live (user-entered) state; a document's state is part of its spec.
        let state = current != nil && kind == .form ? session.store.state : nil
        // Snapshot now: changing provider or model later doesn't affect this run.
        let settings = options()
        let generator = generators(settings.provider)
        return start(.generating(prompt: prompt), initial: current) { bridge, controller, id in
            let instructions = try await controller.cachedSystemPrompt(bridge)
            let input = try await bridge.buildUserPrompt(prompt, currentSpec: current, state: state)
            let request = GenerationRequest(
                model: settings.model,
                instructions: instructions,
                input: input,
                reasoningEffort: settings.reasoningEffort
            )
            // The live client starts its HTTP request as soon as streamText is called.
            try controller.checkCurrent(id)
            return generator.streamText(request)
        }
    }

    /// Plays recorded JSONL through the same pipeline (no network). With `prompt` (scripted
    /// demos), the run shows as generating that prompt and edits the current spec, like ``generate(_:)``.
    @discardableResult
    func replay(_ jsonl: String, as prompt: String? = nil, delay: Duration = .milliseconds(25)) -> Task<Void, Never> {
        let initial = prompt != nil && hasSpec ? spec : nil
        return start(prompt.map { .generating(prompt: $0) } ?? .replaying, initial: initial) { _, _, _ in
            ReplayStream.stream(ReplayStream.chunks(of: jsonl), delay: delay)
        }
    }

    /// Shows a complete spec (offline examples).
    func load(_ spec: Spec) {
        cancelRun()
        resetOutput()
        replaceSpec(with: spec)
        let id = runID
        Task {
            guard let bridge = try? self.bridge() else { return }
            await self.validate(spec, with: bridge, runID: id)
        }
    }

    /// Stops the current stream, keeping what has rendered so far.
    func stop() {
        cancelRun()
    }

    func clear() {
        cancelRun()
        resetOutput()
        replaceSpec(with: nil)
    }

    /// Writes values read from a filled PDF into the document's `state` (JSON Pointers into
    /// it), so the next render shows them.
    func applyState(_ updates: [PDFPreviewModel.StateUpdate]) {
        guard kind == .document, !isStreaming, var json = spec?.json, !updates.isEmpty else { return }
        if json["state"]?.objectValue == nil { json = json.setting(.object([:]), at: "/state") }
        for update in updates where update.pointer.hasPrefix("/") {
            json = json.setting(update.value, at: "/state" + update.pointer)
        }
        setSpec(Spec(json: json))
    }

    /// Hides the validation banner (issues and the auto-fix notice).
    func dismissValidation() {
        issues = []
        didAutoFix = false
    }

    /// Presents data sent by the form's `submit` action. `dataRoot` is the state pointer the
    /// data was read from; `nil` detects it from the spec's submit bindings. `validated` is
    /// `false` for the `-submit` screenshot helper, which skips the action (and its validation).
    func showSubmission(_ data: JSONValue?, dataRoot: String? = nil, validated: Bool = true, date: Date = .now) {
        let data = data ?? .null
        let state = session.store.state
        let root = dataRoot ?? session.spec.flatMap { SubmissionSummary.dataRoot(in: $0, data: data, state: state) }
        let summary = session.spec.map {
            SubmissionSummary.spec(form: $0, data: data, dataRoot: root, state: state, submittedAt: date)
        }
        let fillable = session.spec.map { FillablePDFMapper.spec(form: $0, data: data, dataRoot: root, state: state) }
        submission = Submission(data: data, validated: validated, summary: summary, fillable: fillable)
    }

    func log(_ params: [String: JSONValue]) {
        let message = params["message"]?.stringValue ?? "Event logged"
        print("[FormDemo] log:", JSONValue.object(params).jsonString())
        show(Toast(message: message))
    }

    private func show(_ toast: Toast, for duration: Duration = .seconds(2)) {
        self.toast = toast
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: duration)
            if !Task.isCancelled { self.toast = nil }
        }
    }

    // MARK: Pipeline

    /// Creates the text stream for run `id`. Call ``checkCurrent(_:)`` after any await,
    /// before starting work that is expensive or has side effects.
    private typealias StreamFactory = @MainActor (JSONRenderBridge, GenerationController, Int) async throws
        -> AsyncThrowingStream<TextStreamEvent, any Error>

    private func start(_ activity: Activity, initial: Spec?, makeStream: @escaping StreamFactory) -> Task<Void, Never> {
        cancelRun()
        resetOutput()
        if initial == nil { replaceSpec(with: nil) }
        self.activity = activity
        runID += 1
        let id = runID
        let task = Task {
            await self.run(id: id, initial: initial, makeStream: makeStream)
        }
        self.task = task
        return task
    }

    /// Throws `CancellationError` once run `id` was stopped or superseded.
    private func checkCurrent(_ id: Int) throws {
        if Task.isCancelled || runID != id { throw CancellationError() }
    }

    private func run(id: Int, initial: Spec?, makeStream: StreamFactory) async {
        defer { if runID == id { activity = .idle; task = nil } }
        guard (try? checkCurrent(id)) != nil else { return }

        let bridge: JSONRenderBridge
        let compiler: SpecStreamCompiler
        let stream: AsyncThrowingStream<TextStreamEvent, any Error>
        do {
            bridge = try self.bridge()
            compiler = try await bridge.makeStreamCompiler(initial: initial)
            do {
                try checkCurrent(id)
                stream = try await makeStream(bridge, self, id)
            } catch {
                await compiler.dispose()
                throw error
            }
        } catch {
            if !(error is CancellationError), runID == id { errorMessage = error.localizedDescription }
            return
        }

        var streamError: (any Error)?
        do {
            for try await event in stream {
                try checkCurrent(id)
                switch event {
                case .text(let chunk):
                    rawJSONL += chunk
                    let update = try await compiler.push(chunk)
                    try checkCurrent(id)
                    if !update.newPatches.isEmpty {
                        patchCount += update.newPatches.count
                        setSpec(update.spec)
                    }
                case .servingModelChanged(let model):
                    // The fallback model continues the same output: keep the compiler (and its
                    // pending partial line), the raw text, the patches and the spec.
                    show(Toast(message: "Continued on \(Provider.anthropic.displayName(forModel: model))",
                               systemImage: "arrow.triangle.2.circlepath"), for: .seconds(4))
                }
            }
            // The stream ends without throwing when its consumer is cancelled.
            try checkCurrent(id)
        } catch {
            streamError = error
        }

        if let streamError {
            // Stopped, superseded or failed: free the compiler without flushing; keep the partial spec.
            await compiler.dispose()
            if !(streamError is CancellationError), runID == id {
                errorMessage = streamError.localizedDescription
            }
            return
        }

        // finish() flushes a trailing line without a newline (at most one more patch).
        let final: Spec
        do {
            final = try await compiler.finish()
        } catch {
            if runID == id { errorMessage = error.localizedDescription }
            return
        }
        guard runID == id else { return }
        if final != spec, final.root != nil {
            patchCount += 1
            setSpec(final)
        }

        guard patchCount > 0, final.root != nil else {
            errorMessage = initial == nil
                ? "The model returned no \(kind.noun). Try rephrasing your request."
                : "The model didn't change the \(kind.noun). Try rephrasing your request."
            return
        }
        await validate(final, with: bridge, runID: id)
    }

    /// Validates `spec`; if it is invalid, tries `autoFixSpec` and keeps the fix when it helps.
    private func validate(_ spec: Spec, with bridge: JSONRenderBridge, runID id: Int) async {
        do {
            let catalog = kind.catalog
            var report = try await bridge.validateSpec(spec, hostActions: kind.hostActions, catalog: catalog)
            if !report.valid {
                let fixed = try await bridge.autoFixSpec(spec, catalog: catalog)
                let fixedReport = try await bridge.validateSpec(fixed, hostActions: kind.hostActions, catalog: catalog)
                if fixed != spec, fixedReport.errorCount < report.errorCount {
                    guard runID == id else { return }
                    setSpec(fixed)
                    didAutoFix = true
                    report = fixedReport
                }
            }
            guard runID == id else { return }
            issues = report.issues
        } catch {
            guard runID == id else { return }
            errorMessage = "Validation failed: \(error.localizedDescription)"
        }
    }

    // MARK: Helpers

    /// Updates the current spec in place (streaming, auto-fix): form state is merged, not reset.
    private func setSpec(_ spec: Spec) {
        switch kind {
        case .form: session.spec = spec
        case .document: documentSpec = spec
        }
    }

    /// Starts over with `spec` (a fresh form session, so no state or validation carries over).
    private func replaceSpec(with spec: Spec?) {
        revision += 1
        switch kind {
        case .form: session = FormSession(spec: spec)
        case .document: documentSpec = spec
        }
    }

    private func cancelRun() {
        task?.cancel()
        task = nil
        runID += 1
        activity = .idle
    }

    private func resetOutput() {
        rawJSONL = ""
        patchCount = 0
        errorMessage = nil
        issues = []
        didAutoFix = false
    }

    private func bridge() throws -> JSONRenderBridge {
        if let bridgeInstance { return bridgeInstance }
        let bridge = try JSONRenderBridge()
        bridgeInstance = bridge
        return bridge
    }

    private func cachedSystemPrompt(_ bridge: JSONRenderBridge) async throws -> String {
        if let systemPrompt { return systemPrompt }
        let prompt = try await bridge.systemPrompt(customRules: kind.customRules, catalog: kind.catalog)
        systemPrompt = prompt
        return prompt
    }
}

/// Data received by the `submit` action.
struct Submission: Identifiable {
    let id = UUID()
    let data: JSONValue
    /// `false` when the sheet was opened without running the submit action's validation.
    var validated = true
    /// A PDF spec summarising the submitted fields ("Export as PDF").
    var summary: Spec?
    /// A fillable PDF form equivalent to the form, seeded with the submitted values.
    var fillable: Spec?

    var prettyJSON: String { data.jsonString(prettyPrinted: true) }
}

extension SpecValidation {
    var errorCount: Int { issues.filter(\.isError).count }
}
