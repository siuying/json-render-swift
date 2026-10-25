import SwiftUI

/// Renders a ``FormSession``'s spec with native SwiftUI components and presents the
/// alerts and confirmation dialogs its actions request.
///
/// ```swift
/// JSONRenderView(session: session)
///     .onJSONRenderAction("submit") { params, session in
///         try await api.send(params["data"])
///     }
/// ```
public struct JSONRenderView: View {
    private let session: FormSession

    @Environment(\.jsonRenderActionHandlers) private var actionHandlers
    @Environment(\.openURL) private var openURL

    public init(session: FormSession) {
        self.session = session
    }

    public var body: some View {
        let _ = attachEnvironment()
        Group {
            if let root = session.spec?.root {
                ElementView(key: root, ancestors: [])
            }
        }
        .environment(session)
        .alert(
            session.alert?.title ?? "",
            isPresented: Binding(
                get: { session.alert != nil },
                set: { if !$0 { session.alert = nil } }
            ),
            presenting: session.alert,
            actions: { _ in Button("OK", role: .cancel) {} },
            message: { alert in
                if let message = alert.message { Text(message) }
            }
        )
        .alert(
            session.confirmation?.title ?? "",
            isPresented: Binding(
                get: { session.confirmation != nil },
                // Deferred so a button's own resolution always wins over dismissal.
                set: { presented in
                    if !presented { Task { @MainActor in session.resolveConfirmation(false) } }
                }
            ),
            presenting: session.confirmation,
            actions: { request in
                Button(request.confirmLabel, role: request.isDestructive ? .destructive : nil) {
                    session.resolveConfirmation(true)
                }
                Button(request.cancelLabel, role: .cancel) {
                    session.resolveConfirmation(false)
                }
            },
            message: { request in Text(request.message) }
        )
    }

    /// Hands environment-provided handlers to the session's (unobserved) dispatcher.
    private func attachEnvironment() {
        session.actions.environmentHandlers = actionHandlers
        let openURL = openURL
        session.openURLAction = { openURL($0) }
    }
}
