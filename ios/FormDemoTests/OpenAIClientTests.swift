@testable import FormDemo
import Foundation
import Testing

@Suite("OpenAI client")
struct OpenAIClientTests {
    private let request = GenerationRequest(
        model: "gpt-6-luna",
        instructions: "You are a form generator.",
        input: "Event RSVP",
        reasoningEffort: nil
    )

    private func client(key: String? = "sk-test", endpoint: URL = OpenAIClient.defaultEndpoint) -> OpenAIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return OpenAIClient(endpoint: endpoint, session: URLSession(configuration: configuration), apiKey: { key })
    }

    // MARK: Request construction

    @Test func buildsResponsesRequest() throws {
        let urlRequest = try client().makeURLRequest(request)
        #expect(urlRequest.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.value(forHTTPHeaderField: "Accept") == "text/event-stream")

        let body = try #require(urlRequest.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["model", "instructions", "input", "stream", "store"])
        #expect(json["model"] as? String == "gpt-6-luna")
        #expect(json["instructions"] as? String == "You are a form generator.")
        #expect(json["input"] as? String == "Event RSVP")
        #expect(json["stream"] as? Bool == true)
        #expect(json["store"] as? Bool == false)
    }

    @Test func includesReasoningEffortWhenSet() throws {
        var request = request
        request.reasoningEffort = "low"
        let body = try #require(try client().makeURLRequest(request).httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["reasoning"] as? [String: Any])?["effort"] as? String == "low")
    }

    @Test(arguments: [nil, "", "   "])
    func missingKeyThrows(key: String?) {
        #expect(throws: OpenAIError.missingAPIKey) { try client(key: key).makeURLRequest(request) }
    }

    // MARK: Streaming over a stubbed URLSession

    @Test func streamsTextDeltas() async throws {
        let endpoint = StubURLProtocol.register(status: 200, body: """
        event: response.created
        data: {"type":"response.created","response":{"id":"resp_1"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"{\\"op\\":\\"add\\","}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"\\"path\\":\\"/root\\",\\"value\\":\\"form\\"}\\n"}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"resp_1","status":"completed"}}


        """)
        var text = ""
        for try await event in client(endpoint: endpoint).streamText(request) {
            if case .text(let chunk) = event { text += chunk }
        }
        #expect(text == #"{"op":"add","path":"/root","value":"form"}"# + "\n")

        let sent = try #require(StubURLProtocol.lastRequest(for: endpoint))
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    }

    @Test func httpErrorsCarryTheAPIMessage() async {
        let endpoint = StubURLProtocol.register(
            status: 401,
            body: #"{"error":{"message":"Incorrect API key provided: sk-test.","type":"invalid_request_error","code":"invalid_api_key"}}"#
        )
        await #expect(throws: OpenAIError.http(status: 401, message: "Incorrect API key provided: sk-test.")) {
            for try await _ in client(endpoint: endpoint).streamText(request) {}
        }
    }

    @Test func failedResponseThrows() async {
        let endpoint = StubURLProtocol.register(status: 200, body: """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"partial"}

        event: response.failed
        data: {"type":"response.failed","response":{"error":{"message":"Server overloaded"}}}


        """)
        await #expect(throws: OpenAIError.streamFailed("Server overloaded")) {
            for try await _ in client(endpoint: endpoint).streamText(request) {}
        }
    }

    @Test func refusalThrows() async {
        let endpoint = StubURLProtocol.register(status: 200, body: """
        event: response.refusal.delta
        data: {"type":"response.refusal.delta","delta":"No "}

        event: response.refusal.delta
        data: {"type":"response.refusal.delta","delta":"thanks."}

        event: response.completed
        data: {"type":"response.completed","response":{"status":"completed"}}


        """)
        await #expect(throws: OpenAIError.refused("No thanks.")) {
            for try await _ in client(endpoint: endpoint).streamText(request) {}
        }
    }

    @Test func truncatedStreamThrows() async {
        let endpoint = StubURLProtocol.register(status: 200, body: """
        data: {"type":"response.output_text.delta","delta":"partial"}


        """)
        await #expect(throws: OpenAIError.streamEndedEarly) {
            for try await _ in client(endpoint: endpoint).streamText(request) {}
        }
    }

    @Test func errorBodyMessages() {
        #expect(OpenAIError.message(fromErrorBody: Data(#"{"error":{"message":"Bad model"}}"#.utf8)) == "Bad model")
        #expect(OpenAIError.message(fromErrorBody: Data("Gateway timeout".utf8)) == "Gateway timeout")
        #expect(OpenAIError.message(fromErrorBody: Data()) == nil)
        #expect(OpenAIError.http(status: 404, message: "Bad model").errorDescription?.contains("HTTP 404") == true)
    }
}

/// Serves canned responses per URL so parallel tests don't interfere.
final class StubURLProtocol: URLProtocol {
    private struct Stub {
        var status: Int
        var body: Data
        var lastRequest: URLRequest?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [URL: Stub] = [:]

    /// Registers a response and returns a unique endpoint that serves it.
    static func register(status: Int, body: String) -> URL {
        let url = URL(string: "https://stub.test/\(UUID().uuidString)/v1/responses")!
        lock.withLock { stubs[url] = Stub(status: status, body: Data(body.utf8)) }
        return url
    }

    static func lastRequest(for url: URL) -> URLRequest? {
        lock.withLock { stubs[url]?.lastRequest }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let request = request
        let stub = Self.lock.withLock { () -> Stub? in
            Self.stubs[url]?.lastRequest = request
            return Self.stubs[url]
        }
        guard let stub, let response = HTTPURLResponse(
            url: url, statusCode: stub.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": stub.status == 200 ? "text/event-stream" : "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Deliver in small pieces, like a network stream.
        var offset = 0
        while offset < stub.body.count {
            let end = min(offset + 37, stub.body.count)
            client?.urlProtocol(self, didLoad: stub.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
