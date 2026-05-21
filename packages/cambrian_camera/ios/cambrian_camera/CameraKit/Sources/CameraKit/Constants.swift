import CoreVideo
import Metal

enum Constants {
    static let frameRateTargetFPS: Int = 30
    static let capturePixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    static let workingPixelFormat: MTLPixelFormat = .rgba16Float
    static let captureDefaultWidthPx: Int = 4160
    static let captureDefaultHeightPx: Int = 3120
    static let captureFallbackWidthPx: Int = 1280
    static let captureFallbackHeightPx: Int = 960
    static let cropDefaultWidthPx: Int = 1600
    static let cropDefaultHeightPx: Int = 1200
    static let captureOrientationAngleDeg: CGFloat = 0
    static let stateStreamBufferSize: Int = 64
    /// ADR-30: Deadline for startRunning() / stopRunning() awaited from @MainActor.
    static let sessionLifecycleTimeoutSeconds: Double = 2.0
    // Frame-result heartbeat (07-settings.md §Frame-result heartbeat).
    static let frameResultHeartbeatHz: Int = 3
    static let frameResultHeartbeatIntervalFrames: Int = 10  // 30 fps ÷ 3 Hz
    // Session-only teardown budget for setResolution (03-camera-session.md).
    static let resolutionResizeTimeoutSeconds: Double = 5.0
    // Stage 04 — color pipeline + sample-center-patch (architecture/constants.md).
    /// Square center-patch size in pixels for `sampleCenterPatch()` (constants.md line 35).
    static let centerPatchSizePx: Int = 96
    /// Per-side trim ratio for the patch sampler's trimmed mean.
    ///
    /// 0.075 ≡ 7.5 % bottom + 7.5 % top discarded per channel. Chosen to reject
    /// hot pixels and specular highlights without sacrificing too much sample
    /// area on a 96² patch (~691 of 9216 px per side at 7.5 %).
    static let centerPatchTrimRatio: Double = 0.075
    /// Multiplier applied to BB pedestal sample so the per-pixel noise above
    /// the trimmed mean is also driven to the clamp floor on iPad HITL.
    static let blackBalanceOverscan: Double = 1.5
    /// Per-step log2-space cap retained on `CalibrationCompute.grayWorldGains`
    /// for unit-test stability. `calibrateWB` itself no longer iterates —
    /// the helper is kept as a pure utility but isn't in the live path.
    static let wbGrayWorldLogCap: Float = 0.25
    /// Per-frame wall-clock budget at 30fps (constants.md line 15).
    static let frameLatencyBudgetMs: Int = 33

    // MARK: - Stage 06 — Pool trio + tracker stream

    /// Tracker texture height in pixels; width is aspect-preserved and
    /// even-pixel-rounded in `MetalPipeline` (domain 02-frame-delivery §Parallel
    /// Stream Outputs, U-15 resolved; constants.md#TRACKER_HEIGHT_PX).
    static let trackerHeightPx: Int = 480

    /// `kCVPixelBufferPoolMinimumBufferCountKey` — 1 current mailbox ref +
    /// 1 GPU write slot + 1 slack (constants.md#POOL_MIN_BUFFER_COUNT, ADR-19).
    static let poolMinBufferCount: Int = 3

    /// `kCVPixelBufferPoolMaximumBufferAgeKey` — CF ages out unused buffers
    /// after this many seconds of disuse (constants.md#POOL_MAX_BUFFER_AGE_SECONDS,
    /// ADR-19).
    static let poolMaxBufferAgeSeconds: Double = 1.0

    // MARK: - Stage 08 — C++ pool

    /// Thread-count cap for the C++ PixelSinkPool worker queue.
    static let cppPoolThreadCount: Int = min(4, ProcessInfo.processInfo.processorCount)

    // MARK: - Stage 09 — Health monitoring

    // Stage 09: stall watchdogs.
    /// GPU watchdog threshold — notify-only. constants.md#STALL_GPU_THRESHOLD_MS.
    static let stallGpuThresholdMs: Int = 3000
    /// Capture-result watchdog threshold — triggers recovery. constants.md#STALL_CAPTURE_THRESHOLD_MS.
    static let stallCaptureThresholdMs: Int = 5000

    // Stage 09: AE convergence.
    /// AE convergence timeout — non-fatal notification. constants.md#AE_CONVERGENCE_TIMEOUT_MS.
    static let aeConvergenceTimeoutMs: Int = 5000

