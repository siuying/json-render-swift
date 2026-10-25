/// The AI service that generates specs.
enum Provider: String, CaseIterable, Identifiable, Sendable {
    case openAI = "openai"
    case anthropic

    struct Model: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
    }

    var id: Self { self }

    var displayName: String {
        switch self {
        case .openAI: "OpenAI"
        case .anthropic: "Claude"
        }
    }

    /// Models offered in Settings (plus "Custom…").
    var models: [Model] {
        switch self {
        case .openAI:
            [
                Model(id: "gpt-6-astra", name: "gpt-6-astra"),
                Model(id: "gpt-6.1-sol", name: "gpt-6.1-sol"),
                Model(id: "gpt-6-luna", name: "gpt-6-luna"),
            ]
        case .anthropic:
            [
                Model(id: "claude-fable-5", name: "Claude Fable 5"),
                Model(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
                Model(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
                Model(id: "claude-haiku-5-5", name: "Claude Haiku 5.5"),
            ]
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI: "gpt-6-luna"
        case .anthropic: "claude-sonnet-5-5"
        }
    }

    /// The display name for a model ID (the ID itself for custom models).
    func displayName(forModel id: String) -> String {
        models.first { $0.id == id }?.name ?? id
    }

    /// Effort levels offered in Settings ("Model default" sends none).
    var efforts: [String] {
        switch self {
        case .openAI: ["low", "medium", "high"]
        case .anthropic: ["low", "medium", "high", "xhigh", "max"]
        }
    }

    /// Models whose supported efforts the app knows. OpenAI's are not verified for the
    /// current model IDs; Claude's apply to every listed model.
    func effortsAreVerified(for model: String) -> Bool {
        switch self {
        case .openAI: false
        case .anthropic: models.contains { $0.id == model }
        }
    }

    /// The request field the effort is sent as.
    var effortParameter: String {
        switch self {
        case .openAI: "reasoning.effort"
        case .anthropic: "output_config.effort"
        }
    }

    /// Environment variable (from the scheme / Secrets.xcconfig) holding a fallback key.
    var environmentVariable: String {
        switch self {
        case .openAI: "OPENAI_API_KEY"
        case .anthropic: "ANTHROPIC_API_KEY"
        }
    }

    var keychainAccount: String {
        switch self {
        case .openAI: "openai-api-key"
        case .anthropic: "anthropic-api-key"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .openAI: "sk-…"
        case .anthropic: "sk-ant-…"
        }
    }

    var endpointDescription: String {
        switch self {
        case .openAI: "POST /v1/responses"
        case .anthropic: "POST /v1/messages"
        }
    }
}
