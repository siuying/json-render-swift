import Foundation

enum AnthropicError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case invalidAPIKey(message: String?)
    case rateLimited(retryAfter: String?, message: String?)
    case overloaded(message: String?)
    case server(status: Int, message: String?)
    case http(status: Int, message: String?)
    case streamError(type: String?, message: String)
    case refused(String)
    case cutOff
    case contextWindowExceeded
    case malformedEvent(type: String?, detail: String)
    case streamEndedEarly

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No Anthropic API key. Add one in Settings, or put ANTHROPIC_API_KEY in ios/Secrets.xcconfig."
        case .invalidResponse:
            "The server did not return an HTTP response."
        case .invalidAPIKey(let message):
            "Anthropic rejected the API key (HTTP 401)" + Self.suffix(message)
        case .rateLimited(let retryAfter, let message):
            "Rate limited by Anthropic (HTTP 429)."
                + (retryAfter.map { " Retry after \($0) s." } ?? " Try again shortly.")
                + (message.map { " \($0)" } ?? "")
        case .overloaded(let message):
            "Anthropic is overloaded. Try again shortly" + Self.suffix(message)
        case .server(let status, let message):
            "Anthropic server error (HTTP \(status))" + Self.suffix(message)
        case .http(let status, let message):
            "Anthropic returned HTTP \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))"
                + Self.suffix(message)
        case .streamError(let type, let message):
            type == "overloaded_error" ? "Anthropic is overloaded. Try again shortly: \(message)" : message
        case .refused(let message):
            message.isEmpty ? "The model declined this request." : "The model declined: \(message)"
        case .cutOff:
            "Response was cut off: the model reached max_tokens. What arrived is kept; ask for the rest in a follow-up."
        case .contextWindowExceeded:
            "Response was cut off: the model's context window is full. What arrived is kept; try a shorter request or clear and start over."
        case .malformedEvent(let type, let detail):
            "Could not decode stream event \(type ?? "message"): \(detail)"
        case .streamEndedEarly:
            "The stream ended before the response completed."
        }
    }

    private static func suffix(_ message: String?) -> String {
        message.map { ": \($0)" } ?? "."
    }

    /// Maps a non-2xx response (`{"type":"error","error":{"type","message"}}`).
    static func http(status: Int, body: Data, retryAfter: String?) -> AnthropicError {
        let message = Self.message(fromErrorBody: body)
        switch status {
        case 401: return .invalidAPIKey(message: message)
        case 429: return .rateLimited(retryAfter: retryAfter, message: message)
        case 529: return .overloaded(message: message)
        case 500...599: return .server(status: status, message: message)
        default: return .http(status: status, message: message)
        }
    }

    static func message(fromErrorBody data: Data) -> String? {
        struct Body: Decodable {
            struct Inner: Decodable { var message: String? }
            var error: Inner?
        }
        if let message = (try? JSONDecoder().decode(Body.self, from: data))?.error?.message, !message.isEmpty {
            return message
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(500))
    }
}
