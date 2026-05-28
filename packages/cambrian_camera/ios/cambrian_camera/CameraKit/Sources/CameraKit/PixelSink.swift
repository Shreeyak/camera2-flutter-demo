import CameraKitInterop
import CoreMedia
import CoreVideo
import Foundation
import OSLog
import Synchronization

// Stage 08 — Real ConsumerRegistry backed by CppPixelSinkPool (Mechanism A, D-01 / D-03).
// Dual-dispatch: yield() drives both Swift AsyncStream subscribers and C++ pool consumers.

/// Opaque token returned by `ConsumerRegistry.subscribe(stream:)` and
/// `.registerCallback(stream:callbacks:)`.
public struct ConsumerToken: Sendable, Hashable {
    public let id: UInt64
    public let stream: StreamId

    public init(id: UInt64, stream: StreamId) {
        self.id = id
        self.stream = stream
    }
}

/// C-ABI-shaped callback struct per ADR-31 and D-03.
public struct PixelSinkCallbacks: @unchecked Sendable {
    // swiftlint:disable nesting
    public typealias OnFrame =
        @convention(c) (
            _ context: UnsafeMutableRawPointer?, _ stream: UInt32,
            _ frameNumber: UInt64, _ presentationTimeNs: Int64,
            _ surface: UnsafeMutableRawPointer?
        ) -> Void
    public typealias OnOverwrite =
        @convention(c) (_ context: UnsafeMutableRawPointer?, _ stream: UInt32) -> Void
    public typealias OnError =
        @convention(c) (_ context: UnsafeMutableRawPointer?, _ code: Int32) -> Void
    // swiftlint:enable nesting

    public let onFrame: OnFrame?
    public let onOverwrite: OnOverwrite?
    public let onError: OnError?
    public let context: UnsafeMutableRawPointer?

    public init(
        onFrame: OnFrame?,
        onOverwrite: OnOverwrite?,
        onError: OnError?,
        context: UnsafeMutableRawPointer?
    ) {
        self.onFrame = onFrame
        self.onOverwrite = onOverwrite
        self.onError = onError
        self.context = context
    }
}

