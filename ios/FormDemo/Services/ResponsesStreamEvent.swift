import Foundation

/// The OpenAI Responses API stream events the app cares about.
///
/// See https://platform.openai.com/docs/api-reference/responses-streaming
enum ResponsesStreamEvent: Sendable, Equatable {
    /// `response.output_text.delta`: the next piece of output text.
    case textDelta(String)
    /// `response.completed`, or a `data: [DONE]` sentinel.
    case completed
    /// `response.refusal.delta`: the next piece of a refusal explanation.
    case refusalDelta(String)
    /// `response.refusal.done`: the complete refusal explanation.
    case refusal(String)
    /// `response.failed`, `response.incomplete` or `error`.
    case failed(String)
    /// Lifecycle events with nothing to act on (`response.created`, `…output_item.added`, …).
    case ignored(type: String)

    /// Decodes an SSE event. The JSON `type` field wins over the SSE `event:` name.
    init(_ event: SSEEvent) throws {
        let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if data == "[DONE]" {
            self = .completed
            return
        }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(data.utf8))
        } catch {
            throw OpenAIError.malformedEvent(type: event.event, detail: error.localizedDescription)
        }
        let type = payload.type ?? event.event ?? "message"
        switch type {
        case "response.output_text.delta":
            self = .textDelta(payload.delta ?? "")
        case "response.refusal.delta":
            self = .refusalDelta(payload.delta ?? "")
        case "response.refusal.done":
            self = .refusal(payload.refusal ?? "")
        case "response.completed":
            self = .completed
        case "response.failed":
            self = .failed(payload.response?.error?.message ?? "The response failed.")
        case "response.incomplete":
            let reason = payload.response?.incompleteDetails?.reason ?? "unknown reason"
            self = .failed("Response was cut off (\(reason)). What arrived is kept; ask for the rest in a follow-up.")
        case "error":
            self = .failed(payload.message ?? payload.error?.message ?? "The stream reported an error.")
        default:
            self = .ignored(type: type)
        }
    }

    private struct Payload: Decodable {
        struct ErrorBody: Decodable {
            var message: String?
        }
        struct Response: Decodable {
            struct IncompleteDetails: Decodable {
                var reason: String?
            }
            var error: ErrorBody?
            var incompleteDetails: IncompleteDetails?

            enum CodingKeys: String, CodingKey {
                case error
                case incompleteDetails = "incomplete_details"
            }
        }

        var type: String?
        var delta: String?
        var refusal: String?
        var message: String?
        var error: ErrorBody?
        var response: Response?
    }
}
