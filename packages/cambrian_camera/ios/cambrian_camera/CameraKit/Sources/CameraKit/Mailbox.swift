import Foundation

/// Single-writer cross-isolation reference cell.
///
/// Names the convention used at every `nonisolated(unsafe)` mailbox site
/// in CameraKit so the safety contract lives once, on the type, instead
/// of being re-cited at each call site.
///
/// # Contract
///
/// - Exactly one writer, on one fixed queue / isolation domain. The owner
///   documents which.
/// - Stored values are pointer-sized references (Swift class / Core
///   Foundation / NSObject) or written exactly once before any read
///   (lazy-init form, e.g. cached stream construction in init).
/// - Readers tolerate seeing the previous or the next reference; tearing
///   is precluded by single-pointer-sized stores.
///
/// # What `Mailbox` does NOT do
///
/// - It adds NO synchronization. The hot path remains identical to the
///   raw `nonisolated(unsafe)` form it replaces.
/// - It does not catch new categories of bug at compile time —
///   `nonisolated(unsafe)` was already explicit.
/// - It does not protect against multi-writer scenarios. If two writers
///   need access from different isolation domains, use an actor or a
///   `Mutex`, not `Mailbox`.
///
/// # Why use it
///
/// The invariant is stated once on the type. The pattern is grepable
/// (`grep 'Mailbox<'`) and reviewable: `mailbox.store(...)` outside the
/// documented writer context is a review smell that raw
/// `nonisolated(unsafe)` provides no syntactic distinction for.
public final class Mailbox<T>: @unchecked Sendable {
    private var _value: T?

    public init(_ initial: T? = nil) {
        self._value = initial
    }

    /// Replace the stored value.
    ///
    /// Single-writer contract applies — the
    /// owner type documents which queue / isolation domain calls this.
    public func store(_ value: T?) {
        _value = value
    }

    /// Latest stored value, or `nil` before any `store(_:)` call.
    public var latest: T? {
        _value
    }
}