/// Swift facade for the consumer fan-out (D-01).
///
/// `subscribe(stream:)` uses `AsyncStream` directly (Phase A of D-01's dual-dispatch).
/// `registerCallback(stream:callbacks:)` inserts a C++ pool entry (D-03).
/// `yield(_:stream:)` dispatches to both paths.
///
/// Actor isolation governs subscribe/unregister/registerCallback (cold paths).
/// Publication runs on the delivery queue via a `nonisolated` `yield(_:stream:)`
/// — no actor hop on the frame clock (ADR-02).
public actor ConsumerRegistry {

    // MARK: - Internal table

    private struct Subscriber: Sendable {
        let id: UInt64
        let continuation: AsyncStream<FrameSet>.Continuation
    }

    private struct InnerState {
        var subscribers: [StreamId: [Subscriber]] = [:]
        var nextId: UInt64 = 0
        /// Per-lane drop counter incremented when `Continuation.yield` returns `.dropped`.
        var dropCounts: [StreamId: UInt64] = [:]
    }

    // `nonisolated let` so `yield(_:stream:)` (non-isolated) can reach the mutex
    // without an actor hop. `Mutex` is Sendable.
    private nonisolated let state: Mutex<InnerState> = Mutex(InnerState())

    // C++ pool — owns all C-ABI consumer registrations.
    // `nonisolated let` so `yield()` (nonisolated) can dispatch without actor hop.
    nonisolated let cppPool: CppPixelSinkPool = CppPixelSinkPool()

    // D-11 metrics stream — cached (one underlying stream, shared by re-callers)
    // and the live `MetricsSink` it drives. `metricsSink` is retained here so a
    // teardown via `release()` can tear it down deterministically; the stream's
    // own `onTermination` also releases it when a caller cancels independently.
    private var cachedMetricsStream: AsyncStream<FrameDeliveryStats>?
    private var metricsSink: MetricsSink?

    public init() {}

    // MARK: - Subscribe (Swift lane, D-01)

    /// Returns an `AsyncStream<FrameSet>` with `.bufferingNewest(1)` per ADR-22.
    ///
    /// Termination of the stream (consuming `Task` cancelled or returned) removes
    /// the subscriber synchronously via `onTermination`.
    public func subscribe(stream: StreamId) -> AsyncStream<FrameSet> {
        let id = state.withLock { inner -> UInt64 in
            inner.nextId &+= 1
            return inner.nextId
        }
        return AsyncStream<FrameSet>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.state.withLock { inner in
                inner.subscribers[stream, default: []].append(
                    Subscriber(id: id, continuation: continuation))
            }
            continuation.onTermination = { [self] _ in
                self.state.withLock { inner in
                    inner.subscribers[stream]?.removeAll { $0.id == id }
                }
            }
        }
    }

    // MARK: - registerCallback (C-ABI lane, D-03)

    /// Registers a C-ABI consumer in the C++ pool.
    ///
    /// Throws `InteropError.invalidCallbacks` if `callbacks.onFrame` is nil
    /// (D-03), or `InteropError.missingOnOverwrite` if `callbacks.onOverwrite`
    /// is nil — the G-26-avoidance quality gate (D-11): a sink that cannot
    /// surface mailbox-overwrite drops is rejected at registration time.
    public func registerCallback(
        stream: StreamId,
        callbacks: PixelSinkCallbacks
    ) throws -> ConsumerToken {
        guard let onFrame = callbacks.onFrame else { throw InteropError.invalidCallbacks }
        guard let onOverwrite = callbacks.onOverwrite else {
            throw InteropError.missingOnOverwrite
        }
        // onError is optional per D-03; default to a no-op to satisfy CppPixelSinkCallbacks.
        let onError: PixelSinkCallbacks.OnError = callbacks.onError ?? { _, _ in }

        let cbs = CppPixelSinkCallbacks(
            onFrame: onFrame,
            onOverwrite: onOverwrite,
            onError: onError,
            context: callbacks.context
        )
        let token = cppPool.register(stream: stream.rawPoolId, callbacks: cbs)
        // The C++ pool enforces the same G-26 gate and returns token 0 when it
        // rejects a registration — defense in depth behind the guard above.
        guard token != 0 else { throw InteropError.missingOnOverwrite }
        CameraKitLog.notice(
            .consumers,
            "registerCallback: stream=\(stream.rawPoolId) token=\(token) cppCount=\(self.cppPool.consumerCount(stream: stream.rawPoolId))"
        )
        return ConsumerToken(id: token, stream: stream)
    }

    // MARK: - Metrics stream (D-11)

    /// A single `AsyncStream<FrameDeliveryStats>` aggregating Swift-side per-lane
    /// drop counters and the C++ pool's `mailbox_overwrite_count` atomics (D-11).
    ///
    /// The C++ pool drives the cadence — one emission per `FPS_MEASUREMENT_WINDOW_FRAMES`
    /// — via its metrics callback; each sample carries per-lane *deltas*, not
    /// cumulative counts. Cached: re-callers receive the same stream.
    public func metricsStream() -> AsyncStream<FrameDeliveryStats> {
        if let cached = cachedMetricsStream { return cached }
        var capturedSink: MetricsSink?
        let stream = AsyncStream<FrameDeliveryStats>(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            let sink = MetricsSink(
                continuation: continuation,
                cppPool: self.cppPool,
                swiftDropCount: { [weak self] lane in
                    self?.dropCount(for: lane) ?? 0
                })
            capturedSink = sink
            self.cppPool.setMetricsHandler { [weak sink] lane, overwriteCount in
                sink?.onMetric(stream: lane, overwriteCount: overwriteCount)
            }
            continuation.onTermination = { [self] _ in
                self.cppPool.clearMetricsHandler()
                Task { await self.clearMetricsSink() }
            }
        }
        metricsSink = capturedSink
        cachedMetricsStream = stream
        return stream
    }

    private func clearMetricsSink() {
        metricsSink = nil
        cachedMetricsStream = nil
    }

    // MARK: - Unregister

    /// Finishes the subscriber's continuation (Swift lane) or removes the C++ pool entry.
    ///
    /// Same recursive-lock concern as `release()`: extract the continuation
    /// under lock, finish it once the lock is released.
    public func unregister(token: ConsumerToken) {
        let foundContinuation: AsyncStream<FrameSet>.Continuation? = state.withLock {
            inner in
            guard var lane = inner.subscribers[token.stream] else { return nil }
            guard let idx = lane.firstIndex(where: { $0.id == token.id }) else {
                return nil
            }
            let c = lane[idx].continuation
            lane.remove(at: idx)
            inner.subscribers[token.stream] = lane
            return c
        }
        let lane = foundContinuation != nil ? "swift" : "cpp"
        if let c = foundContinuation {
            c.finish()
        } else {
            cppPool.unregister(token: token.id)
        }
        CameraKitLog.notice(
            .consumers,
            "unregister: token=\(token.id) stream=\(token.stream.rawPoolId) lane=\(lane)"
        )
    }

    // MARK: - Publication path (nonisolated — delivery queue, ADR-02)

    /// Dual-dispatch: Swift AsyncStream subscribers + C++ pool consumers.
    ///
    /// Runs inline on delivery queue; no actor hop.
    nonisolated func yield(_ frameSet: FrameSet, stream: StreamId) {
        // 1. Swift AsyncStream subscribers.
        state.withLock { inner in
            guard let lane = inner.subscribers[stream], !lane.isEmpty else { return }
            inner.subscribers[stream] = lane.filter { sub in
                let r = sub.continuation.yield(frameSet)
                switch r {
                case .enqueued:
                    return true
                case .dropped:
                    inner.dropCounts[stream, default: 0] &+= 1
                    return true
                case .terminated:
                    // Consumer task cancelled — remove eagerly; onTermination fires too but is idempotent.
                    return false
                @unknown default:
                    return true
                }
            }
        }

        // 2. C++ pool consumers — dispatch per-stream IOSurface pointer (D-03).
        // CVPixelBufferGetIOSurface returns Unmanaged<IOSurface>?; toOpaque() gives the IOSurfaceRef.
        let surface = streamBuffer(for: stream, frameSet: frameSet)
            .flatMap { CVPixelBufferGetIOSurface($0) }
            .map { $0.toOpaque() }
        // Convert CMTime to nanoseconds safely regardless of source timescale.
        let tsNs = CMTimeConvertScale(
            frameSet.captureTime, timescale: 1_000_000_000,
            method: .default)
        let presentationNs = tsNs.value
        cppPool.dispatch(
            stream: stream.rawPoolId,
            frameNumber: frameSet.frameNumber,
            presentationTimeNs: presentationNs,
            surface: surface ?? nil)
        // Throttle: log every 300 frames (~10 s at 30 fps) to avoid flooding.
        if frameSet.frameNumber % 300 == 0 {
            let hasSurface = surface != nil
            CameraKitLog.info(
                .consumers,
                "yield: frame=\(frameSet.frameNumber) stream=\(stream.rawPoolId) surface=\(hasSurface) cppConsumers=\(self.cppPool.consumerCount(stream: stream.rawPoolId))"
            )
        }
    }

    private nonisolated func streamBuffer(
        for stream: StreamId, frameSet: FrameSet
    ) -> CVPixelBuffer? {
        switch stream {
        case .natural: return frameSet.natural
        case .processed: return frameSet.processed
        case .tracker: return frameSet.tracker
        }
    }

    nonisolated func hasSubscriber(_ stream: StreamId) -> Bool {
        let swiftHas = state.withLock { $0.subscribers[stream]?.isEmpty == false }
        let cppHas = cppPool.consumerCount(stream: stream.rawPoolId) > 0
        return swiftHas || cppHas
    }

    // MARK: - Native pipeline pointer

    nonisolated func nativePipelinePointer() -> UInt64 { cppPool.rawPointer() }

    // MARK: - Teardown

    /// Finishes every subscriber's continuation.
    ///
    /// Called from `CameraEngine.close()`. `continuation.finish()` synchronously
    /// invokes the `onTermination` handler set in `subscribe(stream:)`, which
    /// re-acquires `state.withLock`. Calling `finish()` while holding the lock
    /// recursively acquires the underlying `os_unfair_lock` and aborts (Stage 11
    /// regression caught this on iPad iOS 26.4.1). Drain the continuations
    /// outside the lock to avoid the recursion.
    func release() {
        metricsSink?.finish()
        cppPool.clearMetricsHandler()
        metricsSink = nil
        cachedMetricsStream = nil
        let toFinish: [AsyncStream<FrameSet>.Continuation] = state.withLock { inner in
            let conts = inner.subscribers.values.flatMap { $0.map(\.continuation) }
            inner.subscribers.removeAll()
            return conts
        }
        for c in toFinish { c.finish() }
    }

    // MARK: - Metrics

    /// Production per-lane drop counter, aggregated by `metricsStream()`.
    ///
    /// Also read directly from tests via `@testable import` — a clean call into
    /// production, not a test seam.
    nonisolated func dropCount(for stream: StreamId) -> UInt64 {
        state.withLock { $0.dropCounts[stream] ?? 0 }
    }
}

