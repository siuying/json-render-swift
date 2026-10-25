import JSONRenderSwiftUI
import SwiftUI
import UIKit

/// One mode's screen: the rendered form or PDF preview (or its JSON/JSONL), a toolbar
/// and the floating prompt bar.
struct WorkspaceView: View {
    let kind: GenerationKind
    let launchOptions: LaunchOptions

    @Environment(GenerationController.self) private var controller
    @Environment(AppSettings.self) private var settings
    @State private var mode: ViewMode = .ui
    @State private var prompt = ""
    @State private var isShowingSettings = false
    @State private var isConfirmingClear = false
    @State private var notice: String?
    @State private var submissionTab: SubmissionSheet.Tab = .data
    /// The document preview (documents only); outlives tab switches so form edits persist.
    @State private var pdfPreview = PDFPreviewModel()
    @State private var filledValues: PDFPreviewModel.FilledValues?

    var body: some View {
        @Bindable var controller = controller
        NavigationStack {
            content
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(controller.hasSpec && kind == .form ? .automatic : .inline)
                .toolbar { toolbar }
                .safeAreaBar(edge: .top) {
                    if controller.hasSpec {
                        Picker("View", selection: $mode) {
                            ForEach(ViewMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomPanel }
                .overlay(alignment: .top) { toastView }
        }
        .sheet(item: $controller.submission) { SubmissionSheet(submission: $0, tab: submissionTab) }
        .sheet(isPresented: $isShowingSettings) { SettingsView() }
        .sheet(item: $filledValues) { values in
            FilledValuesSheet(values: values) {
                controller.applyState(values.updates)
                withAnimation(.snappy) { notice = "Applied \(values.updates.count) values to state" }
                clearNotice()
            }
        }
        .confirmationDialog("Clear the current \(kind.noun)?", isPresented: $isConfirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                controller.clear()
                pdfPreview.reset()
                prompt = ""
                mode = .ui
            }
        }
        .task { await applyLaunchOptions() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !controller.hasSpec {
            if controller.isStreaming {
                ProgressView("Waiting for the first patch…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    kind: kind,
                    onSuggestion: { send($0) },
                    onExample: load,
                    onReplay: { replay() }
                )
            }
        } else {
            switch mode {
            case .ui:
                switch kind {
                case .form: FormCanvas(session: controller.session)
                case .document:
                    DocumentPreview(
                        spec: controller.spec, revision: controller.revision,
                        isStreaming: controller.isStreaming, model: pdfPreview
                    )
                }
            case .json:
                CodeView(blocks: jsonBlocks, onCopy: copy)
            case .jsonl:
                CodeView(blocks: [
                    CodeBlock(
                        title: "JSONL stream · \(controller.patchCount) patches",
                        text: controller.rawJSONL,
                        placeholder: "Examples load the finished spec directly, so there is no stream. Generate a \(kind.noun) or use Replay stream to see one."
                    ),
                ], onCopy: copy)
            }
        }
    }

    private var jsonBlocks: [CodeBlock] {
        let spec = CodeBlock(title: "Spec", text: specJSON)
        switch kind {
        case .form:
            return [spec, CodeBlock(title: "State · live", text: controller.session.store.state.jsonString(prettyPrinted: true))]
        case .document:
            return [spec]
        }
    }

    private var specJSON: String {
        controller.spec?.json.jsonString(prettyPrinted: true) ?? ""
    }

    private var navigationTitle: String {
        guard controller.hasSpec, let spec = controller.spec else { return "" }
        switch kind {
        case .form:
            guard let title = spec.rootElement?.props["title"]?.stringValue, !title.isEmpty else { return "Form Demo" }
            return title
        case .document:
            return PDFExport(spec: spec).title
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Section("Offline examples") {
                    ForEach(kind.examples) { example in
                        Button(example.title, systemImage: example.systemImage) { load(example) }
                    }
                }
                Section("Recorded streams") {
                    ForEach(kind.replays) { stream in
                        Button(stream.title, systemImage: stream.systemImage) { replay(stream.id) }
                    }
                }
            } label: {
                Label("Examples", systemImage: "square.stack")
            }
            .disabled(controller.isStreaming)
        }
        if kind == .document, pdfPreview.hasForm, controller.hasSpec, !controller.isStreaming,
           pdfPreview.isShowing(controller.spec, revision: controller.revision) {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Read filled values", systemImage: "list.bullet.clipboard", action: readFilledValues)
            }
        }
        if kind == .document, let spec = controller.spec, controller.hasSpec, !controller.isStreaming {
            ToolbarItem(placement: .topBarTrailing) {
                let export = pdfPreview.export(for: spec, revision: controller.revision)
                ShareLink(item: export, preview: SharePreview(export.fileName, image: Image(systemName: "doc.richtext"))) {
                    Label("Share PDF", systemImage: "square.and.arrow.up")
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("Copy JSON", systemImage: "doc.on.doc") { copy(specJSON) }
                    .disabled(!controller.hasSpec)
                Button("Clear", systemImage: "trash", role: .destructive) { isConfirmingClear = true }
                    .disabled(!controller.hasSpec && !controller.isStreaming)
                Divider()
                Button("Settings", systemImage: "gearshape") { isShowingSettings = true }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 8) {
            if let message = controller.errorMessage {
                MessageBanner(
                    style: .error,
                    title: "Something went wrong",
                    message: message,
                    actionTitle: settings.apiKey == nil ? "Settings" : nil,
                    action: { isShowingSettings = true },
                    onDismiss: { controller.errorMessage = nil }
                )
            } else if !controller.issues.isEmpty || controller.didAutoFix {
                IssuesBanner(
                    issues: controller.issues,
                    didAutoFix: controller.didAutoFix,
                    onDismiss: controller.dismissValidation
                )
            }
            if controller.isStreaming {
                StreamingStatus(activity: controller.activity, patchCount: controller.patchCount)
            }
            PromptBar(
                text: $prompt,
                placeholder: controller.hasSpec ? kind.editPrompt : kind.newPrompt,
                isStreaming: controller.isStreaming,
                onSend: { send(prompt) },
                onStop: controller.stop
            )
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.snappy, value: controller.errorMessage)
        .animation(.snappy, value: controller.issues)
        .animation(.snappy, value: controller.isStreaming)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = notice.map({ Toast(message: $0) }) ?? controller.toast {
            Label(toast.message, systemImage: toast.systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Actions

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !controller.isStreaming else { return }
        prompt = ""
        mode = .ui
        controller.generate(text)
    }

    private func load(_ example: ExampleSpec) {
        do {
            let spec = try example.load()
            pdfPreview.reset()
            controller.load(spec)
            mode = .ui
        } catch {
            controller.errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func replay(_ id: String? = nil) -> Task<Void, Never>? {
        do {
            let task = controller.replay(try ExampleSpec.replayStream(named: id ?? kind.replays[0].id))
            mode = .ui
            return task
        } catch {
            controller.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func readFilledValues() {
        do {
            filledValues = try pdfPreview.filledValues()
        } catch {
            controller.errorMessage = "Couldn't read the form: \(error.localizedDescription)"
        }
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        withAnimation(.snappy) { notice = "Copied" }
        clearNotice()
    }

    private func clearNotice() {
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.snappy) { notice = nil }
        }
    }

    private func applyLaunchOptions() async {
        switch kind {
        case .form:
            if let id = launchOptions.example, let example = ExampleSpec.named(id, kind: .form) { load(example) }
        case .document:
            if let id = launchOptions.pdfExample, let example = ExampleSpec.named(id, kind: .document) { load(example) }
        }
        guard launchOptions.mode == kind else { return }
        if let id = launchOptions.replay { await replay(id.isEmpty ? nil : id)?.value }
        if let tab = launchOptions.tab { mode = tab }
        #if DEBUG
        if let id = launchOptions.demo {
            do {
                try await DemoScript.named(id).run(
                    controller: controller,
                    setPrompt: { prompt = $0 },
                    openSubmission: { submissionTab = $0 }
                )
            } catch {
                controller.errorMessage = error.localizedDescription
            }
        }
        #endif
        if kind == .form {
            if launchOptions.validate { controller.session.validateAll() }
            if launchOptions.submit {
                let state = controller.session.store.state
                submissionTab = launchOptions.submitFillable ? .fillable : launchOptions.submitPDF ? .pdf : .data
                if let form = state.value(at: "/form") {
                    controller.showSubmission(form, dataRoot: "/form", validated: false)
                } else {
                    controller.showSubmission(state, dataRoot: "", validated: false)
                }
            }
        }
        if launchOptions.settings { isShowingSettings = true }
        if kind == .document, launchOptions.readValues || launchOptions.demoFill {
            for _ in 0..<100 where !pdfPreview.isShowing(controller.spec, revision: controller.revision) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if launchOptions.demoFill {
                pdfPreview.fill(["firstName": "Alex", "lastName": "Rivera", "employer": "Contoso Ltd."])
            }
            if launchOptions.readValues { readFilledValues() }
        }
    }
}

/// The rendered form with the app's action handlers and component overrides.
private struct FormCanvas: View {
    let session: FormSession
    @Environment(GenerationController.self) private var controller

    var body: some View {
        let controller = controller
        JSONRenderView(session: session)
            .onJSONRenderAction("submit") { params, _ in
                controller.showSubmission(params["data"])
            }
            .onJSONRenderAction("log") { params, _ in
                controller.log(params)
            }
            .jsonRenderComponent("Button") { context in
                if context.props.string("style") == "borderedProminent" {
                    ProminentFormButton(context: context)
                } else if let standard = ComponentRegistry.standard.renderer(for: "Button") {
                    standard(context)
                }
            }
            .scrollDismissesKeyboard(.interactively)
    }
}
