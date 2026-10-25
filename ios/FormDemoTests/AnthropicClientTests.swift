@testable import FormDemo
import Foundation
import Testing

@Suite("Anthropic client")
struct AnthropicClientTests {
    private func request(model: String = "claude-sonnet-5-5", effort: String? = nil) -> GenerationRequest {
        GenerationRequest(model: model, instructions: "SYSTEM PROMPT", input: "USER PROMPT", reasoningEffort: effort)
    }

    private func client(key: String? = "sk-ant-test", endpoint: URL = AnthropicClient.defaultEndpoint) -> AnthropicClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return AnthropicClient(endpoint: endpoint, session: URLSession(configuration: configuration), apiKey: { key })
    }

    private func body(_ urlRequest: URLRequest) throws -> NSDictionary {
        let data = try #require(urlRequest.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    // MARK: Request construction

    @Test func exactRequestForHaiku() throws {
        let urlRequest = try client().makeURLRequest(request(model: "claude-haiku-5-5"))
        #expect(urlRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(urlRequest.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == nil)

        let expected: NSDictionary = [
            "model": "claude-haiku-5-5",
            "max_tokens": 64000,
            "stream": true,
            "system": [["type": "text", "text": "SYSTEM PROMPT", "cache_control": ["type": "ephemeral"]]],
            "messages": [["role": "user", "content": "USER PROMPT"]],
        ]
        #expect(try body(urlRequest) == expected)
    }

    @Test(arguments: ["claude-opus-5-5", "claude-sonnet-5-5"])
    func fallbacksForOpusAndSonnet(model: String) throws {
        let urlRequest = try client().makeURLRequest(request(model: model))
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let json = try body(urlRequest)
        #expect(json["fallbacks"] as? String == "default")
        #expect(json["model"] as? String == model)
    }

    @Test(arguments: ["claude-fable-5", "claude-haiku-5-5", "claude-custom"])
    func noFallbacksForOtherModels(model: String) throws {
        let urlRequest = try client().makeURLRequest(request(model: model))
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-beta") == nil)
        #expect(try body(urlRequest)["fallbacks"] == nil)
    }

    @Test func effortIsSentOnlyWhenChosen() throws {
        let withEffort = try body(client().makeURLRequest(request(effort: "low")))
        #expect(withEffort["output_config"] as? NSDictionary == ["effort": "low"])
        let modelDefault = try body(client().makeURLRequest(request()))
        #expect(modelDefault["output_config"] == nil)
    }

    @Test func neverSendsThinkingOrSamplingParameters() throws {
        for model in Provider.anthropic.models.map(\.id) {
            for effort in [nil] + Provider.anthropic.efforts {
                let keys = Set(try body(client().makeURLRequest(request(model: model, effort: effort))).allKeys.compactMap { $0 as? String })
                #expect(keys.isDisjoint(with: ["thinking", "temperature", "top_p", "top_k"]))
                #expect(keys.isSubset(of: ["model", "max_tokens", "stream", "system", "messages", "output_config", "fallbacks"]))
            }
        }
        let messages = try #require(try body(client().makeURLRequest(request()))["messages"] as? [NSDictionary])
        #expect(messages.count == 1, "no assistant prefill")
    }

    @Test(arguments: [nil, "", "  "])
    func missingKeyThrows(key: String?) {
        #expect(throws: AnthropicError.missingAPIKey) { try client(key: key).makeURLRequest(request()) }
        #expect(AnthropicError.missingAPIKey.errorDescription?.contains("Anthropic") == true)
        #expect(AnthropicError.missingAPIKey.errorDescription?.contains("ANTHROPIC_API_KEY") == true)
    }

    // MARK: Stream events

    private func decode(_ data: String, event: String? = nil) throws -> AnthropicStreamEvent {
        try AnthropicStreamEvent(SSEEvent(event: event, data: data))
    }

    @Test func decodesEvents() throws {
        #expect(try decode(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"{\"op\""}}"#) == .textDelta(#"{"op""#))
        #expect(try decode(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#) == .ignored(type: "content_block_delta"))
        #expect(try decode(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#) == .ignored(type: "content_block_delta"))
        #expect(try decode(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#) == .ignored(type: "content_block_start"))
        #expect(try decode(#"{"type":"content_block_start","index":0,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-sonnet-5-5"}}}"#) == .fallback(model: "claude-sonnet-5-5"))
        #expect(try decode(#"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"explanation":"Not allowed."}},"usage":{"output_tokens":3}}"#) == .stop(reason: "refusal", explanation: "Not allowed."))
        #expect(try decode(#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":64000}}"#) == .stop(reason: "max_tokens", explanation: nil))
        #expect(try decode(#"{"type":"message_delta","delta":{},"usage":{"output_tokens":1}}"#) == .ignored(type: "message_delta"))
        #expect(try decode(#"{"type":"message_stop"}"#) == .messageStop)
        #expect(try decode(#"{"type":"ping"}"#, event: "ping") == .ignored(type: "ping"))
        #expect(try decode(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#, event: "error") == .error(type: "overloaded_error", message: "Overloaded"))
        #expect(throws: AnthropicError.self) { try decode("{oops", event: "content_block_delta") }
    }

    private static func sse(_ events: [(String, String)]) -> String {
        events.map { "event: \($0.0)\ndata: \($0.1)\n\n" }.joined()
    }

    private static let start = ("message_start", #"{"type":"message_start","message":{"id":"msg_1","model":"claude-opus-5-5","content":[]}}"#)
    private static let stop = ("message_stop", #"{"type":"message_stop"}"#)

    private static func text(_ text: String, index: Int = 1) -> (String, String) {
        let escaped = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
        return ("content_block_delta", #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":\#(escaped)}}"#)
    }

    private func events(_ body: String, model: String = "claude-opus-5-5") async throws -> [TextStreamEvent] {
        let endpoint = StubURLProtocol.register(status: 200, body: body)
        var events: [TextStreamEvent] = []
        for try await event in client(endpoint: endpoint).streamText(request(model: model)) {
            events.append(event)
        }
        return events
    }

    @Test func streamsTextAndIgnoresThinkingAndPings() async throws {
        let body = Self.sse([
            Self.start,
            ("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            ("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me plan."}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            ("ping", #"{"type":"ping"}"#),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            Self.text(#"{"op":"add","#),
            Self.text(#""path":"/root","value":"form"}"# + "\n"),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":20}}"#),
            Self.stop,
        ])
        #expect(try await events(body) == [.text(#"{"op":"add","#), .text(#""path":"/root","value":"form"}"# + "\n")])
    }

    @Test func fallbackBlockIsANotification() async throws {
        let body = Self.sse([
            Self.start,
            Self.text("first half ", index: 0),
            ("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-sonnet-5-5"}}}"#),
            ("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            Self.text("second half\n", index: 2),
            Self.stop,
        ])
        #expect(try await events(body) == [
            .text("first half "), .servingModelChanged(model: "claude-sonnet-5-5"), .text("second half\n"),
        ])
    }

    @Test func contextWindowExhaustionIsCutOff() async {
        let body = Self.sse([
            Self.start, Self.text("partial"),
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"model_context_window_exceeded"}}"#), Self.stop,
        ])
        await #expect(throws: AnthropicError.contextWindowExceeded) { _ = try await events(body) }
        #expect(AnthropicError.contextWindowExceeded.errorDescription?.hasPrefix("Response was cut off") == true)
    }

    @Test func refusalThrowsWithExplanation() async {
        let body = Self.sse([
            Self.start,
            ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"explanation":"I can't help with that."}}}"#),
            Self.stop,
        ])
        await #expect(throws: AnthropicError.refused("I can't help with that.")) { _ = try await events(body) }
        #expect(AnthropicError.refused("No.").errorDescription == "The model declined: No.")
    }

    @Test func maxTokensIsCutOff() async {
        let body = Self.sse([Self.start, Self.text("partial"), ("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#), Self.stop])
        await #expect(throws: AnthropicError.cutOff) { _ = try await events(body) }
        #expect(AnthropicError.cutOff.errorDescription?.hasPrefix("Response was cut off") == true)
    }

    @Test func midStreamErrorThrows() async {
        let body = Self.sse([Self.start, Self.text("partial"), ("error", #"{"type":"error","error":{"type":"api_error","message":"Internal server error"}}"#)])
        await #expect(throws: AnthropicError.streamError(type: "api_error", message: "Internal server error")) { _ = try await events(body) }
    }

    @Test func truncatedStreamThrows() async {
        await #expect(throws: AnthropicError.streamEndedEarly) { _ = try await events(Self.sse([Self.start, Self.text("partial")])) }
    }

    // MARK: HTTP errors

    @Test func httpErrorMapping() async {
        let body = { (type: String, message: String) in Data(#"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#.utf8) }
        #expect(AnthropicError.http(status: 401, body: body("authentication_error", "invalid x-api-key"), retryAfter: nil)
            == .invalidAPIKey(message: "invalid x-api-key"))
        #expect(AnthropicError.http(status: 429, body: body("rate_limit_error", "Slow down"), retryAfter: "20")
            == .rateLimited(retryAfter: "20", message: "Slow down"))
        #expect(AnthropicError.http(status: 529, body: body("overloaded_error", "Overloaded"), retryAfter: nil)
            == .overloaded(message: "Overloaded"))
        #expect(AnthropicError.http(status: 500, body: body("api_error", "Boom"), retryAfter: nil)
            == .server(status: 500, message: "Boom"))
        #expect(AnthropicError.http(status: 400, body: body("invalid_request_error", "bad model"), retryAfter: nil)
            == .http(status: 400, message: "bad model"))
        #expect(AnthropicError.rateLimited(retryAfter: "20", message: nil).errorDescription?.contains("Retry after 20 s") == true)
        #expect(AnthropicError.invalidAPIKey(message: "invalid x-api-key").errorDescription?.contains("401") == true)

        let endpoint = StubURLProtocol.register(status: 401, body: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#)
        await #expect(throws: AnthropicError.invalidAPIKey(message: "invalid x-api-key")) {
            for try await _ in client(endpoint: endpoint).streamText(request()) {}
        }
    }
}
