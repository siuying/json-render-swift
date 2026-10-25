import Foundation

enum OpenAIError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case invalidResponse
    case http(status: Int, message: String?)
    case malformedEvent(type: String?, detail: String)
    case streamFailed(String)
    case refused(String)
    case streamEndedEarly

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No OpenAI API key. Add one in Settings, or put OPENAI_API_KEY in ios/Secrets.xcconfig."
        case .invalidResponse:
            "The server did not return an HTTP response."
        case .http(let status, let message):
            "OpenAI returned HTTP \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))"
                + (message.map { ": \($0)" } ?? ".")
        case .malformedEvent(let type, let detail):
            "Could not decode stream event \(type ?? "message"): \(detail)"
        case .streamFailed(let message):
            message
        case .refused(let message):
            message.isEmpty ? "The model declined this request." : "The model declined: \(message)"
        case .streamEndedEarly:
            "The stream ended before the response completed."
        }
    }

    /// The `error.message` of an OpenAI error body, if the body is one.
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
