import Foundation

/// Streams text from the Anthropic Messages API (`POST /v1/messages`, `stream: true`)
/// over plain URLSession; there is no official Swift SDK.
struct AnthropicClient: TextGenerating {
    static let defaultEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2023-06-01"
    static let maxTokens = 64_000
    /// Models that get server-side refusal fallback (`fallbacks: "default"` + beta header).
    static let fallbackModels: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5"]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    var endpoint: URL = Self.defaultEndpoint
    var session: URLSession = .shared
    /// Returns the API key at request time (Keychain first, then `ANTHROPIC_API_KEY`).
    var apiKey: @Sendable () -> String?

    func streamText(_ request: GenerationRequest) -> AsyncThrowingStream<TextStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The HTTP request for a generation. Internal so tests can check headers and body.
    func makeURLRequest(_ request: GenerationRequest) throws -> URLRequest {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw AnthropicError.missingAPIKey
        }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if Self.fallbackModels.contains(request.model) {
            urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.timeoutInterval = 120
        urlRequest.httpBody = try JSONEncoder().encode(AnthropicRequestBody(request))
        return urlRequest
    }

    private func run(_ request: GenerationRequest, yield: (TextStreamEvent) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: makeURLRequest(request))
        guard let http = response as? HTTPURLResponse else { throw AnthropicError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 64 * 1024 { break }
            }
            throw AnthropicError.http(
                status: http.statusCode, body: body, retryAfter: http.value(forHTTPHeaderField: "retry-after")
            )
        }

        var parser = SSEParser()
        for try await byte in bytes {
            guard let event = parser.push(byte) else { continue }
            if try handle(event, yield: yield) { return }
        }
        if let event = parser.finish(), try handle(event, yield: yield) { return }
        try Task.checkCancellation()
        throw AnthropicError.streamEndedEarly
    }

    /// Returns `true` once the message is complete.
    private func handle(_ event: SSEEvent, yield: (TextStreamEvent) -> Void) throws -> Bool {
        switch try AnthropicStreamEvent(event) {
        case .textDelta(let text):
            if !text.isEmpty { yield(.text(text)) }
        case .fallback(let model):
            yield(.servingModelChanged(model: model))
        case .stop(let reason, let explanation):
            switch reason {
            case "refusal": throw AnthropicError.refused(explanation ?? "")
            case "max_tokens": throw AnthropicError.cutOff
            case "model_context_window_exceeded": throw AnthropicError.contextWindowExceeded
            default: break
            }
        case .messageStop:
            return true
        case .error(let type, let message):
            throw AnthropicError.streamError(type: type, message: message)
        case .ignored:
            break
        }
        return false
    }
}

/// JSON body of `POST /v1/messages`. Deliberately has no `thinking`, `temperature`,
/// `top_p`, `top_k` or assistant prefill: current models reject them.
struct AnthropicRequestBody: Encodable, Equatable {
    struct CacheControl: Encodable, Equatable {
        var type = "ephemeral"
    }
    struct SystemBlock: Encodable, Equatable {
        var type = "text"
        var text: String
        var cacheControl = CacheControl()

        enum CodingKeys: String, CodingKey {
            case type, text
            case cacheControl = "cache_control"
        }
    }
    struct Message: Encodable, Equatable {
        var role = "user"
        var content: String
    }
    struct OutputConfig: Encodable, Equatable {
        var effort: String
    }

    var model: String
    var maxTokens = AnthropicClient.maxTokens
    var stream = true
    var system: [SystemBlock]
    var messages: [Message]
    var outputConfig: OutputConfig?
    var fallbacks: String?

    enum CodingKeys: String, CodingKey {
        case model, stream, system, messages, fallbacks
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }

    init(_ request: GenerationRequest) {
        model = request.model
        system = [SystemBlock(text: request.instructions)]
        messages = [Message(content: request.input)]
        outputConfig = request.reasoningEffort.map(OutputConfig.init(effort:))
        fallbacks = AnthropicClient.fallbackModels.contains(request.model) ? "default" : nil
    }
}
