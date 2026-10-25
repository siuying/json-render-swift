import SwiftUI

/// Renders one spec element by key: evaluates visibility, resolves props and hands a
/// ``ComponentContext`` to the registered component. Renders nothing for missing keys
/// (partially streamed specs), hidden elements and reference cycles.
struct ElementView: View {
    let key: String
    let ancestors: [String]

    @Environment(FormSession.self) private var session
    @Environment(\.jsonRenderRegistry) private var registry
    @State private var localValues: [String: JSONValue] = [:]

    var body: some View {
        if !ancestors.contains(key),
           let element = session.spec?.elements[key],
           Visibility.evaluate(element.visible, state: session.store)
        {
            let context = ComponentContext(
                key: key,
                element: element,
                props: Props(Expressions.resolveProps(element.props, state: session.store)),
                session: session,
                bindings: Expressions.bindings(in: element.props),
                ancestors: ancestors,
                localValues: $localValues
            )
            if let render = registry.renderer(for: element.type) {
                render(context)
            } else {
                UnknownComponentView(type: element.type)
            }
        }
    }
}

/// An element's children, in order. Duplicate keys render once.
public struct ElementChildren: View {
    let keys: [String]
    let ancestors: [String]

    public var isEmpty: Bool { keys.isEmpty }

    public var body: some View {
        var seen: Set<String> = []
        let unique = keys.filter { seen.insert($0).inserted }
        ForEach(unique, id: \.self) { key in
            ElementView(key: key, ancestors: ancestors)
        }
    }
}

/// Placeholder for component types missing from the registry (DEBUG builds only).
struct UnknownComponentView: View {
    let type: String

    var body: some View {
        #if DEBUG
        Label("Unknown component “\(type)”", systemImage: "questionmark.square.dashed")
            .font(.caption)
            .foregroundStyle(.secondary)
        #endif
    }
}
