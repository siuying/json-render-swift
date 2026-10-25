import SwiftUI

extension EnvironmentValues {
    /// Component renderers used by ``JSONRenderView``.
    @Entry public var jsonRenderRegistry: ComponentRegistry = .standard
    /// Host action handlers installed with ``SwiftUI/View/onJSONRenderAction(_:perform:)``.
    @Entry var jsonRenderActionHandlers: [String: ActionHandler] = [:]
    /// Set inside a rendered `Form`, so nested `Form` elements don't nest SwiftUI forms.
    @Entry var jsonRenderInsideForm = false
}

extension View {
    /// Handles a spec action by name, e.g. `"submit"` (called after validation passes)
    /// or any custom action. Takes precedence over handlers registered on the session.
    public func onJSONRenderAction(_ action: String, perform handler: @escaping ActionHandler) -> some View {
        transformEnvironment(\.jsonRenderActionHandlers) { $0[action] = handler }
    }

    /// Adds or overrides the renderer for a component type.
    public func jsonRenderComponent<Content: View>(
        _ type: String,
        @ViewBuilder content: @escaping @MainActor @Sendable (ComponentContext) -> Content
    ) -> some View {
        transformEnvironment(\.jsonRenderRegistry) { $0.register(type, content: content) }
    }

    /// Replaces the component registry.
    public func jsonRenderRegistry(_ registry: ComponentRegistry) -> some View {
        environment(\.jsonRenderRegistry, registry)
    }
}
