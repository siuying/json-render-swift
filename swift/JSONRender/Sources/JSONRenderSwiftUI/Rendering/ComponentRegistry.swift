import SwiftUI

/// Maps catalog component type names to SwiftUI renderers.
///
/// Start from ``standard`` and override or add types:
/// ```swift
/// var registry = ComponentRegistry.standard
/// registry.register("Rating") { context in RatingView(context: context) }
/// ```
/// or, scoped to a view hierarchy, use `.jsonRenderComponent("Rating") { … }`.
public struct ComponentRegistry: Sendable {
    public typealias Renderer = @MainActor @Sendable (ComponentContext) -> AnyView

    private var renderers: [String: Renderer]

    public init() {
        renderers = [:]
    }

    /// The registered type names.
    public var types: [String] { renderers.keys.sorted() }

    public func renderer(for type: String) -> Renderer? {
        renderers[type]
    }

    /// Registers (or replaces) the renderer for `type`.
    public mutating func register<Content: View>(
        _ type: String,
        @ViewBuilder content: @escaping @MainActor @Sendable (ComponentContext) -> Content
    ) {
        renderers[type] = { AnyView(content($0)) }
    }

    public mutating func unregister(_ type: String) {
        renderers[type] = nil
    }

    /// A copy with `type` registered.
    public func registering<Content: View>(
        _ type: String,
        @ViewBuilder content: @escaping @MainActor @Sendable (ComponentContext) -> Content
    ) -> ComponentRegistry {
        var copy = self
        copy.register(type, content: content)
        return copy
    }
}
