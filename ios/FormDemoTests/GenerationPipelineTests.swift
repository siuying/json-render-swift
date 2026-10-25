@testable import FormDemo
import Foundation
import JSONRenderSwiftUI
import Testing

/// Drives ``GenerationController`` with a mock text stream instead of OpenAI.
@MainActor
@Suite("Generation pipeline")
struct GenerationPipelineTests {
    private func makeController(_ generator: MockGenerator) -> GenerationController {
        GenerationController(generator: generator) {
            GenerationOptions(model: "test-model", reasoningEffort: "low")
        }
    }

    private var registrationJSONL: String {
        get throws { try ExampleSpec.replayStream(for: .form) }
    }

    @Test func streamsRegistrationIntoTheExpectedSpec() async throws {
        let jsonl = try registrationJSONL
        let generator = MockGenerator(.chunks(ReplayStream.chunks(of: jsonl)))
        let controller = makeController(generator)

        await controller.generate("Sign-up form with password confirmation").value

        let expected = try #require(ExampleSpec.named("registration", kind: .form)).load()
        let spec = try #require(controller.spec)
        #expect(spec.root == "form")
        #expect(spec.json == expected.json)
        #expect(controller.rawJSONL == jsonl)
        #expect(controller.patchCount == jsonl.split(separator: "\n").count)
        #expect(controller.errorMessage == nil)
        #expect(controller.issues.isEmpty)
        #expect(!controller.isStreaming)
        #expect(controller.session.store.state.value(at: "/form/email") == .string(""))

        let request = try #require(generator.requests.first)
        #expect(request.model == "test-model")
        #expect(request.reasoningEffort == "low")
        #expect(request.instructions.contains("AVAILABLE COMPONENTS"))
        #expect(request.instructions.contains(#"custom action "log""#))
        #expect(request.input.contains("Sign-up form with password confirmation"))
    }

