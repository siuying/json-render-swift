import Foundation
import OSLog

/// A host action handler. `params` are fully resolved (no expressions remain).
public typealias ActionHandler = @MainActor @Sendable (_ params: [String: JSONValue], _ session: FormSession) async throws -> Void

/// Resolves and executes action bindings.
///
/// Order of precedence for an action name:
/// 1. State built-ins: `setState`, `pushState`, `removeState`, `resetForm`.
/// 2. `submit`: validates every visible field; only when all pass is the host's
///    `submit` handler invoked.
/// 3. Host handlers (registered here or with `.onJSONRenderAction`).
/// 4. Platform built-ins the host may override: `showAlert`, `openURL`.
/// 5. Anything else is logged and ignored.
@MainActor
public final class ActionDispatcher {
    private enum Outcome { case completed, halted }

    private unowned let session: FormSession
    private var handlers: [String: ActionHandler] = [:]
    /// Handlers supplied through the SwiftUI environment; they take precedence.
    var environmentHandlers: [String: ActionHandler] = [:]
    private var idCounter = 0

    init(session: FormSession) {
        self.session = session
    }

    /// Registers (or replaces) the handler for an action name.
    public func register(_ action: String, handler: @escaping ActionHandler) {
        handlers[action] = handler
    }

    public func unregister(_ action: String) {
        handlers[action] = nil
    }

    func handler(for action: String) -> ActionHandler? {
        environmentHandlers[action] ?? handlers[action]
    }

    /// Executes bindings in order. Each binding's params are resolved against the
    /// live state, so later bindings observe earlier mutations. The chain stops when a
    /// binding halts: `submit` fails validation, a confirmation is cancelled, or a
    /// handler throws without an `onError` (mirroring core, where these reject).
    public func dispatch(_ bindings: [ActionBinding], datum: JSONValue? = nil) async {
        await run(bindings, datum: datum, while: { true })
    }

    public func dispatch(_ binding: ActionBinding) async {
        await run(binding, while: { true })
    }

    /// Runs bindings while `isCurrent()` holds (checked before each binding and after every
    /// suspension). Returns `false` when the chain halted or became stale.
    @discardableResult
    func run(_ bindings: [ActionBinding], datum: JSONValue? = nil, while isCurrent: () -> Bool) async -> Bool {
        for binding in bindings {
            guard isCurrent(), await run(binding, datum: datum, while: isCurrent) else { return false }
        }
        return true
    }

