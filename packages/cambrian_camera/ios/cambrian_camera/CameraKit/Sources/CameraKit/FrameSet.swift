import CoreMedia
import CoreVideo
import Foundation

// CVPixelBuffer (CVImageBuffer) is a Core Foundation ref-counted object backed by IOSurface.
// Its retain/release operations are thread-safe. @unchecked Sendable per G-13: CPU access
// is strictly gated by CVPixelBufferLockBaseAddress (ADR-06) at all call sites.
extension CVPixelBuffer: @retroactive @unchecked Sendable {}

/// Atomic unit of publication per ADR-18.
///
/// Stage 06: constructed in `MetalPipeline.addCompletedHandler` from three
/// IOSurface-backed `CVPixelBuffer`s (natural/processed/tracker), the
/// `CMSampleBuffer` capture metadata, and the per-frame `ProcessingMetadata`
/// snapshot from the `Mutex<UniformStorage>` read in `encode()`. Published to
/// subscribed lanes via `ConsumerRegistry.yield(_:stream:)`.
///
/// `@unchecked Sendable` per G-13: `CVPixelBuffer` is not yet `Sendable` on
/// iOS 26; IOSurface backing plus the GPU-completion-before-construction
/// ordering in the completion handler make cross-thread use safe.
///
/// # Lifetime contract
///
/// Consumers must not retain a `FrameSet` (or its `natural` / `processed` /
/// `tracker` `CVPixelBuffer`s) across an `await` or beyond the next stream
/// yield. The buffers are pool-backed (POOL_CAP_RULE); retention exhausts
/// the pool, starves frame delivery, and surfaces three hops away as
/// `frameStall` / watchdog recovery — root cause invisible from the symptom.
///
/// Snapshot any fields you need (`frameNumber`, `captureTime`, `capture`,
/// `processing`, `blurScore`, `trackerQuality`) into your own storage before
/// yielding control. If you need the pixel data itself, copy it under
/// `CVPixelBufferLockBaseAddress` (ADR-06) into your own backing store.
public struct FrameSet: @unchecked Sendable, Hashable {
    public let frameNumber: UInt64
    public let captureTime: CMTime
    public let natural: CVPixelBuffer
    public let processed: CVPixelBuffer
    public let tracker: CVPixelBuffer
    public let capture: CaptureMetadata
    public let processing: ProcessingMetadata
    public let blurScore: Float
    public let trackerQuality: TrackerQuality

    public init(
        frameNumber: UInt64, captureTime: CMTime,
        natural: CVPixelBuffer, processed: CVPixelBuffer, tracker: CVPixelBuffer,
        capture: CaptureMetadata, processing: ProcessingMetadata,
        blurScore: Float, trackerQuality: TrackerQuality
    ) {
        self.frameNumber = frameNumber
        self.captureTime = captureTime
        self.natural = natural
        self.processed = processed
        self.tracker = tracker
        self.capture = capture
        self.processing = processing
        self.blurScore = blurScore
        self.trackerQuality = trackerQuality
    }

    public static func == (lhs: FrameSet, rhs: FrameSet) -> Bool {
        lhs.frameNumber == rhs.frameNumber && lhs.captureTime == rhs.captureTime
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(frameNumber)
        hasher.combine(captureTime.value)
    }
}

public enum TrackerQuality: String, Sendable, Hashable {
    case good
    case degraded
    case invalid
}

public struct CaptureMetadata: Sendable, Hashable {
    public let iso: Float
    public let exposureDurationNs: Int64
    public let whiteBalanceGains: WhiteBalanceGains
    public let whiteBalanceModeActive: WhiteBalanceMode
    public let lensPosition: Float
    public let focusModeActive: CameraMode
    public let exposureModeActive: CameraMode
    public let zoomFactor: Double
    public let cameraPosition: CameraPosition

