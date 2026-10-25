@testable import FormDemo
import Foundation
import Testing

@MainActor
@Suite("Settings")
struct AppSettingsTests {
    private func makeSettings(
        stored: [String: String] = [:],
        environment: [String: String] = [:]
    ) -> (AppSettings, UserDefaults, String) {
        let suite = "settings-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        for (key, value) in stored { defaults.set(value, forKey: key) }
        let settings = AppSettings(defaults: defaults, keychainService: suite, environment: environment)
        return (settings, defaults, suite)
    }

    @Test func defaults() {
        let (settings, _, _) = makeSettings()
        #expect(settings.provider == .openAI)
        #expect(settings.effectiveModel(for: .openAI) == "gpt-6-luna")
        #expect(settings.effectiveModel(for: .anthropic) == "claude-sonnet-5-5")
        #expect(settings.effort(for: .openAI) == nil)
        #expect(settings.effort(for: .anthropic) == nil)
        #expect(settings.generationOptions == GenerationOptions(provider: .openAI, model: "gpt-6-luna", reasoningEffort: nil))
        #expect(Provider.openAI.models.map(\.id) == ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna"])
        #expect(Provider.anthropic.models.map(\.id) == ["claude-fable-5", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        #expect(Provider.anthropic.displayName(forModel: "claude-opus-5-5") == "Claude Opus 5.5")
    }

    @Test func effortsPerProvider() {
        let (settings, _, _) = makeSettings()
        #expect(settings.availableEfforts == ["low", "medium", "high"])
        #expect(!settings.effortsAreVerified, "OpenAI efforts are unverified for these IDs")
        settings.provider = .anthropic
        #expect(settings.availableEfforts == ["low", "medium", "high", "xhigh", "max"])
        #expect(settings.effortsAreVerified)
        settings.model = "claude-experimental"
        #expect(!settings.effortsAreVerified)
    }

    @Test func defaultProviderFollowsConfiguredKeys() {
        #expect(makeSettings(environment: ["ANTHROPIC_API_KEY": "sk-ant"]).0.provider == .anthropic)
        #expect(makeSettings(environment: ["ANTHROPIC_API_KEY": "sk-ant", "OPENAI_API_KEY": "sk"]).0.provider == .openAI)
        #expect(makeSettings(environment: ["OPENAI_API_KEY": "sk"]).0.provider == .openAI)
        // An explicit choice wins.
        #expect(makeSettings(stored: ["provider": "openai"], environment: ["ANTHROPIC_API_KEY": "sk-ant"]).0.provider == .openAI)
    }

    @Test func providerSwitchingKeepsEachProvidersSettings() {
        let (settings, defaults, suite) = makeSettings()
        settings.model = "gpt-6-astra"
        settings.reasoningEffort = "high"
        settings.provider = .anthropic
        #expect(settings.model == "claude-sonnet-5-5")
        #expect(settings.reasoningEffort == nil)
        settings.model = "claude-opus-5-5"
        settings.reasoningEffort = "max"
        #expect(settings.generationOptions == GenerationOptions(provider: .anthropic, model: "claude-opus-5-5", reasoningEffort: "max"))

        settings.provider = .openAI
        #expect(settings.generationOptions == GenerationOptions(provider: .openAI, model: "gpt-6-astra", reasoningEffort: "high"))

        let restored = AppSettings(defaults: defaults, keychainService: suite, environment: [:])
        #expect(restored.provider == .openAI)
        #expect(restored.effort(for: .anthropic) == "max")
        #expect(restored.model(for: .anthropic) == "claude-opus-5-5")
    }

    @Test func customModelPersists() {
        let (settings, defaults, suite) = makeSettings()
        settings.provider = .anthropic
        settings.model = "claude-custom-preview"
        let restored = AppSettings(defaults: defaults, keychainService: suite, environment: [:])
        #expect(restored.effectiveModel(for: .anthropic) == "claude-custom-preview")
        #expect(!Provider.anthropic.models.contains { $0.id == restored.model(for: .anthropic) })

        settings.model = "   "
        #expect(settings.effectiveModel == "claude-sonnet-5-5", "a blank custom ID falls back to the default")
    }

    @Test func incompatibleSavedEffortIsReset() {
        let (settings, defaults, _) = makeSettings(stored: ["openai.effort": "xhigh", "anthropic.effort": "xhigh"])
        #expect(settings.effort(for: .openAI) == nil)
        #expect(defaults.string(forKey: "openai.effort") == nil)
        #expect(settings.effort(for: .anthropic) == "xhigh")
    }

    @Test func keysArePerProvider() throws {
        let (settings, _, _) = makeSettings(environment: ["OPENAI_API_KEY": "env-openai"])
        defer {
            try? settings.saveAPIKey("", for: .openAI)
            try? settings.saveAPIKey("", for: .anthropic)
        }
        #expect(settings.apiKey(for: .openAI) == "env-openai")
        #expect(settings.apiKey(for: .anthropic) == nil)
        try settings.saveAPIKey("  sk-ant-test  ", for: .anthropic)
        #expect(settings.apiKey(for: .anthropic) == "sk-ant-test")
        #expect(settings.apiKeyProviders[.anthropic]?.resolve() == "sk-ant-test")
        #expect(settings.apiKeyProviders[.openAI]?.resolve() == "env-openai")
        try settings.saveAPIKey("", for: .anthropic)
        #expect(settings.apiKey(for: .anthropic) == nil)
    }

    @Test func modelDefaultSendsNoReasoning() throws {
        let (settings, _, _) = makeSettings()
        let options = settings.generationOptions
        let request = GenerationRequest(model: options.model, instructions: "i", input: "p", reasoningEffort: options.reasoningEffort)
        let body = try #require(try OpenAIClient(apiKey: { "sk-test" }).makeURLRequest(request).httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["reasoning"] == nil)
    }
}