// MARK: - Test seams (internal — accessed via @testable import)
#if DEBUG
extension ConsumerRegistry {
    /// Test seam: synthetically bump the Swift-side per-lane drop counter so
    /// `metricsStream()` aggregation can be exercised without driving real
    /// mailbox overflow (D-11).
    nonisolated func _incrementSwiftDropForTest(stream: StreamId, by count: UInt64 = 1) {
        state.withLock { $0.dropCounts[stream, default: 0] &+= count }
    }

    /// Per-lane subscriber count — readable from tests via @testable import.
    nonisolated func subscriberCount(for stream: StreamId) -> Int {
        state.withLock { $0.subscribers[stream]?.count ?? 0 }
    }

    /// C++ pool consumer count for `stream` — test seam.
    nonisolated func cppConsumerCount(for stream: StreamId) -> UInt32 {
        cppPool.consumerCount(stream: stream.rawPoolId)
    }
}
#endif

// MARK: - StreamId C++ pool lane index

extension StreamId {
    /// Maps the `StreamId` String-raw enum to a compact UInt32 lane index
    /// for the C++ `PixelSinkPool` (D-03).
    var rawPoolId: UInt32 {
        switch self {
        case .natural: return 0
        case .processed: return 1
        case .tracker: return 2
        }
    }
}

