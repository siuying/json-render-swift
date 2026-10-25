import SwiftUI

/// Provider, API key (Keychain) and model settings.
struct SettingsView: View {
    private static let customTag = "\u{0}custom"

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var draftKey = ""
    @State private var keyError: String?
    /// Shows the model ID field even while it holds a preset ID.
    @State private var isCustomModel = false

    var body: some View {
        @Bindable var settings = settings
        let provider = settings.provider
        NavigationStack {
            Form {
                Section {
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(Provider.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Used by both Form and Document. A running generation keeps the provider it started with.")
                }

                keySection(provider)
                modelSection(provider)

                Section("Endpoint") {
                    LabeledContent("API", value: provider.endpointDescription)
                    LabeledContent("Streaming", value: "Server-sent events")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .alert("Keychain", isPresented: Binding(get: { keyError != nil }, set: { if !$0 { keyError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(keyError ?? "")
            }
            .onAppear(perform: syncCustomModel)
            .onChange(of: provider) {
                draftKey = ""
                syncCustomModel()
            }
        }
    }

    // MARK: Sections

    private func keySection(_ provider: Provider) -> some View {
        Section {
            SecureField(provider.keyPlaceholder, text: $draftKey)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { save(draftKey, for: provider) }
            HStack {
                Button("Save to Keychain") { save(draftKey, for: provider) }
                    .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                if !settings.storedAPIKey(for: provider).isEmpty {
                    Button("Remove", role: .destructive) { save("", for: provider) }
                }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("\(provider.displayName) API key")
        } footer: {
            Text(keyStatus(provider))
        }
    }

    private func modelSection(_ provider: Provider) -> some View {
        @Bindable var settings = settings
        return Section {
            Picker("Model", selection: modelSelection(provider)) {
                ForEach(provider.models) { model in
                    Text(model.name).tag(model.id)
                }
                Text("Custom…").tag(Self.customTag)
            }
            if isCustomModel {
                TextField("Model ID", text: $settings.model, prompt: Text(provider.defaultModel))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            }
            Picker("Effort", selection: $settings.reasoningEffort) {
                Text("Model default").tag(String?.none)
                ForEach(settings.availableEfforts, id: \.self) { effort in
                    Text(effortName(effort)).tag(Optional(effort))
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text(effortFooter(provider))
        }
    }

    /// The picker shows the preset for a listed model ID, otherwise "Custom…".
    private func modelSelection(_ provider: Provider) -> Binding<String> {
        Binding(
            get: {
                let model = settings.model(for: provider)
                return !isCustomModel && provider.models.contains { $0.id == model } ? model : Self.customTag
            },
            set: { tag in
                if tag == Self.customTag {
                    isCustomModel = true
                } else {
                    isCustomModel = false
                    settings.setModel(tag, for: provider)
                }
            }
        )
    }

    private func syncCustomModel() {
        let provider = settings.provider
        let model = settings.model(for: provider)
        isCustomModel = !provider.models.contains { $0.id == model }
    }

    // MARK: Copy

    private func effortName(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra high"
        default: effort.capitalized
        }
    }

    private func effortFooter(_ provider: Provider) -> String {
        let base = "Effort is sent as \(provider.effortParameter); Model default sends none."
        switch provider {
        case .openAI:
            return base + " Supported efforts aren't verified for these model IDs; use Model default if the API rejects one."
        case .anthropic:
            let note = " Low or medium is plenty for forms and documents. Opus 5.5 and Haiku 5.5 default to medium."
            return base + note + (settings.effortsAreVerified ? "" : " Efforts aren't verified for custom model IDs.")
        }
    }

    private func keyStatus(_ provider: Provider) -> String {
        let stored = settings.storedAPIKey(for: provider)
        if !stored.isEmpty {
            return "A key ending in …\(stored.suffix(4)) is stored in the Keychain."
        }
        if settings.environmentAPIKey(for: provider) != nil {
            return "Using \(provider.environmentVariable) from Secrets.xcconfig. A key saved here takes precedence."
        }
        return "No key yet. Offline examples and Replay stream work without one."
    }

    private func save(_ key: String, for provider: Provider) {
        do {
            try settings.saveAPIKey(key, for: provider)
            draftKey = ""
        } catch {
            keyError = error.localizedDescription
        }
    }
}
