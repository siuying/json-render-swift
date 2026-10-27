import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import Observation
import OSLog

/// The runtime for one rendered spec: state, validation, actions and presentation.
///
/// ```swift
/// let session = FormSession(spec: spec)
/// JSONRenderView(session: session)
///     .onJSONRenderAction("submit") { params, session in … }
/// ```
///
/// Assigning ``spec`` repeatedly while a spec streams in is cheap and safe: state is
/// re-seeded only when the root key changes; otherwise newly streamed `state` values
/// are merged without overwriting what the user has already entered.
@MainActor
@Observable
public final class FormSession {
    /// The state model (`spec.state` seeded, then user/action edits).
    public let store: StateStore
    /// Per-field validation state.
    @ObservationIgnored public let validation = ValidationStore()
    /// Built-in and host action handling.
    @ObservationIgnored public private(set) lazy var actions = ActionDispatcher(session: self)

    /// Custom validation functions available to `checks` (built-ins take precedence).
    @ObservationIgnored public var validators: [String: ValidationFunction]

    /// The spec being rendered. May be partial while streaming.
    public var spec: Spec? {
        didSet { specDidChange(from: oldValue) }
    }

    /// The state the form resets to (`spec.state` of the current spec).
    public private(set) var initialState: JSONValue

    /// Alert requested by `showAlert`; presented by ``JSONRenderView``.
    public var alert: AlertRequest?
    /// Confirmation requested by an action's `confirm`; presented by ``JSONRenderView``.
    public private(set) var confirmation: ConfirmationRequest?
    /// Host actions currently executing (e.g. `"submit"` while the handler awaits). An
    /// action stays listed until every concurrent run of it has finished.
    public var runningActions: Set<String> { Set(runningCounts.keys) }
    private var runningCounts: [String: Int] = [:]

    /// Opens URLs for the `openURL` action. Defaults to the SwiftUI environment's
    /// `openURL` once a ``JSONRenderView`` has rendered, else the system
    /// (`UIApplication` / `NSWorkspace`); set it to intercept links.
    @ObservationIgnored public var urlOpener: (@MainActor (URL) -> Void)?

