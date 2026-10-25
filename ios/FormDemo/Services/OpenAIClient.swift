import Foundation

/// Streams text from the OpenAI Responses API (`POST /v1/responses`, `stream: true`).
struct OpenAIClient: TextGenerating {
    static let defaultEndpoint = URL(string: "https://api.openai.com/v1/responses")!

    var endpoint: URL = Self.defaultEndpoint
    var session: URLSession = .shared
    /// Returns the API key at request time (Keychain first, then `OPENAI_API_KEY`).
    var apiKey: @Sendable () -> String?

    func streamText(_ request: GenerationRequest) -> AsyncThrowingStream<TextStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request) { continuation.yield(.text($0)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The HTTP request for a generation. Internal so tests can check the body.
    func makeURLRequest(_ request: GenerationRequest) throws -> URLRequest {
        guard let key = apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw OpenAIError.missingAPIKey
        }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = 120
        urlRequest.httpBody = try JSONEncoder().encode(RequestBody(request))
        return urlRequest
    }

    private func run(_ request: GenerationRequest, yield: (String) -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: makeURLRequest(request))
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 64 * 1024 { break }
            }
            throw OpenAIError.http(status: http.statusCode, message: OpenAIError.message(fromErrorBody: body))
        }

        var parser = SSEParser()
        var refusal: String?
        for try await byte in bytes {
            guard let event = parser.push(byte) else { continue }
            if try handle(event, refusal: &refusal, yield: yield) { return }
        }
        if let event = parser.finish(), try handle(event, refusal: &refusal, yield: yield) { return }
        try Task.checkCancellation()
        throw OpenAIError.streamEndedEarly
    }

    /// Returns `true` once the response is complete. A refusal surfaces as
    /// ``OpenAIError/refused(_:)`` when the response completes.
    private func handle(_ event: SSEEvent, refusal: inout String?, yield: (String) -> Void) throws -> Bool {
        switch try ResponsesStreamEvent(event) {
        case .textDelta(let text):
            if !text.isEmpty { yield(text) }
            return false
        case .refusalDelta(let text):
            refusal = (refusal ?? "") + text
            return false
        case .refusal(let text):
            refusal = text.isEmpty ? (refusal ?? "") : text
            return false
        case .completed:
            if let refusal { throw OpenAIError.refused(refusal) }
            return true
        case .failed(let message):
            throw OpenAIError.streamFailed(message)
        case .ignored:
            return false
        }
    }
}

/// JSON body of `POST /v1/responses`.
struct RequestBody: Encodable, Equatable {
    struct Reasoning: Encodable, Equatable {
        var effort: String
    }

    var model: String
    var instructions: String
    var input: String
    var stream = true
    var store = false
    var reasoning: Reasoning?

    init(_ request: GenerationRequest) {
        model = request.model
        instructions = request.instructions
        input = request.input
        reasoning = request.reasoningEffort.map(Reasoning.init(effort:))
    }
}
