import Foundation
import Observation

/// User settings: the provider, and per provider the model and effort (UserDefaults) and
/// the API key (Keychain).
@MainActor
@Observable
final class AppSettings {
    static let defaultKeychainService = "dev.jsonrender.FormDemo"
    private static let providerKey = "provider"

    @ObservationIgnored private let defaults: UserDefaults
    /// Thread-safe key lookup per provider for the network clients.
    @ObservationIgnored let apiKeyProviders: [Provider: APIKeyProvider]

    /// The explicitly chosen provider; `nil` until the user picks one.
    private var storedProvider: Provider?
    private var models: [Provider: String] = [:]
    private var efforts: [Provider: String] = [:]
    private var storedKeys: [Provider: String] = [:]

    init(
        defaults: UserDefaults = .standard,
        keychainService: String = AppSettings.defaultKeychainService,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        var providers: [Provider: APIKeyProvider] = [:]
        for provider in Provider.allCases {
            providers[provider] = APIKeyProvider(
                keychain: KeychainStore(service: keychainService, account: provider.keychainAccount),
                environment: environment,
                variable: provider.environmentVariable
            )
        }
        apiKeyProviders = providers
        storedProvider = defaults.string(forKey: Self.providerKey).flatMap(Provider.init(rawValue:))
        for provider in Provider.allCases {
            models[provider] = defaults.string(forKey: Self.modelKey(provider)) ?? provider.defaultModel
            efforts[provider] = defaults.string(forKey: Self.effortKey(provider))
            storedKeys[provider] = providers[provider]?.keychain.read() ?? ""
            resetIncompatibleEffort(for: provider)
        }
    }

    private static func modelKey(_ provider: Provider) -> String { "\(provider.rawValue).model" }
    private static func effortKey(_ provider: Provider) -> String { "\(provider.rawValue).effort" }

    // MARK: Provider

    /// The chosen provider. Until one is chosen: OpenAI, unless only a Claude key is configured.
    var provider: Provider {
        get {
            if let storedProvider { return storedProvider }
            return apiKey(for: .openAI) == nil && apiKey(for: .anthropic) != nil ? .anthropic : .openAI
        }
        set {
            storedProvider = newValue
            defaults.set(newValue.rawValue, forKey: Self.providerKey)
        }
    }

    // MARK: Model and effort

    func model(for provider: Provider) -> String {
        models[provider] ?? provider.defaultModel
    }

    func setModel(_ model: String, for provider: Provider) {
        models[provider] = model
        defaults.set(model, forKey: Self.modelKey(provider))
        resetIncompatibleEffort(for: provider)
    }

    /// The model to request; the provider default when the field is blank.
    func effectiveModel(for provider: Provider) -> String {
        let trimmed = model(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? provider.defaultModel : trimmed
    }

    /// `nil` = "Model default": no effort parameter is sent.
    func effort(for provider: Provider) -> String? {
        efforts[provider]
    }

    func setEffort(_ effort: String?, for provider: Provider) {
        efforts[provider] = effort
        defaults.set(effort, forKey: Self.effortKey(provider))
    }

    /// The current provider's model (bindable).
    var model: String {
        get { model(for: provider) }
        set { setModel(newValue, for: provider) }
    }

    /// The current provider's effort (bindable).
    var reasoningEffort: String? {
        get { effort(for: provider) }
        set { setEffort(newValue, for: provider) }
    }

    var effectiveModel: String { effectiveModel(for: provider) }

    /// Effort levels offered for the current provider ("Model default" is always available).
    var availableEfforts: [String] { provider.efforts }

    /// Whether the app knows the current model supports ``availableEfforts``.
    var effortsAreVerified: Bool { provider.effortsAreVerified(for: effectiveModel) }

    /// What the next generation uses (a snapshot, so later changes don't affect a running request).
    var generationOptions: GenerationOptions {
        GenerationOptions(provider: provider, model: effectiveModel, reasoningEffort: reasoningEffort)
    }

    /// Falls back to the model default when a saved effort isn't offered.
    private func resetIncompatibleEffort(for provider: Provider) {
        if let effort = efforts[provider], !provider.efforts.contains(effort) {
            setEffort(nil, for: provider)
        }
    }

    // MARK: API keys

    /// The key saved in the Keychain for `provider` (empty when none).
    func storedAPIKey(for provider: Provider) -> String {
        storedKeys[provider] ?? ""
    }

    func environmentAPIKey(for provider: Provider) -> String? {
        apiKeyProviders[provider]?.environmentKey
    }

    /// Keychain key first, then the provider's environment variable.
    func apiKey(for provider: Provider) -> String? {
        let stored = storedAPIKey(for: provider)
        return stored.isEmpty ? environmentAPIKey(for: provider) : stored
    }

    /// The current provider's key.
    var apiKey: String? { apiKey(for: provider) }

    func saveAPIKey(_ key: String, for provider: Provider) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try apiKeyProviders[provider]?.keychain.write(trimmed)
        storedKeys[provider] = trimmed
    }
}

/// Resolves a provider's key: Keychain first, then its environment variable.
struct APIKeyProvider: Sendable {
    var keychain: KeychainStore
    var environment: [String: String]
    var variable: String

    var environmentKey: String? {
        environment[variable].flatMap { $0.isEmpty ? nil : $0 }
    }

    func resolve() -> String? {
        keychain.read().flatMap { $0.isEmpty ? nil : $0 } ?? environmentKey
    }
}
