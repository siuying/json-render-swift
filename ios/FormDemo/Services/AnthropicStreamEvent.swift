import Foundation

/// The Anthropic Messages API stream events the app acts on.
///
/// Event types: `message_start`, `content_block_start`, `content_block_delta`,
/// `content_block_stop`, `message_delta`, `message_stop`, `ping`, `error`.
enum AnthropicStreamEvent: Sendable, Equatable {
    /// `content_block_delta` with `delta.type == "text_delta"`.
    case textDelta(String)
    /// `content_block_start` of a `fallback` block: the turn re-runs on `model`.
    case fallback(model: String)
    /// `message_delta` carrying a stop reason (`end_turn`, `refusal`, `max_tokens`,
    /// `model_context_window_exceeded`, …).
    case stop(reason: String, explanation: String?)
    /// `message_stop`: the response is complete.
    case messageStop
    /// `error`, sent mid-stream.
    case error(type: String?, message: String)
    /// Everything else: `ping`, `message_start`, thinking blocks and deltas, block stops, …
    case ignored(type: String)

    /// Decodes an SSE event. The JSON `type` field wins over the SSE `event:` name.
    init(_ event: SSEEvent) throws {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(event.data.utf8))
        } catch {
            throw AnthropicError.malformedEvent(type: event.event, detail: error.localizedDescription)
        }
        let type = payload.type ?? event.event ?? "message"
        switch type {
        case "content_block_delta" where payload.delta?.type == "text_delta":
            self = .textDelta(payload.delta?.text ?? "")
        case "content_block_start" where payload.contentBlock?.type == "fallback":
            let block = payload.contentBlock
            self = .fallback(model: block?.to?.model ?? block?.model ?? "another model")
        case "message_delta":
            if let reason = payload.delta?.stopReason {
                let explanation = payload.delta?.stopDetails?.explanation ?? payload.stopDetails?.explanation
                self = .stop(reason: reason, explanation: explanation)
            } else {
                self = .ignored(type: type)
            }
        case "message_stop":
            self = .messageStop
        case "error":
            self = .error(type: payload.error?.type, message: payload.error?.message ?? "The stream reported an error.")
        default:
            self = .ignored(type: type)
        }
    }

    private struct Payload: Decodable {
        struct Delta: Decodable {
            var type: String?
            var text: String?
            var stopReason: String?
            var stopDetails: StopDetails?

            enum CodingKeys: String, CodingKey {
                case type, text
                case stopReason = "stop_reason"
                case stopDetails = "stop_details"
            }
        }
        struct StopDetails: Decodable {
            var explanation: String?
        }
        struct ContentBlock: Decodable {
            struct Target: Decodable { var model: String? }
            var type: String?
            var model: String?
            var to: Target?
        }
        struct ErrorBody: Decodable {
            var type: String?
            var message: String?
        }

        var type: String?
        var delta: Delta?
        var contentBlock: ContentBlock?
        var stopDetails: StopDetails?
        var error: ErrorBody?

        enum CodingKeys: String, CodingKey {
            case type, delta, error
            case contentBlock = "content_block"
            case stopDetails = "stop_details"
        }
    }
}