    @Test func formBuildsProgressivelyAndStopCancelsTheStream() async throws {
        let lines = try registrationJSONL.split(separator: "\n").map { $0 + "\n" }
        let generator = MockGenerator(.manual)
        let controller = makeController(generator)

        let task = controller.generate("Sign-up")
        let continuation = try await generator.waitForContinuation()
        for line in lines.prefix(4) { continuation.yield(.text(String(line))) }
        try await waitUntil { controller.spec?.elements["email"] != nil }

        #expect(controller.isStreaming)
        #expect(controller.spec?.root == "form")
        #expect(controller.spec?.elements["password"] == nil)

        controller.stop()
        await task.value
        #expect(!controller.isStreaming)
        #expect(controller.errorMessage == nil)
        #expect(controller.spec?.elements["email"] != nil, "partial form is kept")
        try await waitUntil { generator.wasTerminated }

        // Late chunks after Stop are ignored.
        continuation.yield(.text(String(lines[4])))
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.spec?.elements["password"] == nil)
    }

    @Test func followUpPromptRefinesTheCurrentForm() async throws {
        let generator = MockGenerator(.chunks(ReplayStream.chunks(of: try registrationJSONL)))
        let controller = makeController(generator)
        await controller.generate("Sign-up").value
        let session = controller.session
        session.store.set("ada@example.com", at: "/form/email")

        generator.behavior = .chunks([
            #"{"op":"add","path":"/elements/phone","value":{"type":"TextField","props":{"label":"Phone","value":{"$bindState":"/form/phone"},"keyboard":"phone"},"children":[]}}"# + "\n",
            #"{"op":"add","path":"/elements/account/children/-","value":"phone"}"# + "\n",
            #"{"op":"add","path":"/state/form/phone","value":""}"#,
        ])
        await controller.generate("Add a phone number").value

        let refine = try #require(generator.requests.last)
        #expect(refine.input.contains("Add a phone number"))
        #expect(refine.input.contains("confirm-password"), "edit mode sends the current spec")
        #expect(refine.input.contains("ada@example.com"), "edit mode sends the current state")

        let spec = try #require(controller.spec)
        #expect(controller.session === session, "refinement keeps the session")
        #expect(spec.elements["phone"]?.type == "TextField")
        #expect(spec.elements["account"]?.children.last == "phone")
        #expect(spec.elements["confirm-password"] != nil)
        #expect(session.store.state.value(at: "/form/email") == .string("ada@example.com"))
        #expect(session.store.state.value(at: "/form/phone") == .string(""))
        #expect(controller.rawJSONL.hasPrefix(#"{"op":"add","path":"/elements/phone""#))
    }

    @Test func stopBeforeTheRunStartsSendsNoRequest() async {
        let generator = MockGenerator(.chunks([]))
        let controller = makeController(generator)
        let task = controller.generate("Cancel me")
        controller.stop()
        await task.value
        #expect(generator.requests.isEmpty)

        // Superseded by a replay before it started.
        let superseded = controller.generate("Replaced")
        let replay = controller.replay(#"{"op":"add","path":"/root","value":"form"}"#, delay: .zero)
        await superseded.value
        await replay.value
        #expect(generator.requests.isEmpty)
        #expect(controller.errorMessage == nil)
    }

    @Test func stopBeforeTheRunStartsOpensNoConnection() async {
        let endpoint = CountingURLProtocol.register()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingURLProtocol.self]
        let client = OpenAIClient(endpoint: endpoint, session: URLSession(configuration: configuration), apiKey: { "sk-test" })
        let controller = GenerationController(generator: client) { GenerationOptions(model: "gpt-6-luna", reasoningEffort: nil) }
        for _ in 0..<20 {
            let task = controller.generate("Cancel me")
            controller.stop()
            await task.value
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(CountingURLProtocol.starts(for: endpoint) == 0)
        #expect(controller.errorMessage == nil)
    }

    @Test func refusedEditIsReported() async throws {
        let endpoint = StubURLProtocol.register(status: 200, body: """
        event: response.refusal.delta
        data: {"type":"response.refusal.delta","delta":"I can't help "}

        event: response.refusal.delta
        data: {"type":"response.refusal.delta","delta":"with that."}

        event: response.refusal.done
        data: {"type":"response.refusal.done","refusal":"I can't help with that."}

        event: response.completed
        data: {"type":"response.completed","response":{"status":"completed"}}


        """)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = OpenAIClient(endpoint: endpoint, session: URLSession(configuration: configuration), apiKey: { "sk-test" })
        let controller = GenerationController(generator: client) { GenerationOptions(model: "gpt-6-luna", reasoningEffort: nil) }
        let original = try #require(ExampleSpec.named("registration", kind: .form)).load()
        controller.load(original)

        await controller.generate("Something disallowed").value
        #expect(controller.errorMessage == "The model declined: I can't help with that.")
        #expect(controller.spec == original)
    }

    @Test func editWithoutPatchesIsReported() async throws {
        let generator = MockGenerator(.chunks(["Sure! I've updated the form for you."]))
        let controller = makeController(generator)
        let original = try #require(ExampleSpec.named("registration", kind: .form)).load()
        controller.load(original)

        await controller.generate("Make it nicer").value
        #expect(controller.errorMessage?.contains("didn't change the form") == true)
        #expect(controller.patchCount == 0)
        #expect(controller.spec == original)
    }

    @Test func editWhosePatchIsFlushedByFinishSucceeds() async throws {
        // The only patch has no trailing newline, so it is applied by finish(), not push().
        let generator = MockGenerator(.chunks([#"{"op":"replace","path":"/elements/form/props/title","value":"Join us"}"#]))
        let controller = makeController(generator)
        controller.load(try #require(ExampleSpec.named("registration", kind: .form)).load())

        await controller.generate("Rename the form").value
        #expect(controller.errorMessage == nil)
        #expect(controller.patchCount == 1)
        #expect(controller.spec?.elements["form"]?.props["title"] == .string("Join us"))
    }

    @Test func fallbackContinuesTheOutput() async throws {
        let generator = MockGenerator(.events([
            .text(#"{"op":"add","path":"/root","value":"form"}"# + "\n"),
            .text(#"{"op":"add","path":"/elements/form","value":{"type":"Form","props":{"title":"First"},"children":["note"]}}"# + "\n"),
            .servingModelChanged(model: "claude-sonnet-5-5"),
            .text(#"{"op":"add","path":"/elements/note","value":{"type":"Text","props":{"content":"kept"},"children":[]}}"# + "\n"),
        ]))
        let controller = makeController(generator)
        await controller.generate("Anything").value

        #expect(controller.errorMessage == nil)
        #expect(controller.spec?.elements["form"]?.props["title"] == .string("First"), "earlier patches are kept")
        #expect(controller.spec?.elements["note"]?.props["content"] == .string("kept"))
        #expect(controller.patchCount == 3)
        #expect(controller.rawJSONL.contains("First") && controller.rawJSONL.contains("kept"))
        #expect(controller.toast?.message == "Continued on Claude Sonnet 5.5")
    }

    @Test func fallbackInsideAJSONLLineKeepsThePendingLine() async throws {
        let generator = MockGenerator(.events([
            .text(#"{"op":"add","path":"/root","value":"form"}"# + "\n"),
            .text(#"{"op":"add","path":"/elements/form","value":{"type":"Form","#),
            .servingModelChanged(model: "claude-sonnet-5-5"),
            .text(#""props":{"title":"Joined"},"children":[]}}"# + "\n"),
        ]))
        let controller = makeController(generator)
        await controller.generate("Anything").value

        #expect(controller.errorMessage == nil)
        #expect(controller.spec?.elements["form"]?.props["title"] == .string("Joined"), "the split patch is completed")
        #expect(controller.patchCount == 2)
    }

    @Test func fallbackDuringAnEditKeepsEarlierPatches() async throws {
        let generator = MockGenerator(.chunks([]))
        let controller = makeController(generator)
        controller.load(try #require(ExampleSpec.named("registration", kind: .form)).load())
        generator.behavior = .events([
            .text(#"{"op":"replace","path":"/elements/form/props/title","value":"Join"}"# + "\n"),
            .servingModelChanged(model: "claude-sonnet-5-5"),
            .text(#"{"op":"replace","path":"/elements/form/props/subtitle","value":"Quick"}"# + "\n"),
        ])
        await controller.generate("Rename").value

        #expect(controller.errorMessage == nil)
        #expect(controller.spec?.elements["form"]?.props["title"] == .string("Join"))
        #expect(controller.spec?.elements["form"]?.props["subtitle"] == .string("Quick"))
        #expect(controller.patchCount == 2)
    }

    @Test func fallbackThroughTheAnthropicClient() async throws {
        let line = { (patch: String) in
            let escaped = String(decoding: try! JSONEncoder().encode(patch + "\n"), as: UTF8.self)
            return "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\(escaped)}}\n\n"
        }
        let body = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{}}\n\n"
            + line(#"{"op":"replace","path":"/elements/doc/props/title","value":"New title"}"#)
            + "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"fallback\",\"from\":{\"model\":\"claude-opus-5-5\"},\"to\":{\"model\":\"claude-sonnet-5-5\"}}}\n\n"
            + line(#"{"op":"replace","path":"/elements/doc/props/author","value":"New author"}"#)
            + "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        let endpoint = StubURLProtocol.register(status: 200, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let client = AnthropicClient(endpoint: endpoint, session: URLSession(configuration: configuration), apiKey: { "sk-ant" })
        let controller = GenerationController(kind: .document, generator: client) {
            GenerationOptions(provider: .anthropic, model: "claude-opus-5-5", reasoningEffort: nil)
        }
        controller.load(try #require(ExampleSpec.named("invoice", kind: .document)).load())
        await controller.generate("Retitle").value

        #expect(controller.errorMessage == nil)
        #expect(controller.patchCount == 2)
        #expect(controller.spec?.elements["doc"]?.props["title"] == .string("New title"))
        #expect(controller.spec?.elements["doc"]?.props["author"] == .string("New author"))
    }

    @Test func truncationIsAnErrorAndKeepsWhatArrived() async throws {
        for error in [AnthropicError.contextWindowExceeded, AnthropicError.cutOff, OpenAIError.streamFailed("Response was cut off (max_output_tokens).")] as [any Error] {
            let generator = MockGenerator(.chunks([]))
            let controller = makeController(generator)
            controller.load(try #require(ExampleSpec.named("registration", kind: .form)).load())
            generator.behavior = .partialThenFailure(
                [#"{"op":"replace","path":"/elements/form/props/title","value":"Partial"}"# + "\n"], error
            )
            await controller.generate("Big edit").value
            #expect(controller.errorMessage?.hasPrefix("Response was cut off") == true, "\(error)")
            #expect(controller.spec?.elements["form"]?.props["title"] == .string("Partial"))
            #expect(controller.issues.isEmpty, "a truncated run isn't validated as complete")
        }
    }

    @Test func providerIsChosenWhenTheRunStarts() async throws {
        let openAI = MockGenerator(.chunks([#"{"op":"add","path":"/root","value":"form"}"# + "\n"]))
        let anthropic = MockGenerator(.chunks([#"{"op":"add","path":"/root","value":"form"}"# + "\n"]))
        let settings = OptionsBox(GenerationOptions(provider: .anthropic, model: "claude-haiku-5-5", reasoningEffort: "low"))
        let controller = GenerationController(
            generators: { $0 == .openAI ? openAI : anthropic },
            options: { settings.value }
        )
        let task = controller.generate("Form")
        settings.value = GenerationOptions(provider: .openAI, model: "gpt-6-luna", reasoningEffort: nil)  // switched mid-run
        await task.value

        #expect(openAI.requests.isEmpty)
        #expect(anthropic.requests.first?.model == "claude-haiku-5-5")
        #expect(anthropic.requests.first?.reasoningEffort == "low")

        await controller.generate("Again").value
        #expect(openAI.requests.first?.model == "gpt-6-luna")
    }

    @Test func streamErrorsAreShown() async {
        let generator = MockGenerator(.failure(OpenAIError.http(status: 401, message: "Incorrect API key provided")))
        let controller = makeController(generator)
        await controller.generate("Event RSVP").value
        #expect(controller.errorMessage?.contains("HTTP 401") == true)
        #expect(controller.errorMessage?.contains("Incorrect API key provided") == true)
        #expect(!controller.isStreaming)
    }

    @Test func proseWithoutPatchesIsAnError() async {
        let controller = makeController(MockGenerator(.chunks(["Sorry, I can't help with that."])))
        await controller.generate("Event RSVP").value
        #expect(controller.errorMessage?.contains("no form") == true)
    }

    @Test func invalidSpecIsAutoFixed() async throws {
        // `visible` and `on` inside props are a common LLM mistake that autoFixSpec repairs.
        let generator = MockGenerator(.chunks([
            #"{"op":"add","path":"/root","value":"form"}"# + "\n",
            #"{"op":"add","path":"/elements/form","value":{"type":"Form","props":{"title":"Fix me"},"children":["section"]}}"# + "\n",
            #"{"op":"add","path":"/elements/section","value":{"type":"Section","props":{},"children":["name"]}}"# + "\n",
            #"{"op":"add","path":"/elements/name","value":{"type":"TextField","props":{"label":"Name","value":{"$bindState":"/form/name"},"visible":{"$state":"/form/show"}},"children":[]}}"# + "\n",
        ]))
        let controller = makeController(generator)
        await controller.generate("Broken").value

        #expect(controller.errorMessage == nil)
        #expect(controller.didAutoFix)
        let name = try #require(controller.spec?.elements["name"])
        #expect(name.props["visible"] == nil)
        #expect(name.visible == .object(["$state": .string("/form/show")]))

        controller.dismissValidation()
        #expect(!controller.didAutoFix)
        #expect(controller.issues.isEmpty)
    }

    @Test func handledCustomActionsAreNotReported() async {
        let controller = makeController(MockGenerator(.chunks([
            #"{"op":"add","path":"/root","value":"form"}"# + "\n",
            #"{"op":"add","path":"/elements/form","value":{"type":"Form","props":{},"children":["draft"]}}"# + "\n",
            #"{"op":"add","path":"/elements/draft","value":{"type":"Button","props":{"label":"Save draft"},"on":{"press":{"action":"log","params":{"message":"Draft saved"}}},"children":[]}}"# + "\n",
        ])))
        await controller.generate("Draft").value
        #expect(controller.errorMessage == nil)
        #expect(controller.issues.isEmpty)
    }

    @Test func replayUsesTheSamePipeline() async throws {
        let controller = makeController(MockGenerator(.chunks([])))
        await controller.replay(try registrationJSONL, delay: .zero).value
        let expected = try #require(ExampleSpec.named("registration", kind: .form)).load()
        #expect(controller.spec?.json == expected.json)
        #expect(controller.issues.isEmpty)
    }

    @Test func examplesLoadIntoAFreshSession() throws {
        let controller = makeController(MockGenerator(.chunks([])))
        for example in ExampleSpec.forms {
            let spec = try example.load()
            let previous = controller.session
            controller.load(spec)
            #expect(controller.session !== previous)
            #expect(controller.spec == spec)
            #expect(controller.rawJSONL.isEmpty)
        }
        controller.clear()
        #expect(!controller.hasSpec)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

/// Counts connections per URL and never responds (holds the request open).
final class CountingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [URL: Int] = [:]

    static func register() -> URL {
        let url = URL(string: "https://counting.test/\(UUID().uuidString)/v1/responses")!
        lock.withLock { counts[url] = 0 }
        return url
    }

    static func starts(for url: URL) -> Int {
        lock.withLock { counts[url] ?? 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.counts[url, default: 0] += 1 }
    }

    override func stopLoading() {}
}

@MainActor
final class OptionsBox {
    var value: GenerationOptions
    init(_ value: GenerationOptions) { self.value = value }
}

/// A scripted ``TextGenerating``.
final class MockGenerator: TextGenerating, @unchecked Sendable {
    enum Behavior {
        case chunks([String])
        case events([TextStreamEvent])
        case partialThenFailure([String], any Error)
        case failure(any Error)
        /// The test drives the stream through ``waitForContinuation()``.
        case manual
    }

    private let lock = NSLock()
    private var _behavior: Behavior
    private var _requests: [GenerationRequest] = []
    private var _continuation: AsyncThrowingStream<TextStreamEvent, any Error>.Continuation?
    private var _terminated = false

    init(_ behavior: Behavior) {
        _behavior = behavior
    }

    var behavior: Behavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }

    var requests: [GenerationRequest] { lock.withLock { _requests } }
    var wasTerminated: Bool { lock.withLock { _terminated } }

    func streamText(_ request: GenerationRequest) -> AsyncThrowingStream<TextStreamEvent, any Error> {
        let behavior = lock.withLock {
            _requests.append(request)
            return _behavior
        }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TextStreamEvent.self)
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            lock.withLock { _terminated = true }
        }
        switch behavior {
        case .chunks(let chunks):
            for chunk in chunks { continuation.yield(.text(chunk)) }
            continuation.finish()
        case .events(let events):
            for event in events { continuation.yield(event) }
            continuation.finish()
        case .failure(let error):
            continuation.finish(throwing: error)
        case .partialThenFailure(let chunks, let error):
            for chunk in chunks { continuation.yield(.text(chunk)) }
            continuation.finish(throwing: error)
        case .manual:
            lock.withLock { _continuation = continuation }
        }
        return stream
    }

    func waitForContinuation() async throws -> AsyncThrowingStream<TextStreamEvent, any Error>.Continuation {
        for _ in 0..<500 {
            if let continuation = lock.withLock({ _continuation }) { return continuation }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }
}