    // Stage 09: FPS degradation.
    /// Fraction of expected fps below which a window is counted as degraded.
    ///
    /// Expected fps accounts for manual exposure: min(1e9/exposureNs, targetFps).
    /// Replaces the upstream fixed floor (FPS_DEGRADED_THRESHOLD_FPS=15) — see DECISIONS.md.
    static let fpsDegradedFraction: Double = 0.8
    /// Consecutive below-threshold windows required before emitting. constants.md#FPS_DEGRADED_STREAK_COUNT.
    static let fpsDegradedStreakCount: Int = 3
    /// One FPS measurement per window of this many frames. constants.md#FPS_MEASUREMENT_WINDOW_FRAMES.
    static let fpsMeasurementWindowFrames: Int = 30

    // Stage 09: recovery.
    /// Consecutive HW failures before entering recovery. constants.md#HW_ERROR_THRESHOLD_CONSECUTIVE.
    static let hwErrorThresholdConsecutive: Int = 5
    /// Max retries before fatal MAX_RETRIES_EXCEEDED. constants.md#RECOVERY_MAX_RETRIES.
    static let recoveryMaxRetries: Int = 5
    /// Exponential backoff schedule (attempts 1..5+). constants.md#RECOVERY_BACKOFF_*_MS.
    static let recoveryBackoff1Ms: Int = 500
    static let recoveryBackoff2Ms: Int = 1000
    static let recoveryBackoff3Ms: Int = 2000
    static let recoveryBackoff4Ms: Int = 4000
    static let recoveryBackoff5PlusMs: Int = 8000

    /// Backoff lookup: attempts are 1-indexed; values beyond 5 clamp to `recoveryBackoff5PlusMs`.
    static func recoveryBackoffMs(attempt: Int) -> Int {
        switch attempt {
        case ..<1: return recoveryBackoff1Ms
        case 1: return recoveryBackoff1Ms
        case 2: return recoveryBackoff2Ms
        case 3: return recoveryBackoff3Ms
        case 4: return recoveryBackoff4Ms
        default: return recoveryBackoff5PlusMs
        }
    }

    // MARK: - Stage 10 — Recording mode

    /// AE lower frame-rate bound while recording — allows AE to halve in low light.
    /// constants.md#FRAME_RATE_RECORDING_MIN_FPS.
    static let frameRateRecordingMinFps: Int = 15
    /// Default video bitrate. TARGET_BITRATE_MBPS is marked "measurements/" upstream;
    /// 40 Mbps is reasonable for 4K HEVC @ 30fps. See state.md open questions.
    static let recordingTargetBitrateBpsDefault: Int = 40_000_000
    /// Deadline for AVAssetWriter.finishWriting.
    ///
    /// Past this, cancel to avoid corrupt MP4
    /// (ADR-16, G-08). constants.md#RECORDING_FINISH_TIMEOUT_SECONDS.
    static let recordingFinishTimeoutSeconds: Double = 5.0
    /// Recording EOS drain budget. constants.md#DRAIN_TIMEOUT_SECONDS.
    static let drainTimeoutSeconds: Double = 5.0
    /// Native VideoToolbox encoder input pixel format (NV12 video-range).
    /// constants.md#ENCODER_PIXEL_FORMAT.
    static let encoderPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

    // MARK: - RGBA8 lane conversion (unconditional)

    /// Wire pixel format emitted on `currentPixelBuffer(stream:)`.
    ///
    /// BGRA8 is Apple's `CVMetalTextureCache`-canonical 32-bit RGBA-family
    /// format on iOS — wraps zero-copy as `.bgra8Unorm`. Android adapts at
    /// its end (D-2P-09). See
    /// `docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md`.
    static let eightBitLanePixelFormat: OSType = kCVPixelFormatType_32BGRA

    /// `MTLPixelFormat` paired with `eightBitLanePixelFormat` for
    /// `CVMetalTextureCache` wraps and Pass-7 kernel output.
    static let eightBitLaneMetalFormat: MTLPixelFormat = .bgra8Unorm

    /// String reported on `SessionCapabilities.streamPixelFormat`.
    ///
    /// Conversion to BGRA8 is unconditional — natural and processed lane buffers
    /// always deliver `kCVPixelFormatType_32BGRA` to `currentPixelBuffer(stream:)`.
    static let streamPixelFormatString: String = "BGRA8"
}