    @ObservationIgnored var openURLAction: (@MainActor (URL) -> Void)?
    @ObservationIgnored private var suppressFieldValidation = false
    @ObservationIgnored private var suppressWatchers = false
    /// Incremented whenever a new root is loaded; stale watcher chains check it.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watchTasks: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    public init(spec: Spec? = nil, validators: [String: ValidationFunction] = [:]) {
        self.spec = spec
        self.validators = validators
        let seed = spec?.state ?? .object([:])
        initialState = seed
        store = StateStore(initialState: seed)
        store.addObserver { [weak self] change in self?.stateDidChange(change) }
    }

    // MARK: Spec updates

    /// Seeding and merging `spec.state` is initialization, not a user change: it neither
    /// triggers change-validation nor fires `watch` bindings.
    private func specDidChange(from oldSpec: Spec?) {
        guard spec != oldSpec else { return }
        let newSeed = spec?.state ?? .object([:])
        if spec?.root != oldSpec?.root {
            generation += 1
            cancelWatchers { _ in true }
            initialState = newSeed
            validation.reset()
            seeding { store.replace(with: newSeed) }
            return
        }
        if newSeed != initialState {
            let merged = StateMerge.merge(current: store.peek(at: "") ?? .object([:]), oldSeed: initialState, newSeed: newSeed)
            initialState = newSeed
            seeding { store.replace(with: merged) }
        }
        cancelWatchers { [spec] key in spec?.elements[key]?.watch.isEmpty != false }
        reconcileValidation()
    }

    /// After a same-root spec update: clears state of fields no longer in the spec (removed
    /// or rebound) and re-runs validation for validated fields, whose checks may have
    /// changed. Hidden-but-present fields keep their state.
    private func reconcileValidation() {
        guard let spec else { return }
        let state = store.peek(at: "") ?? .object([:])
        let declaredPaths = Set(FormField.fields(in: spec, state: state, includeHidden: true).map(\.path))
        for field in validation.fieldsWithState where !declaredPaths.contains(field.path) {
            field.reset()
        }
        for field in FormField.fields(in: spec, state: state) where validation.field(field.path).validated {
            validate(field)
        }
    }

    // MARK: Fields

    /// Fields (elements with `checks` bound via `$bindState`) currently visible.
    public var visibleFields: [FormField] {
        guard let spec else { return [] }
        return FormField.fields(in: spec, state: store.peek(at: "") ?? .object([:]))
    }

    /// Runs validation for one field and records the result.
    @discardableResult
    public func validate(_ field: FormField) -> ValidationResult {
        let state = store.peek(at: "") ?? .object([:])
        let result = Validation.run(
            field.config,
            value: state.value(at: field.path),
            state: state,
            customFunctions: validators,
            valuePointer: field.path
        )
        validation.field(field.path).record(result)
        return result
    }

    /// Validates every visible field; returns `true` when all pass (core `validateAll`).
    @discardableResult
    public func validateAll() -> Bool {
        var allValid = true
        for field in visibleFields where !validate(field).valid {
            allValid = false
        }
        return allValid
    }

    /// Called by input components when focus leaves a field.
    public func fieldDidBlur(_ field: FormField) {
        validation.field(field.path).touched = true
        if field.validateOn == .blur { validate(field) }
    }

    /// Restores `initialState` (or writes `value` / the initial value at `statePath`)
    /// and clears the affected validation state. `watch` bindings still fire.
    public func resetForm(statePath: String? = nil, value: JSONValue? = nil) {
        withoutFieldValidation {
            if let statePath, !statePath.isEmpty {
                store.set(value ?? initialState.value(at: statePath), at: statePath)
                validation.reset(under: statePath)
            } else {
                store.replace(with: initialState)
                validation.reset()
            }
        }
    }

    /// Re-validates fields that already show results, plus `validateOn: change` fields
    /// whose value changed, so errors stay current (including cross-field checks).
    private func stateDidChange(_ change: StateStore.Change) {
        guard spec != nil else { return }
        if !suppressFieldValidation {
            for field in visibleFields {
                let valueChanged = change.oldState.value(at: field.path) != change.newState.value(at: field.path)
                if validation.field(field.path).validated || (field.validateOn == .change && valueChanged) {
                    validate(field)
                }
            }
        }
        if !suppressWatchers { fireWatchers(change) }
    }

    private func withoutFieldValidation(_ body: () -> Void) {
        suppressFieldValidation = true
        body()
        suppressFieldValidation = false
    }

    private func seeding(_ body: () -> Void) {
        suppressWatchers = true
        withoutFieldValidation(body)
        suppressWatchers = false
    }

    // MARK: Events & actions

    /// Dispatches the bindings an element declares for `event` (e.g. `"press"`).
    public func emit(_ event: String, from elementKey: String, datum: JSONValue? = nil) async {
        guard let bindings = spec?.elements[elementKey]?.on[event] else { return }
        await actions.dispatch(bindings, datum: datum)
    }

    /// Runs an action by name; `params` may contain expressions.
    public func perform(_ action: String, params: [String: JSONValue] = [:]) async {
        await actions.dispatch(ActionBinding(action: action, params: params))
    }

    /// Fires `watch` bindings of mounted (visible) elements whose watched value changed.
    /// Each element runs one chain at a time (a newer change cancels the older chain), and
    /// a chain stops once its element is removed, hidden or a new root is loaded.
    private func fireWatchers(_ change: StateStore.Change) {
        guard let spec else { return }
        for (key, element) in FormField.visibleElements(in: spec, state: change.newState) where !element.watch.isEmpty {
            let triggered = element.watch.sorted(by: { $0.key < $1.key })
                .filter { change.oldState.value(at: $0.key) != change.newState.value(at: $0.key) }
                .flatMap(\.value)
            if !triggered.isEmpty { startWatcher(key: key, bindings: triggered) }
        }
    }

    private func startWatcher(key: String, bindings: [ActionBinding]) {
        watchTasks[key]?.task.cancel()
        let id = UUID()
        let generation = generation
        let task = Task { [weak self] in
            guard let self else { return }
            await actions.run(bindings, while: { self.isWatcherCurrent(key: key, generation: generation) })
            if watchTasks[key]?.id == id { watchTasks[key] = nil }
        }
        watchTasks[key] = (id, task)
    }

    private func isWatcherCurrent(key: String, generation: Int) -> Bool {
        guard !Task.isCancelled, generation == self.generation, let spec,
              spec.elements[key]?.watch.isEmpty == false else { return false }
        return FormField.visibleElements(in: spec, state: store.peek(at: "") ?? .object([:])).contains { $0.key == key }
    }

    private func cancelWatchers(where shouldCancel: (String) -> Bool) {
        for (key, entry) in watchTasks where shouldCancel(key) {
            entry.task.cancel()
            watchTasks[key] = nil
        }
    }

    func actionStarted(_ action: String) { runningCounts[action, default: 0] += 1 }

    func actionFinished(_ action: String) {
        let remaining = (runningCounts[action] ?? 1) - 1
        runningCounts[action] = remaining > 0 ? remaining : nil
    }

    func open(_ url: URL) {
        if let urlOpener { return urlOpener(url) }
        if let openURLAction { return openURLAction(url) }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: Confirmation

    func requestConfirmation(
        title: String, message: String, confirmLabel: String?, cancelLabel: String?, isDestructive: Bool
    ) async -> Bool {
        resolveConfirmation(false)
        return await withCheckedContinuation { continuation in
            confirmation = ConfirmationRequest(
                title: title,
                message: message,
                confirmLabel: confirmLabel ?? "Confirm",
                cancelLabel: cancelLabel ?? "Cancel",
                isDestructive: isDestructive,
                continuation: continuation
            )
        }
    }

    /// Completes the pending confirmation (`true` runs the action).
    public func resolveConfirmation(_ confirmed: Bool) {
        guard let pending = confirmation else { return }
        confirmation = nil
        pending.continuation?.resume(returning: confirmed)
    }
}