    public init(
        iso: Float, exposureDurationNs: Int64, whiteBalanceGains: WhiteBalanceGains,
        whiteBalanceModeActive: WhiteBalanceMode, lensPosition: Float,
        focusModeActive: CameraMode, exposureModeActive: CameraMode,
        zoomFactor: Double, cameraPosition: CameraPosition
    ) {
        self.iso = iso
        self.exposureDurationNs = exposureDurationNs
        self.whiteBalanceGains = whiteBalanceGains
        self.whiteBalanceModeActive = whiteBalanceModeActive
        self.lensPosition = lensPosition
        self.focusModeActive = focusModeActive
        self.exposureModeActive = exposureModeActive
        self.zoomFactor = zoomFactor
        self.cameraPosition = cameraPosition
    }
}

// ProcessingMetadata extracted to ProcessingMetadata.swift in Stage 05 (brief §4).

// MARK: - CaptureMetadata convenience

extension CaptureMetadata {
    /// Stage 06 placeholder: zero-valued sensor metadata.
    ///
    /// Full attachment-derived implementation lands with sensor-metadata
    /// plumbing in a later stage.
    static func placeholder() -> CaptureMetadata {
        CaptureMetadata(
            iso: 0,
            exposureDurationNs: 0,
            whiteBalanceGains: WhiteBalanceGains(red: 1, green: 1, blue: 1),
            whiteBalanceModeActive: .auto,
            lensPosition: 0,
            focusModeActive: .auto,
            exposureModeActive: .auto,
            zoomFactor: 1.0,
            cameraPosition: .back
        )
    }
}

public struct WhiteBalanceGains: Sendable, Hashable {
    public let red: Float
    public let green: Float
    public let blue: Float
    public init(red: Float, green: Float, blue: Float) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum CameraPosition: String, Sendable, Hashable {
    case back
    case front
    case wide
}

public struct FrameDeliveryStats: Sendable, Hashable {
    public let producedByLane: [StreamId: UInt64]
    public let deliveredByLane: [StreamId: UInt64]
    public let droppedByLane: [StreamId: UInt64]
    public let holdOverBudgetByLane: [StreamId: UInt64]
    public let poolExhaustion: UInt64
    public let cppOverwriteByLane: [StreamId: UInt64]

    public init(
        producedByLane: [StreamId: UInt64], deliveredByLane: [StreamId: UInt64],
        droppedByLane: [StreamId: UInt64], holdOverBudgetByLane: [StreamId: UInt64],
        poolExhaustion: UInt64, cppOverwriteByLane: [StreamId: UInt64]
    ) {
        self.producedByLane = producedByLane
        self.deliveredByLane = deliveredByLane
        self.droppedByLane = droppedByLane
        self.holdOverBudgetByLane = holdOverBudgetByLane
        self.poolExhaustion = poolExhaustion
        self.cppOverwriteByLane = cppOverwriteByLane
    }
}

// MARK: - Sensor read types (compressed here per Stage 01 type-compression decision)

/// Sensor metadata delivered at constants.md#FRAME_RESULT_HEARTBEAT_HZ.
///
/// Full implementation Stage 04.
public struct FrameResult: Sendable, Hashable {
    public var iso: Int?
    public var exposureTimeNs: Int64?
    public var focusDistance: Double?
    public var wbGainR: Double?
    public var wbGainG: Double?
    public var wbGainB: Double?

    public init(
        iso: Int? = nil, exposureTimeNs: Int64? = nil, focusDistance: Double? = nil,
        wbGainR: Double? = nil, wbGainG: Double? = nil, wbGainB: Double? = nil
    ) {
        self.iso = iso
        self.exposureTimeNs = exposureTimeNs
        self.focusDistance = focusDistance
        self.wbGainR = wbGainR
        self.wbGainG = wbGainG
        self.wbGainB = wbGainB
    }
}

/// Per-channel trimmed-mean sample from sampleCenterPatch().
///
/// Full implementation Stage 04.
public struct RgbSample: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }
}
