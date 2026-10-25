import Observation

/// Top-level state: the selected mode and one independent controller per mode, so
/// switching between Form and Document keeps each workspace as it was.
@MainActor
@Observable
final class AppModel {
    var mode: GenerationKind
    let forms: GenerationController
    let documents: GenerationController

    init(
        mode: GenerationKind = .form,
        generators: @escaping @Sendable (Provider) -> any TextGenerating,
        options: @escaping @MainActor () -> GenerationOptions
    ) {
        self.mode = mode
        forms = GenerationController(kind: .form, generators: generators, options: options)
        documents = GenerationController(kind: .document, generators: generators, options: options)
    }

    /// One client for every provider (tests).
    convenience init(
        mode: GenerationKind = .form,
        generator: any TextGenerating,
        options: @escaping @MainActor () -> GenerationOptions
    ) {
        self.init(mode: mode, generators: { _ in generator }, options: options)
    }

    func controller(for kind: GenerationKind) -> GenerationController {
        switch kind {
        case .form: forms
        case .document: documents
        }
    }
}