// MARK: - MetricsSink (D-11 aggregation)

/// Drives `ConsumerRegistry.metricsStream()`.
///
/// The C++ pool invokes `onMetric` once per lane per FPS window; this merges
/// the Swift-side per-lane drop counters with the C++ pool's per-lane
/// `mailbox_overwrite_count` and emits a single `FrameDeliveryStats` carrying
/// per-lane *deltas* (D-11) when the last lane (`.tracker`) reports.
private final class MetricsSink: @unchecked Sendable {
    private let continuation: AsyncStream<FrameDeliveryStats>.Continuation
    private let cppPool: CppPixelSinkPool
    private let swiftDropCount: @Sendable (StreamId) -> UInt64
    private let prev = Mutex<(cpp: [StreamId: UInt64], swift: [StreamId: UInt64])>(
        (cpp: [:], swift: [:]))
    private let lastLogged = Mutex<ContinuousClock.Instant?>(nil)

    init(
        continuation: AsyncStream<FrameDeliveryStats>.Continuation,
        cppPool: CppPixelSinkPool,
        swiftDropCount: @escaping @Sendable (StreamId) -> UInt64
    ) {
        self.continuation = continuation
        self.cppPool = cppPool
        self.swiftDropCount = swiftDropCount
    }

    /// Invoked per-lane by the C++ metrics callback.
    ///
    /// The pool emits every lane each window in id order, so `.tracker` (id 2,
    /// the last lane) is the once-per-window trigger for the merged snapshot.
    func onMetric(stream: UInt32, overwriteCount: UInt64) {
        guard stream == StreamId.tracker.rawPoolId else { return }
        let stats: FrameDeliveryStats = prev.withLock { p in
            var cppDelta: [StreamId: UInt64] = [:]
            var swiftDelta: [StreamId: UInt64] = [:]
            for lane in StreamId.allCases {
                let curCpp = cppPool.overwriteCount(stream: lane.rawPoolId)
                let curSwift = swiftDropCount(lane)
                cppDelta[lane] = curCpp &- (p.cpp[lane] ?? 0)
                swiftDelta[lane] = curSwift &- (p.swift[lane] ?? 0)
                p.cpp[lane] = curCpp
                p.swift[lane] = curSwift
            }
            return FrameDeliveryStats(
                producedByLane: [:],
                deliveredByLane: [:],
                droppedByLane: swiftDelta,
                holdOverBudgetByLane: [:],
                poolExhaustion: 0,
                cppOverwriteByLane: cppDelta)
        }
        // The panel emit (`continuation.yield`) runs every FPS window; the log
        // line is throttled to ~3 s wall-clock so `camerakit.log` stays readable.
        let now = ContinuousClock.now
        let shouldLog = lastLogged.withLock { last -> Bool in
            if let last, now - last < .seconds(3) { return false }
            last = now
            return true
        }
        if shouldLog {
            let perLane = StreamId.allCases.map { lane in
                "\(lane)=\(stats.cppOverwriteByLane[lane] ?? 0)/\(stats.droppedByLane[lane] ?? 0)"
            }.joined(separator: " ")
            CameraKitLog.notice(
                .consumers,
                "[metrics] window emit (cppOverwrite/swiftDrop): \(perLane)"
            )
        }
        continuation.yield(stats)
    }

    func finish() { continuation.finish() }
}
