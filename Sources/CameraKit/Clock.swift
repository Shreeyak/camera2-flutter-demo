import Foundation

/// Injectable clock for timing-sensitive code (watchdogs, recovery backoff, AE timeout).
///
/// Production uses `SystemClock`; tests use `TestClock` to drive time forward synchronously.
public protocol CameraKitClock: Sendable {
    /// Milliseconds since an arbitrary epoch. Monotonic; not wall-clock.
    func nowMs() -> UInt64
    /// Sleep for the given duration. Cancellation-aware.
    func sleep(milliseconds: Int) async throws
}

public struct SystemClock: CameraKitClock {
    public init() {}
    public func nowMs() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
    public func sleep(milliseconds: Int) async throws {
        try await Task.sleep(for: .milliseconds(milliseconds))
    }
}
