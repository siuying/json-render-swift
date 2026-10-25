import Foundation
import Synchronization

/// Incrementally compiles a JSONL (RFC 6902 patch per line) stream into a ``Spec``
/// using core's `createSpecStreamCompiler` inside the JavaScript bridge.
///
/// ```swift
/// let compiler = try await bridge.makeStreamCompiler()
/// do {
///     for try await chunk in textStream {
///         let update = try await compiler.push(chunk)
///         if !update.newPatches.isEmpty { session.spec = update.spec }
///     }
///     session.spec = try await compiler.finish()
/// } catch {
///     await compiler.dispose()   // cancelled or failed stream
/// }
/// ```
///
/// ``finish()`` flushes a trailing line without a newline and frees the JavaScript-side
/// compiler; ``dispose()`` frees it without flushing. A compiler released without either
/// is disposed automatically.
public final class SpecStreamCompiler: Sendable {
    public struct Update: Sendable, Hashable {
        /// The spec compiled so far.
        public var spec: Spec
        /// Patches applied by this push (empty when the chunk had no complete line).
        public var newPatches: [JSONValue]
    }

    let bridge: JSONRenderBridge
    let handle: Int
    private let isClosed = Mutex(false)

    init(bridge: JSONRenderBridge, handle: Int) {
        self.bridge = bridge
        self.handle = handle
    }

    deinit {
        guard !isClosed.withLock({ $0 }) else { return }
        let bridge = bridge, handle = handle
        Task { try? await bridge.compilerDispose(handle: handle) }
    }

    /// Feeds raw stream text; complete lines are parsed and applied.
    public func push(_ chunk: String) async throws -> Update {
        try await bridge.compilerPush(handle: handle, chunk: chunk)
    }

    /// Flushes any buffered final line and returns the final spec.
    public func finish() async throws -> Spec {
        markClosed()
        return try await bridge.compilerFinish(handle: handle)
    }

    /// Frees the compiler without flushing (e.g. the stream was cancelled). Idempotent.
    public func dispose() async {
        guard markClosed() else { return }
        try? await bridge.compilerDispose(handle: handle)
    }

    /// Marks the compiler closed; returns `false` if it already was.
    @discardableResult
    private func markClosed() -> Bool {
        isClosed.withLock { closed in
            defer { closed = true }
            return !closed
        }
    }
}
