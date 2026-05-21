import AVFoundation
import CoreMedia

/// Receives raw sample buffers from `AVCaptureVideoDataOutput` on the `delivery`
/// DispatchQueue (ADR-02).
///
/// - This class is intentionally NOT an actor. All work happens on the `delivery`
///   queue; no hops to any actor boundary, MainActor, or other DispatchQueue are
///   permitted in this file (ADR-02 / ADR-07).
/// - `@unchecked Sendable`: the instance is captured in `@Sendable` closures on
///   `delivery`. `onSampleBuffer` is set by `CameraEngine` on `sessionQueue` before
///   `startRunning()` — no concurrent mutation occurs during streaming.
/// - GPU submission gate (ADR-09, D-06) is enforced inside `MetalPipeline.encode()`
///   after CPU-side work and immediately before `commandBuffer.commit()`. The
///   `captureOutput(_:didOutput:from:)` path passes through that gate check.
final class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    // MARK: - Properties

    /// Called on the `delivery` queue for every successfully delivered frame.
    ///
    /// Set by `CameraEngine` on `sessionQueue` before the session starts running.
    /// This is the Metal pipeline's entry point.
    var onSampleBuffer: (@Sendable (CMSampleBuffer) -> Void)?

    /// Weak reference to the engine for frame-result heartbeat (Stage 03).
    weak var engine: CameraEngine?

    /// Watchdog pair for GPU and capture liveliness (Stage 09).
    ///
    /// Set by `CameraEngine` in `open()` before `startRunning()`.
    var watchdogs: WatchdogPair?

    /// Resume-cadence probe: number of upcoming delivered frames still to log.
    ///
    /// Armed by the engine (`reconcile(.active)`, interruption-ended, resolution
    /// change) to a small budget; each delivered frame logs its arrival
    /// (dims/format + the log's own timestamp) and decrements. The sequence of
    /// timestamps reveals whether AVF delivery is continuous after a resume or
    /// stalls after the first frame. nonisolated(unsafe): set on the actor,
    /// read/decremented on the delivery queue — a benign diagnostic race.
    nonisolated(unsafe) var framesToLog: Int = 0

    // MARK: - Init

    override init() {
        super.init()
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    /// Invoked on the `delivery` queue for each frame that AVFoundation delivers.
    ///
    /// Forwards the buffer directly to `onSampleBuffer`; no actor hops (ADR-02).
    /// Refreshes GPU and capture watchdogs on every arrival (Stage 09, ADR-31).
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if framesToLog > 0 {
            framesToLog -= 1
            // PTS = capture timestamp. Advancing ~33 ms/frame through a resume ⇒
            // AVF delivers FRESH content (so a frozen preview is downstream =
            // compositor). Frozen/stale PTS ⇒ AVF is handing back stale frames.
            let ptsS = String(
                format: "%.3f",
                CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
            if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let w = CVPixelBufferGetWidth(pb)
                let h = CVPixelBufferGetHeight(pb)
                let pf = CVPixelBufferGetPixelFormatType(pb)
                let four =
                    String(
                        bytes: [
                            UInt8((pf >> 24) & 0xFF),
                            UInt8((pf >> 16) & 0xFF),
                            UInt8((pf >> 8) & 0xFF),
                            UInt8(pf & 0xFF),
                        ],
                        encoding: .ascii) ?? "????"
                CameraKitLog.notice(
                    .engine,
                    "[resume] delivery frame (t1) pts=\(ptsS)s actual=\(w)x\(h) pf='\(four)'")
            } else {
                CameraKitLog.notice(
                    .engine, "[resume] delivery frame (t1) pts=\(ptsS)s (no image buffer)")
            }
        }
        watchdogs?.gpu.refresh()
        watchdogs?.capture.refresh()
        onSampleBuffer?(sampleBuffer)
        engine?.tickFrame()
        let engRef = engine
        Task { await engRef?.noteFrameDelivered() }
    }

    /// Invoked on the `delivery` queue when a frame is dropped.
    ///
    /// AVFoundation buffer-pressure drops are not hardware failures — they self-correct
    /// through automatic backpressure. We do not increment failure counters for drops
    /// (Stage 09, ADR-31).
    func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // AVFoundation buffer-pressure drops are not HW failures — they self-correct.
    }
}
