import Foundation
import Observation

/// Anything expressions, visibility conditions and validation args can read state from.
public protocol StateReading {
    /// Value at a JSON Pointer, or `nil` when absent (`undefined`).
    func value(at pointer: String) -> JSONValue?
}

extension JSONValue: StateReading {}

/// Observable JSON state model addressed by JSON Pointers.
///
/// Observation is fine-grained: views that read ``value(at:)`` are only
/// invalidated when that pointer (or one of its ancestors/descendants) changes,
/// so typing in one field does not re-render unrelated fields. Reading
/// ``state`` observes the whole document.
@MainActor
@Observable
public final class StateStore {
    /// A single state change: the pointers written and the full document before/after.
    /// Compare `oldState`/`newState` to find affected locations (pointers may be aliases
    /// such as `/items/-`).
    public struct Change: Sendable {
        public let pointers: [String]
        public let oldState: JSONValue
        public let newState: JSONValue
    }

    @ObservationIgnored private var storage: JSONValue
    @ObservationIgnored private var slots: [String: Slot] = [:]
    @ObservationIgnored private var observers: [UUID: @MainActor (Change) -> Void] = [:]

    public init(initialState: JSONValue = .object([:])) {
        storage = initialState.objectValue != nil ? initialState : .object([:])
    }

    /// The whole state document. Reading it observes every change.
    public var state: JSONValue {
        access(keyPath: \.state)
        return storage
    }

    /// Reads a value and observes only that pointer.
    public func value(at pointer: String) -> JSONValue? {
        slot(for: pointer).value
    }

    /// Reads a value without registering an observation dependency.
    public func peek(at pointer: String) -> JSONValue? {
        storage.value(at: pointer)
    }

    /// Writes `value` at `pointer` (`nil` removes it). No-op when the value is unchanged.
    public func set(_ value: JSONValue?, at pointer: String) {
        update([(pointer, value)])
    }

    /// Applies several writes with a single change notification.
    public func update(_ writes: [(pointer: String, value: JSONValue?)]) {
        var next = storage
        var changed: [String] = []
        for write in writes where next.value(at: write.pointer) != write.value {
            next = next.setting(write.value, at: write.pointer)
            changed.append(write.pointer)
        }
        guard !changed.isEmpty else { return }
        commit(next, changed: changed)
    }

    /// Replaces the whole document (e.g. when a new spec is loaded).
    public func replace(with state: JSONValue) {
        let next = state.objectValue != nil ? state : .object([:])
        guard next != storage else { return }
        commit(next, changed: [""])
    }

    /// Registers a change observer; returns a token for ``removeObserver(_:)``.
    @discardableResult
    public func addObserver(_ observer: @escaping @MainActor (Change) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: Private

    private func commit(_ next: JSONValue, changed pointers: [String]) {
        let old = storage
        withMutation(keyPath: \.state) { storage = next }
        // Re-read every observed pointer rather than matching pointer text: writes such as
        // `/items/-` (append) or `/items/00` (alias of `/items/0`) affect locations whose
        // pointers do not overlap textually. Unchanged slots are not invalidated.
        for (pointer, slot) in slots {
            let value = next.value(at: pointer)
            if slot.value != value { slot.value = value }
        }
        let change = Change(pointers: pointers, oldState: old, newState: next)
        for observer in observers.values { observer(change) }
    }

    private func slot(for pointer: String) -> Slot {
        if let slot = slots[pointer] { return slot }
        let slot = Slot(value: storage.value(at: pointer))
        slots[pointer] = slot
        return slot
    }

    @Observable
    final class Slot {
        var value: JSONValue?
        init(value: JSONValue?) { self.value = value }
    }
}

extension StateStore: @MainActor StateReading {}
