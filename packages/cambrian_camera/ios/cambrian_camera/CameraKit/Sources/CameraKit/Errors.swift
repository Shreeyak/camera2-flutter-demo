import Foundation

// MARK: - Error routing contract
//
// CameraKit has two parallel error surfaces. Route by phase:
//
// 1. Synchronous rejections at the command boundary — caller precondition
//    violations, invalid arguments, .alreadyOpen / .notOpen, alreadyInFlight,
//    invalidOutputPath — surface as typed `EngineError` throws on the
//    suspension point. Caller code handles via `try` / `catch`.
//
// 2. Asynchronous hardware / session / encoding failures — capture device
//    errors, AVCaptureSession runtime errors, AVAssetWriter failures,
//    watchdog firings, max-retries-exceeded — surface as `CameraError` on
//    `errorStream()`. UI subscribes to the stream and routes by `isFatal`.
//
// `EngineError.fatal(CameraError)` bridges (1) → (2) when a synchronous
// path discovers an async-origin fatal condition that already exists as a
// `CameraError` value.
//
// Rationale: synchronous APIs cannot block on future hardware state; async
// failures cannot be observed by a caller that has already returned. The
// surfaces are not interchangeable. Each throw / emit site picks one
// according to its phase, not its severity.

/// Domain-public error-code taxonomy per domain-revised/10-api-contract.md §ErrorCode.
public enum ErrorCode: String, Sendable, Hashable {
    case cameraNotFound = "CAMERA_NOT_FOUND"
    case cameraInUse = "CAMERA_IN_USE"
    case permissionDenied = "PERMISSION_DENIED"
    case cameraAccessError = "CAMERA_ACCESS_ERROR"
    case cameraDisconnected = "CAMERA_DISCONNECTED"
    case configurationFailed = "CONFIGURATION_FAILED"
    case captureFailure = "CAPTURE_FAILURE"
    case recordingStartFailed = "RECORDING_START_FAILED"
    case recordingFailed = "RECORDING_FAILED"
    case recordingTruncated = "RECORDING_TRUNCATED"
    case frameStall = "FRAME_STALL"
    case maxRetriesExceeded = "MAX_RETRIES_EXCEEDED"
    case unknownError = "UNKNOWN_ERROR"
    case settingsConflict = "SETTINGS_CONFLICT"
    case invalidFormat = "INVALID_FORMAT"
    case fpsDegraded = "FPS_DEGRADED"
    case aeConvergenceTimeout = "AE_CONVERGENCE_TIMEOUT"
    case invalidState = "INVALID_STATE"
    case hardwareError = "HARDWARE_ERROR"
}

/// onError payload per domain-revised/10-api-contract.md §Error.
public struct CameraError: Sendable, Error, Hashable {
    public let code: ErrorCode
    public let message: String
    public let isFatal: Bool

    public init(code: ErrorCode, message: String, isFatal: Bool) {
        self.code = code
        self.message = message
        self.isFatal = isFatal
    }
}

/// Typed throws per ADR-25.
///
/// Wraps framework errors without losing root cause.
public enum EngineError: Error, Sendable {
    case alreadyOpen
    case notOpen
    case cameraDenied
    case noBackCamera
    case noSupportedFormat(reason: String)
    case lockForConfigurationFailed
    case settingsConflict(reason: String)
    case sessionLifecycleTimeout
    case metal(MetalError)
    case interop(InteropError)
    case recording(RecordingError)
    case capture(StillCaptureError)
    case fatal(CameraError)
    /// Caller passed an `outputURL` that resolves outside the app sandbox.
    ///
    /// iOS apps are kernel-sandboxed; only paths under `NSHomeDirectory()` are writable.
    ///
    /// See `OutputPathResolver` for the valid-locations list.
    case invalidOutputPath(URL)
    /// A `calibrate*()` call is in flight; conflicting mutating ops
    /// (`updateSettings(...)` touching white balance, `setResolution(...)`)
    /// must not race with it. Phase-2 design §2b concurrency contract.
    case calibrationInProgress
}

public enum MetalError: Error, Sendable, Equatable {
    case commandBufferFailed(code: Int)
    case textureCacheCreateFailed(code: Int32)
    case textureWrapFailed(code: Int32)
    case textureAllocationFailed
    case pipelineStateCompilation(String)
    case unsupportedFormat
    /// Calibration / sampling path required the latest natural texture but the
    /// mailbox is still empty (no frame delivered yet, or post-pause/close).
    case noFrameAvailable
}

public enum InteropError: Error, Sendable {
    case pixelSinkRegistrationRejected(code: Int32)
    case pipelineHandleUnavailable
    /// on_frame was nil on registerCallback (D-03 quality gate).
    case invalidCallbacks
    /// on_overwrite was nil on registerCallback — the G-26-avoidance quality
    /// gate (D-11): a sink that cannot surface mailbox-overwrite drops is
    /// rejected at registration, never silently degraded at runtime.
    case missingOnOverwrite
    /// Unmanaged retain/release mismatch detected on unregister.
    case retainMismatch
}

public enum RecordingError: Error, Sendable {
    case writerStartFailed(status: Int)
    case appendFailed(status: Int)
    case finishTimeout
    case diskFull
    case notReadyForMoreMediaData
    case finalizeTimeout
    case finalizeFailed(reason: String)
    case cancelledByPause
    /// The output filename carried no extension; the format cannot be inferred.
    ///
    /// Only `.mp4` is supported — pass a name ending in `.mp4`, or pass no name
    /// at all to get a timestamped default. Associated value is the offending
    /// filename.
    case missingFileExtension(String)
    /// The output filename extension is not a supported video format.
    ///
    /// Only `.mp4` is supported. Associated value is the offending extension.
    case unsupportedVideoFormat(String)
}

// MARK: - Still capture types (compressed here per Stage 01 type-compression decision)

/// Output of a successful captureImage() call.
///
/// Full implementation Stage 06.
public struct StillCaptureOutput: Sendable, Hashable {
    public let filePath: String
    public init(filePath: String) { self.filePath = filePath }
}

/// Errors specific to still capture.
///
/// Full implementation Stage 06.
public enum StillCaptureError: Error, Sendable {
    case alreadyInFlight
    case metalReadbackFailed
    case fileWriteFailed(String)
    /// `captureNaturalPicture` was called before any natural-lane frame
    /// reached the pipeline's mailbox.
    ///
    /// Engine is open but `MetalPipeline.latestNaturalBuffer` is `nil` —
    /// caller raced the first sample-buffer-delegate fire. Try again after
    /// the first frame arrives. Distinct from `metalReadbackFailed`, which
    /// covers GPU-readback failures on the processed lane (vImage, CGImage
    /// build, IOSurface lock).
    case bufferUnavailable
    /// The output filename carried no extension; the image format cannot be
    /// inferred.
    ///
    /// Supply one of: `.png`, `.jpg`/`.jpeg`, `.tif`/`.tiff` — or pass no name
    /// at all to get a timestamped `.png` default. Associated value is the
    /// offending filename.
    case missingFileExtension(String)
    /// The output filename extension is not a supported still-image format.
    ///
    /// Supported: `.png`, `.jpg`/`.jpeg`, `.tif`/`.tiff`. Associated value is
    /// the offending extension.
    case unsupportedImageFormat(String)
}
