import CameraKitCxx
// CameraKitInterop — thin Swift module isolating C++ interop per ADR-13.
// .interoperabilityMode(.Cxx) is confined to this target only.
import Foundation
import OSLog

private let log = Logger(subsystem: "com.cambrian.camerakit", category: "interop")

// MARK: - CppPixelSinkPool

/// Holds the Swift-side metrics handler behind an opaque pointer so the C-ABI
/// `MetricsCallbackFn` thunk can recover it.
///
/// Retained by `CppPixelSinkPool` while a handler is installed; released on
/// replacement / clear / deinit.
private final class MetricsHandlerBox {
    let handler: @Sendable (_ stream: UInt32, _ overwriteCount: UInt64) -> Void
    init(handler: @escaping @Sendable (UInt32, UInt64) -> Void) {
        self.handler = handler
    }
}

/// Wraps the C++ `PixelSinkPool` with a Swift-friendly reference type.
public final class CppPixelSinkPool: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    private let metricsLock = NSLock()
    private var metricsCtx: UnsafeMutableRawPointer?

    public init() {
        handle = pixel_sink_pool_create()!
        let ptr = pixel_sink_pool_raw_pointer(handle)
        log.info("CppPixelSinkPool: created — handle 0x\(String(ptr, radix: 16))")
    }

    deinit {
        log.info("CppPixelSinkPool: destroying")
        clearMetricsHandler()
        pixel_sink_pool_destroy(handle)
    }

    public func register(stream: UInt32, callbacks: CppPixelSinkCallbacks) -> UInt64 {
        pixel_sink_pool_register(handle, stream, callbacks.raw)
    }

    public func unregister(token: UInt64) {
        pixel_sink_pool_unregister(handle, token)
    }

    public func dispatch(
        stream: UInt32, frameNumber: UInt64,
        presentationTimeNs: Int64,
        surface: UnsafeMutableRawPointer?
    ) {
        pixel_sink_pool_dispatch(handle, stream, frameNumber, presentationTimeNs, surface)
    }

    public func consumerCount(stream: UInt32) -> UInt32 {
        pixel_sink_pool_consumer_count(handle, stream)
    }

    public func rawPointer() -> UInt64 {
        UInt64(pixel_sink_pool_raw_pointer(handle))
    }

    // MARK: - D-11 observability

    /// Records a mailbox-overwrite event for `stream` (production + test seam).
    public func noteOverwrite(stream: UInt32) {
        pixel_sink_pool_note_overwrite(handle, stream)
    }

    /// Cumulative mailbox-overwrite count for `stream`.
    public func overwriteCount(stream: UInt32) -> UInt64 {
        pixel_sink_pool_overwrite_count(handle, stream)
    }

    /// Installs the per-window metrics handler.
    ///
    /// The C-ABI `PixelSinkMetrics` struct is unpacked here so it never escapes
    /// the interop boundary (ADR-13). Replacing or clearing the handler
    /// releases the prior box.
    public func setMetricsHandler(
        _ handler: @escaping @Sendable (_ stream: UInt32, _ overwriteCount: UInt64) -> Void
    ) {
        let box = MetricsHandlerBox(handler: handler)
        let raw = Unmanaged.passRetained(box).toOpaque()
        metricsLock.lock()
        let prior = metricsCtx
        metricsCtx = raw
        metricsLock.unlock()
        pixel_sink_pool_set_metrics_callback(
            handle,
            { ctx, metrics in
                guard let ctx else { return }
                let box = Unmanaged<MetricsHandlerBox>.fromOpaque(ctx).takeUnretainedValue()
                box.handler(metrics.stream, metrics.mailbox_overwrite_count)
            },
            raw)
        if let prior { Unmanaged<MetricsHandlerBox>.fromOpaque(prior).release() }
    }

    /// Clears any installed metrics handler and releases its box.
    public func clearMetricsHandler() {
        pixel_sink_pool_set_metrics_callback(handle, nil, nil)
        metricsLock.lock()
        let prior = metricsCtx
        metricsCtx = nil
        metricsLock.unlock()
        if let prior { Unmanaged<MetricsHandlerBox>.fromOpaque(prior).release() }
    }

    /// Forces an immediate metrics emission for every lane (test seam).
    public func emitMetrics() {
        pixel_sink_pool_emit_metrics(handle)
    }
}

// MARK: - CppPixelSinkCallbacks

/// Lightweight bridge type carrying the C-ABI callback struct.
public struct CppPixelSinkCallbacks: @unchecked Sendable {
    let raw: PixelSinkCallbacks

    public init(
        onFrame:
            @escaping @convention(c) (
                UnsafeMutableRawPointer?, UInt32, UInt64, Int64,
                UnsafeMutableRawPointer?
            ) -> Void,
        onOverwrite:
            @escaping @convention(c) (
                UnsafeMutableRawPointer?, UInt32
            ) -> Void,
        onError:
            @escaping @convention(c) (
                UnsafeMutableRawPointer?, Int32
            ) -> Void,
        context: UnsafeMutableRawPointer?
    ) {
        raw = PixelSinkCallbacks(
            on_frame: onFrame,
            on_overwrite: onOverwrite,
            on_error: onError,
            context: context)
    }
}

// MARK: - CppCaptureAtomic

/// Wraps the C++ `std::atomic<bool>` capture-in-flight guard (Invariant 7).
public final class CppCaptureAtomic: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer

    public init() { handle = capture_atomic_create()! }

    deinit { capture_atomic_destroy(handle) }

    /// CAS false → true.
    ///
    /// Returns true if acquired (was false, now true).
    public func tryAcquire() -> Bool { capture_atomic_try_acquire(handle) }

    /// Store false unconditionally.
    public func release() { capture_atomic_release(handle) }
}
