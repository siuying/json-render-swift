import SwiftUI

@main
struct FormDemoApp: App {
    @State private var settings: AppSettings
    @State private var model: AppModel
    private let launchOptions = LaunchOptions.current

    init() {
        let settings = AppSettings()
        let openAIKey = settings.apiKeyProviders[.openAI]
        let anthropicKey = settings.apiKeyProviders[.anthropic]
        let openAI = OpenAIClient(apiKey: { openAIKey?.resolve() })
        let anthropic = AnthropicClient(apiKey: { anthropicKey?.resolve() })
        _settings = State(initialValue: settings)
        _model = State(initialValue: AppModel(
            mode: launchOptions.mode,
            generators: { provider in
                switch provider {
                case .openAI: openAI
                case .anthropic: anthropic
                }
            },
            options: { settings.generationOptions }
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView(launchOptions: launchOptions)
                .environment(settings)
                .environment(model)
        }
    }
}
