import Atomics
import Foundation

/// ADR-30: Dispatches `work` onto `queue` and resumes the caller when either
/// the work signals completion or `timeout` elapses — whichever comes first.
///
/// Never throws: a timeout is an observable state stall, not an error. The caller
/// can detect a stall by observing that the session-lifecycle state did not advance.
///
/// Uses a `ManagedAtomic<Bool>` CAS to guarantee the continuation resumes exactly
/// once regardless of which branch wins the race. `withThrowingTaskGroup` is NOT
/// used here because group teardown blocks until all child tasks finish, and a
/// `withCheckedContinuation` that is awaiting a blocking operation (e.g. a hung
/// `stopRunning()`) will not respond to task cancellation — causing a deadlock.
func runOnQueue(
    _ queue: DispatchQueue,
    timeout: Duration = .seconds(Constants.sessionLifecycleTimeoutSeconds),
    _ work: @escaping @Sendable () -> Void
) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let resumed = ManagedAtomic<Bool>(false)
        let resumeOnce: @Sendable () -> Void = {
            let (won, _) = resumed.compareExchange(
                expected: false, desired: true,
                ordering: .sequentiallyConsistent
            )
            if won { cont.resume() }
        }

        // Deadline branch: resumes after timeout if work hasn't finished yet.
        Task {
            try? await Task.sleep(for: timeout)
            resumeOnce()
        }

        // Work branch: resumes as soon as work() returns.
        queue.async {
            work()
            resumeOnce()
        }
    }
}
