import Foundation

/// What to generate: the model, the system instructions and the user input.
struct GenerationRequest: Sendable, Equatable {
    var model: String
    var instructions: String
    var input: String
    /// Effort level (`reasoning.effort` / `output_config.effort`); `nil` leaves the model default.
    var reasoningEffort: String?
}

/// An item of a generation stream.
enum TextStreamEvent: Sendable, Equatable {
    /// The next piece of output text.
    case text(String)
    /// The output is now served by another model (Claude's server-side fallback). A
    /// notification only: the new model continues the existing output, so nothing is discarded.
    case servingModelChanged(model: String)
}

/// Streams generated text. ``OpenAIClient`` and ``AnthropicClient`` are the live
/// implementations; tests inject mocks.
protocol TextGenerating: Sendable {
    /// Stream events in order. Cancelling the consuming task cancels the request.
    func streamText(_ request: GenerationRequest) -> AsyncThrowingStream<TextStreamEvent, any Error>
}