    @discardableResult
    func run(_ binding: ActionBinding, datum: JSONValue? = nil, while isCurrent: () -> Bool) async -> Bool {
        guard isCurrent() else { return false }
        let state = session.store.peek(at: "") ?? .object([:])
        var params: [String: JSONValue] = [:]
        for (key, value) in binding.params {
            if let path = value["$datum"]?.stringValue {
                params[key] = datum.map { path.isEmpty ? $0 : ($0.value(at: path) ?? .null) } ?? .null
            } else {
                params[key] = Expressions.resolveActionParam(value, state: state)
            }
        }
        if let confirm = binding.confirm {
            let confirmed = await session.requestConfirmation(
                title: Expressions.interpolateConfirm(confirm.title, state: state),
                message: Expressions.interpolateConfirm(confirm.message, state: state),
                confirmLabel: confirm.confirmLabel,
                cancelLabel: confirm.cancelLabel,
                isDestructive: confirm.isDestructive
            )
            guard confirmed, isCurrent() else { return false }
        }

        do {
            guard try await execute(binding.action, params: params) == .completed, isCurrent() else { return false }
            if let onSuccess = binding.onSuccess {
                return await runFollowUp(onSuccess, error: nil, while: isCurrent)
            }
            return true
        } catch {
            guard let onError = binding.onError else {
                Logger.jsonRender.error("Action \(binding.action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
            guard isCurrent() else { return false }
            return await runFollowUp(onError, error: error, while: isCurrent)
        }
    }

    // MARK: Execution

    private func execute(_ action: String, params: [String: JSONValue]) async throws -> Outcome {
        let store = session.store
        switch action {
        case "setState":
            guard let path = params["statePath"]?.stringValue, !path.isEmpty else { return .completed }
            store.set(params["value"], at: path)
            return .completed

        case "pushState":
            guard let path = params["statePath"]?.stringValue, !path.isEmpty else { return .completed }
            let item = resolveIDTokens(params["value"]) ?? .null
            let items = store.peek(at: path)?.arrayValue ?? []
            var writes: [(pointer: String, value: JSONValue?)] = [(path, .array(items + [item]))]
            if let clear = params["clearStatePath"]?.stringValue, !clear.isEmpty {
                writes.append((clear, .string("")))
            }
            store.update(writes)
            return .completed

        case "removeState":
            guard let path = params["statePath"]?.stringValue, let index = params["index"]?.doubleValue else {
                return .completed
            }
            let items = store.peek(at: path)?.arrayValue ?? []
            let kept = items.enumerated().filter { Double($0.offset) != index }.map(\.element)
            store.set(.array(kept), at: path)
            return .completed

        case "resetForm":
            session.resetForm(statePath: params["statePath"]?.stringValue, value: params["value"])
            return .completed

        case "submit":
            guard session.validateAll() else { return .halted }
            return try await runHost(action, params: params)

        default:
            if handler(for: action) != nil { return try await runHost(action, params: params) }
            switch action {
            case "showAlert":
                session.alert = AlertRequest(
                    title: params["title"].map(JS.toString) ?? "",
                    message: params["message"].map(JS.toString)
                )
            case "openURL":
                guard let string = params["url"]?.stringValue, let url = URL(string: string) else {
                    Logger.jsonRender.warning("openURL: invalid url param")
                    break
                }
                session.open(url)
            default:
                Logger.jsonRender.warning("No handler registered for action: \(action, privacy: .public)")
            }
            return .completed
        }
    }

    private func runHost(_ action: String, params: [String: JSONValue]) async throws -> Outcome {
        guard let handler = handler(for: action) else {
            Logger.jsonRender.warning("No handler registered for action: \(action, privacy: .public)")
            return .completed
        }
        session.actionStarted(action)
        defer { session.actionFinished(action) }
        try await handler(params, session)
        return .completed
    }

    /// `onSuccess` / `onError`: `{ "set": { ptr: value } }` or `{ "action", "params"? }`.
    private func runFollowUp(_ followUp: JSONValue, error: Error?, while isCurrent: () -> Bool) async -> Bool {
        if let assignments = followUp["set"]?.objectValue {
            session.store.update(assignments.map { pointer, value in
                if let error, value == .string("$error.message") {
                    return (pointer, .string(error.localizedDescription))
                }
                return (pointer, value)
            })
        } else if let binding = ActionBinding(json: followUp) {
            return await run(binding, while: isCurrent)
        } else if followUp["navigate"] != nil {
            Logger.jsonRender.info("onSuccess.navigate is not supported by the SwiftUI runtime")
        }
        return true
    }

    /// RN `pushState` tokens: `"$id"` or `{ "$id": true }` become unique ids.
    private func resolveIDTokens(_ value: JSONValue?) -> JSONValue? {
        switch value {
        case .string("$id")?:
            return .string(nextID())
        case .object(let members)?:
            if members.count == 1, members["$id"] != nil { return .string(nextID()) }
            return .object(members.mapValues { resolveIDTokens($0) ?? .null })
        case .array(let items)?:
            return .array(items.map { resolveIDTokens($0) ?? .null })
        default:
            return value
        }
    }

    private func nextID() -> String {
        idCounter += 1
        return "\(Int(Date().timeIntervalSince1970 * 1000))-\(idCounter)"
    }
}
