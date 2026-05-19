import CameraKit
import Foundation

/// Thread-safe registry mapping opaque `Int64` handles to `CameraEngine` instances.
///
/// Dart owns the handle; Swift owns the engine. Every `open()` call constructs a
/// new `CameraEngine` (itself an actor) and registers it here, returning the
/// freshly-minted handle across the Pigeon boundary. Subsequent HostApi calls
/// resolve the handle back to the engine and forward the request.
///
/// Implemented as a Swift `actor` so concurrent Pigeon callbacks (each running
/// on its own Task) cannot race the counter or the backing map. The monotonic
/// counter starts at `1` so that `0` can serve as a sentinel "no handle" value
/// on the Dart side without colliding with a valid registration.
actor HandleRegistry {

    /// Thrown by `resolve(_:)` when the supplied handle is not registered.
    ///
    /// Either the handle was never issued, was already unregistered via
    /// `close()`, or belongs to a different registry instance.
    struct NotFound: Error {
        let handle: Int64
    }

    // MARK: - State

    private var nextHandle: Int64 = 1
    private var engines: [Int64: CameraEngine] = [:]

    // MARK: - Public API

    /// Registers an engine and returns a fresh handle.
    ///
    /// The handle is monotonically increasing — handles are never reused, even
    /// after the corresponding engine is unregistered. This matches Android's
    /// long-handle semantics and lets logs disambiguate "engine 4 closed" from
    /// "engine 4 opened again" trivially.
    func register(_ engine: CameraEngine) -> Int64 {
        let handle = nextHandle
        nextHandle += 1
        engines[handle] = engine
        return handle
    }

    /// Resolves a handle to its registered engine.
    ///
    /// - Throws: `HandleRegistry.NotFound` if the handle is unknown.
    func resolve(_ handle: Int64) throws -> CameraEngine {
        guard let engine = engines[handle] else {
            throw NotFound(handle: handle)
        }
        return engine
    }

    /// Removes the mapping for a handle. Idempotent — unknown handles are silently ignored.
    ///
    /// Callers should invoke this from `close()` once the engine has finished
    /// shutting down. Releasing the dictionary slot drops the registry's strong
    /// reference; if no other ARC owners exist, the engine deinitialises.
    func unregister(_ handle: Int64) {
        engines.removeValue(forKey: handle)
    }

    /// Returns the number of currently-registered engines. Intended for tests
    /// and diagnostic logging.
    func count() -> Int {
        engines.count
    }

    /// Returns a snapshot of every currently-registered engine.
    ///
    /// Used by `LifecycleObserver` to fan a single UIScene phase transition
    /// out to every open engine. Returning only the values (not the handles)
    /// is deliberate: callers cannot mutate the registry through this snapshot
    /// and cannot match an engine back to its Dart-side handle, which keeps
    /// the abstraction tight. The snapshot is a value-copy of the dictionary's
    /// values at the moment the actor serviced the call; concurrent
    /// register/unregister calls after the copy don't affect the returned array.
    func allEngines() -> [CameraEngine] {
        Array(engines.values)
    }
}
