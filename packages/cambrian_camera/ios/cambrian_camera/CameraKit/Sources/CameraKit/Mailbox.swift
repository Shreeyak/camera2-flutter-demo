import Foundation
import os

/// Lock-protected cross-isolation reference cell.
///
/// Names the convention used at every cross-isolation mailbox site in
/// CameraKit so the safety contract lives once, on the type, instead of being
/// re-cited at each call site.
///
/// # Contract
///
/// - Holds a single optional value (`T?`), typically a pointer-sized reference
///   (Swift class / Core Foundation / NSObject) such as an `MTLTexture`,
///   `CVPixelBuffer`, cached `AsyncStream`, or `MetalPipeline` handle.
/// - `store(_:)` and `latest` are serialized by an `OSAllocatedUnfairLock`, so
///   the ARC retain (on read) and release (on overwrite) happen under the lock.
///   Concurrent read/write from different isolation domains is therefore safe.
/// - "latest" returns the most recently stored value, or `nil` before any
///   `store(_:)`. Readers may observe the previous or the next value across a
///   concurrent `store(_:)`; both are valid, fully-retained references.
///
/// # Why the lock
///
/// The render loop (`MTKViewDelegate.draw`, the Flutter texture bridge) reads
/// these cells on its own thread while the capture/delivery queue writes them.
/// An unsynchronized `var _value: T?` races the reader's retain against the
/// writer's release of the same reference → over-release → `EXC_BAD_ACCESS`
/// (a pointer-authentication trap in `Mailbox.latest.getter`, observed during
/// background/recovery — measurements 2026-05-20 §1). The lock closes that hole
/// for every site uniformly, including downstream consumers (cam2fd's bridge).
///
/// # Writer guidance
///
/// A single writer on one fixed queue / isolation domain remains the intended
/// usage, and the owner documents which. Multiple writers are now *safe*
/// (last-store-wins) but still a design smell — prefer a single writer so the
/// observable ordering is obvious. `mailbox.store(...)` outside the documented
/// writer context is grepable (`grep 'Mailbox<'`) and reviewable.
public final class Mailbox<T>: @unchecked Sendable {
    // Void-state unfair lock used as a plain mutex so `T` stays unconstrained
    // (`OSAllocatedUnfairLock<State>` would require `State: Sendable`). Safety of
    // the `_value` access is vouched for by this lock — hence `@unchecked Sendable`.
    private let lock = OSAllocatedUnfairLock()
    private var _value: T?

    public init(_ initial: T? = nil) {
        self._value = initial
    }

    /// Replace the stored value.
    ///
    /// Serialized with `latest` by the lock.
    public func store(_ value: T?) {
        lock.lock()
        _value = value
        lock.unlock()
    }

    /// Latest stored value, or `nil` before any `store(_:)` call.
    ///
    /// The retain of the returned reference happens under the lock, so it cannot
    /// race a concurrent `store(_:)`'s release.
    public var latest: T? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }
}
