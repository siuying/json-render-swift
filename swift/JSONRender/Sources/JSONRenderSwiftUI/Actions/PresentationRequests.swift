import Foundation

/// An alert requested by the `showAlert` action. Presented by ``JSONRenderView``.
public struct AlertRequest: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public var title: String
    public var message: String?

    public init(title: String, message: String? = nil) {
        self.title = title
        self.message = message
    }
}

/// A pending `confirm` dialog. Presented by ``JSONRenderView``; resolve it through
/// ``FormSession/resolveConfirmation(_:)``.
public struct ConfirmationRequest: Identifiable, Sendable {
    public let id = UUID()
    public var title: String
    public var message: String
    public var confirmLabel: String
    public var cancelLabel: String
    public var isDestructive: Bool
    let continuation: CheckedContinuation<Bool, Never>?

    /// A standalone request (e.g. for previews or tests); resolving it has no effect on
    /// any action.
    public init(title: String, message: String, confirmLabel: String = "Confirm", cancelLabel: String = "Cancel", isDestructive: Bool = false) {
        self.init(title: title, message: message, confirmLabel: confirmLabel, cancelLabel: cancelLabel,
                  isDestructive: isDestructive, continuation: nil)
    }

    init(
        title: String, message: String, confirmLabel: String, cancelLabel: String, isDestructive: Bool,
        continuation: CheckedContinuation<Bool, Never>?
    ) {
        self.title = title
        self.message = message
        self.confirmLabel = confirmLabel
        self.cancelLabel = cancelLabel
        self.isDestructive = isDestructive
        self.continuation = continuation
    }
}
