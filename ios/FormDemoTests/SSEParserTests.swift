@testable import FormDemo
import Foundation
import Testing

@Suite("SSE parser")
struct SSEParserTests {
    private func parse(_ text: String, chunkSize: Int? = nil) -> [SSEEvent] {
        var parser = SSEParser()
        let bytes = Array(text.utf8)
        var events: [SSEEvent] = []
        let size = chunkSize ?? max(bytes.count, 1)
        var start = 0
        while start < bytes.count {
            let end = min(start + size, bytes.count)
            events += parser.push(contentsOf: bytes[start..<end])
            start = end
        }
        if let last = parser.finish() { events.append(last) }
        return events
    }

    @Test func parsesTypedEvents() {
        let events = parse("""
        event: response.created
        data: {"type":"response.created"}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"Hi"}


        """)
        #expect(events == [
            SSEEvent(event: "response.created", data: #"{"type":"response.created"}"#),
            SSEEvent(event: "response.output_text.delta", data: #"{"type":"response.output_text.delta","delta":"Hi"}"#),
        ])
    }

    @Test func chunkBoundariesDoNotMatter() {
        let stream = "event: a\ndata: héllo 👋\n\n: keep-alive\n\ndata: {\"x\":1}\r\n\r\nevent: b\rdata: two\r\r"
        let expected = parse(stream)
        #expect(expected == [
            SSEEvent(event: "a", data: "héllo 👋"),
            SSEEvent(event: nil, data: #"{"x":1}"#),
            SSEEvent(event: "b", data: "two"),
        ])
        for size in 1...12 {
            #expect(parse(stream, chunkSize: size) == expected, "chunk size \(size)")
        }
    }

    @Test func joinsMultilineData() {
        let events = parse("data: first\ndata:second\ndata\ndata:  indented\n\n")
        #expect(events == [SSEEvent(event: nil, data: "first\nsecond\n\n indented")])
    }

    @Test func ignoresCommentsRetryAndEventsWithoutData() {
        let events = parse(": comment\nretry: 1000\nevent: ping\n\nid: 7\ndata: x\n\n")
        #expect(events == [SSEEvent(event: nil, data: "x", id: "7")])
    }

    @Test func finishFlushesUnterminatedEvent() {
        #expect(parse("data: [DONE]") == [SSEEvent(event: nil, data: "[DONE]")])
        #expect(parse("data: tail\n") == [SSEEvent(event: nil, data: "tail")])
    }
}

@Suite("Responses stream events")
struct ResponsesStreamEventTests {
    private func decode(_ data: String, event: String? = nil) throws -> ResponsesStreamEvent {
        try ResponsesStreamEvent(SSEEvent(event: event, data: data))
    }

    @Test func textDelta() throws {
        let event = try decode(#"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"{\"op\":\"add\"","sequence_number":4}"#)
        #expect(event == .textDelta(#"{"op":"add""#))
    }

    @Test func completionAndDoneSentinel() throws {
        #expect(try decode(#"{"type":"response.completed","response":{"id":"resp_1","status":"completed"}}"#) == .completed)
        #expect(try decode("[DONE]") == .completed)
    }

    @Test func failures() throws {
        #expect(try decode(#"{"type":"error","code":"rate_limit_exceeded","message":"Rate limit reached","param":null}"#, event: "error") == .failed("Rate limit reached"))
        #expect(try decode(#"{"type":"error","error":{"message":"Nested message"}}"#) == .failed("Nested message"))
        #expect(try decode(#"{"type":"response.failed","response":{"status":"failed","error":{"code":"server_error","message":"The model crashed"}}}"#) == .failed("The model crashed"))
        #expect(try decode(#"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#) == .failed("Response was cut off (max_output_tokens). What arrived is kept; ask for the rest in a follow-up."))
    }

    @Test func refusals() throws {
        #expect(try decode(#"{"type":"response.refusal.delta","item_id":"msg_1","output_index":0,"content_index":0,"delta":"I can't"}"#) == .refusalDelta("I can't"))
        #expect(try decode(#"{"type":"response.refusal.done","item_id":"msg_1","output_index":0,"content_index":0,"refusal":"I can't help."}"#) == .refusal("I can't help."))
    }

    @Test func eventNameIsTheFallbackType() throws {
        #expect(try decode(#"{"delta":"x"}"#, event: "response.output_text.delta") == .textDelta("x"))
        #expect(try decode(#"{"type":"response.in_progress"}"#) == .ignored(type: "response.in_progress"))
    }

    @Test func malformedJSONThrows() {
        #expect(throws: OpenAIError.self) { try decode("{not json", event: "response.output_text.delta") }
    }
}
