import Atomics
import Foundation
import Synchronization

/// Which wall of the stall-detection pair this instance is.
public enum WatchdogKind: Sendable {
    case gpu
    case capture

    var thresholdMs: Int {
        switch self {
        case .gpu: return Constants.stallGpuThresholdMs
        case .capture: return Constants.stallCaptureThresholdMs
        }
    }

    var messagePrefix: String {
        switch self {
        case .gpu: return "gpu:"
        case .capture: return "capture:"
        }
    }
}

/// Fire callback payload.
public struct WatchdogFire: Sendable {
    public let kind: WatchdogKind
    public let armedSessionToken: UInt64
    public let thresholdMs: Int
}

/// Stall watchdog. `refresh()` is lock-free (ManagedAtomic) — safe from the delivery queue.
public final class Watchdog: @unchecked Sendable {

    public let kind: WatchdogKind

    private let clock: any CameraKitClock
    private let onFire: @Sendable (WatchdogFire) -> Void

    private let lastKickMs: ManagedAtomic<UInt64> = ManagedAtomic(0)

    private let state: Mutex<State>

    private struct State {
        var armedToken: UInt64?
        var pollerTask: Task<Void, Never>?
    }

    public init(
        kind: WatchdogKind,
        clock: any CameraKitClock,
        onFire: @escaping @Sendable (WatchdogFire) -> Void
    ) {
        self.kind = kind
        self.clock = clock
        self.onFire = onFire
        self.state = Mutex(State())
    }

    /// Inspect the armed session token (test seam).
    public var armedSessionToken: UInt64? {
        state.withLock { $0.armedToken }
    }

    /// Arm the watchdog for a session.
    public func arm(sessionToken: UInt64) {
        lastKickMs.store(clock.nowMs(), ordering: .releasing)
        let poller = Task { [weak self, clock, kind, onFire] in
            let halfMs = max(50, kind.thresholdMs / 4)
            while !Task.isCancelled {
                try? await clock.sleep(milliseconds: halfMs)
                guard let self else { return }
                let now = clock.nowMs()
                let last = self.lastKickMs.load(ordering: .acquiring)
                if now >= last + UInt64(kind.thresholdMs) {
                    let armed: UInt64? = self.state.withLock { $0.armedToken }
                    guard let token = armed else { return }
                    CameraKitLog.warning(
                        .engine,
                        "[watchdog] \(kind.messagePrefix) stall thresholdMs=\(kind.thresholdMs) token=\(token)"
                    )
                    onFire(WatchdogFire(kind: kind, armedSessionToken: token, thresholdMs: kind.thresholdMs))
                    self.state.withLock { $0.armedToken = nil }
                    return
                }
            }
        }
        state.withLock { s in
            s.armedToken = sessionToken
            s.pollerTask?.cancel()
            s.pollerTask = poller
        }
    }

    /// Record a fresh observation.
    ///
    /// Lock-free.
    public func refresh() {
        lastKickMs.store(clock.nowMs(), ordering: .releasing)
    }

    /// Disarm.
    public func disarm() {
        let task: Task<Void, Never>? = state.withLock { s in
            let t = s.pollerTask
            s.pollerTask = nil
            s.armedToken = nil
            return t
        }
        task?.cancel()
    }
}

/// Convenience container held by `CameraEngine`.
public struct WatchdogPair: Sendable {
    public let gpu: Watchdog
    public let capture: Watchdog

    public init(gpu: Watchdog, capture: Watchdog) {
        self.gpu = gpu
        self.capture = capture
    }

    public func disarmAll() {
        gpu.disarm()
        capture.disarm()
    }
}

extension Watchdog {
    /// Static convenience per brief §4.
    public static func disarmAll(_ pair: WatchdogPair) { pair.disarmAll() }
}
