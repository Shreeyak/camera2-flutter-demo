import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Owns the `AVCaptureSession` lifecycle: configure, start, stop.
///
/// All `AVCaptureSession` mutations and `AVCaptureDevice.lockForConfiguration()` calls
/// run on `sessionQueue` (ADR-07). `CameraEngine` dispatches onto that queue; this class
/// never dispatches internally.
///
/// `@unchecked Sendable` because the instance is captured in `@Sendable` closures that
/// run on `sessionQueue`. Callers must ensure all methods are invoked on `sessionQueue`.
final class CameraSession: @unchecked Sendable {

    // MARK: - Stored properties

    /// Serializes all AVCaptureSession mutations and lockForConfiguration() calls (ADR-07).
    let sessionQueue: DispatchQueue

    /// Set by configure(); nil until then.
    private(set) var device: (any CaptureDeviceProviding)?

    /// The AVCaptureSession instance.
    ///
    /// Created once per open() call, reused across
    /// pause/resume (G-07 / ADR-07 §Session object is created once per open()).
    let avSession: AVCaptureSession

    /// Retained output — created in init() and wired in configure().
    private let videoOutput: AVCaptureVideoDataOutput

    // MARK: - Session event routing

    enum SessionEvent: Sendable {
        case cameraInUseBegan
        case cameraInUseEnded
        case runtimeError(String)
        case otherInterruption(reasonRawValue: Int)
        /// Counterpart to `.otherInterruption` — fired by AVF's
        /// `interruptionEndedNotification` for any non-cameraInUse reason.
        /// Phase-2 §2d.5: lets the engine revert from `.interrupted` to
        /// `.streaming` without conflating with the cameraInUse self-heal path.
        case otherInterruptionEnded
    }

    // Set by CameraEngine at open(). Routes interruption/runtime-error events up.
    var onSessionEvent: (@Sendable (SessionEvent) -> Void)?

    // MARK: - Init

    init() {
        sessionQueue = DispatchQueue(
            label: "com.cambrian.camerakit.session",
            qos: .userInitiated)
        avSession = AVCaptureSession()
        videoOutput = AVCaptureVideoDataOutput()
    }

    // MARK: - configure()

    /// Finds the back wide-angle camera (D-08), selects the largest 4:3 format at 30 fps
    /// (G-17), wires the video data output, and sets landscape-right rotation (ADR-17).
    ///
    /// Must be called on `sessionQueue`.
    ///
    /// - Parameters:
    ///   - deliveryQueue: Queue passed to `setSampleBufferDelegate(_:queue:)`. Owned by
    ///     the caller (`CameraEngine`).
    ///   - sampleBufferDelegate: The `CaptureDelegate` that receives sample buffers.
    ///     Owned by the caller.
    /// - Returns: The live device wrapper and the chosen capture size.
    /// - Throws: `EngineError.noBackCamera` if the device is absent;
    ///   `EngineError.lockForConfigurationFailed` if the device lock fails;
    ///   `EngineError.noSupportedFormat` if landscape-right rotation is unsupported.
    func configure(
        deliveryQueue: DispatchQueue,
        sampleBufferDelegate: AVCaptureVideoDataOutputSampleBufferDelegate
    ) throws -> (device: any CaptureDeviceProviding, captureSize: Size) {

        // ── 1. Device discovery (D-08) ──────────────────────────────────────────────
        // Use the default API per architecture/03-camera-session.md §Device selection.
        guard
            let avDevice = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back
            )
        else {
            throw EngineError.noBackCamera
        }

        // ── 2. Format selection (G-17, partial override 2026-05-13) ────────────────
        // Filter: 8-bit biplanar YUV FullRange only. VideoRange is rejected per
        // user directive — see state.md Decision §63. Contradicts G-17 and
        // architecture/03-camera-session.md §Enumeration step 1.
        let yuvFormats: [AVCaptureDevice.Format] = avDevice.formats.filter { format in
            CMFormatDescriptionGetMediaSubType(format.formatDescription)
                == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }

        // Sort by pixel count descending (largest first).
        let sortedByPreference: [AVCaptureDevice.Format] = yuvFormats.sorted { lhs, rhs in
            let lDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let rDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(lDims.width) * Int(lDims.height) > Int(rDims.width) * Int(rDims.height)
        }

        // Select the largest 4:3 format that supports 30 fps.
        let fps30 = Int32(Constants.frameRateTargetFPS)
        let candidateFormats: [AVCaptureDevice.Format] =
            sortedByPreference
            .filter { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let w = Int32(dims.width)
                let h = Int32(dims.height)
                guard w * 3 == h * 4 else { return false }  // 4:3 ratio
                // Must support 30 fps within at least one frame-rate range.
                return format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate <= Double(fps30) && Double(fps30) <= range.maxFrameRate
                }
            }
            // Sort by pixel count descending so `.first` is the largest.
            .sorted { lhs, rhs in
                let lDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let rDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                return Int(lDims.width) * Int(lDims.height) > Int(rDims.width) * Int(rDims.height)
            }

        let (chosenFormat, chosenSize): (AVCaptureDevice.Format?, Size) = {
            if let best = candidateFormats.first {
                let dims = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
                return (best, Size(width: Int(dims.width), height: Int(dims.height)))
            }
            // Fallback: no 4:3 at 30fps found; use the fallback dimensions (G-17).
            // Pick the format nearest the fallback dimensions if one exists; otherwise nil.
            let fallbackW = Constants.captureFallbackWidthPx
            let fallbackH = Constants.captureFallbackHeightPx
            let nearest = sortedByPreference.min { lhs, rhs in
                let lDims = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let rDims = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                let lDist = abs(Int(lDims.width) - fallbackW) + abs(Int(lDims.height) - fallbackH)
                let rDist = abs(Int(rDims.width) - fallbackW) + abs(Int(rDims.height) - fallbackH)
                return lDist < rDist
            }
            return (nearest, Size(width: fallbackW, height: fallbackH))
        }()

        // ── 3. Lock for configuration and apply format + frame rate ────────────────
        // Explicit unlock (no defer) so the lock scope closes before we "send"
        // avDevice into LiveCaptureDevice's actor isolation below. A defer that
        // captures avDevice would remain live across the actor-init, which Swift 6
        // strict concurrency flags as a potential data race.
        do {
            try avDevice.lockForConfiguration()
        } catch {
            throw EngineError.lockForConfigurationFailed
        }

        if let format = chosenFormat {
            avDevice.activeFormat = format
        }
        let frameDuration = CMTimeMake(value: 1, timescale: Int32(Constants.frameRateTargetFPS))
        avDevice.activeVideoMinFrameDuration = frameDuration
        avDevice.activeVideoMaxFrameDuration = frameDuration

        // bug6: disable low-light boost. LLB multiplies analog gain in dim
        // scenes, which sacrifices spatial detail for SNR. Stills come out
        // softer when LLB engages mid-frame. Disabling makes detail
        // deterministic across exposure conditions; AE still handles low
        // light via shutter/ISO within format limits.
        if avDevice.isLowLightBoostSupported {
            avDevice.automaticallyEnablesLowLightBoostWhenAvailable = false
        }

        avDevice.unlockForConfiguration()

        // ── 4. Wire session input + output ──────────────────────────────────────────
        // All avDevice-derived objects (deviceInput) must be created and added to the
        // session BEFORE avDevice is "sent" into LiveCaptureDevice's actor isolation.
        // Swift 6 region isolation treats LiveCaptureDevice(avDevice:) as a send; any
        // subsequent use of avDevice or values derived from it would be flagged.
        let deviceInput = try AVCaptureDeviceInput(device: avDevice)

        avSession.beginConfiguration()

        // bug6: set sessionPreset to .inputPriority before adding the input so the
        // device's activeFormat is honored. The default preset (.high) overrides
        // activeFormat and silently downgrades the delivered buffer to 1080p,
        // which left the destination textures (sized at format dims, e.g.
        // 4032×3024) under-filled and showing un-sampled BT.601-of-zero green
        // along the bottom and right edges.
        if avSession.canSetSessionPreset(.inputPriority) {
            avSession.sessionPreset = .inputPriority
        }

        if avSession.canAddInput(deviceInput) {
            avSession.addInput(deviceInput)
        }

        // Output settings: request the pixel format we want from AVFoundation.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Constants.capturePixelFormat
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(sampleBufferDelegate, queue: deliveryQueue)

        if avSession.canAddOutput(videoOutput) {
            avSession.addOutput(videoOutput)
        }

        avSession.commitConfiguration()

        // Register interruption and runtime-error observers now that configuration is committed.
        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: avSession,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note: note, ended: false)
        }
        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: avSession,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note: note, ended: true)
        }
        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: avSession,
            queue: nil
        ) { [weak self] note in
            self?.handleRuntimeError(note: note)
        }

        // ── 5. Wrap in LiveCaptureDevice (ADR-32 test seam) ─────────────────────────
        // Done last: avDevice is "sent" into the actor here; no further direct uses
        // of avDevice follow in this function.
        let liveDevice = LiveCaptureDevice(avDevice: avDevice)
        self.device = liveDevice

        // ── 6. Orientation: landscape-right via videoRotationAngle (ADR-17) ─────────
        if let connection = videoOutput.connection(with: .video) {
            let angle = Constants.captureOrientationAngleDeg  // ADR-17
            guard connection.isVideoRotationAngleSupported(angle) else {
                throw EngineError.noSupportedFormat(
                    reason: "videoRotationAngle \(angle)° not supported on this device (ADR-17)")
            }
            connection.videoRotationAngle = angle  // ADR-17

            // bug6: disable video stabilization. The standard / cinematic modes
            // warp each frame (rolling-shutter correction + bilinear resample +
            // crop), which softens fine detail. Off makes the captured frame a
            // raw read of the sensor's ISP-processed output without geometric
            // post-processing — material sharpness gain on stills.
            connection.preferredVideoStabilizationMode = .off
        }

        return (device: liveDevice, captureSize: chosenSize)
    }

    // MARK: - Lifecycle wrappers

    /// Starts the capture session.
    ///
    /// Caller must dispatch onto `sessionQueue` (ADR-07).
    func startRunning() {
        avSession.startRunning()
    }

    /// Stops the capture session.
    ///
    /// Caller must dispatch onto `sessionQueue` (ADR-07).
    func stopRunning() {
        avSession.stopRunning()
    }

    /// Starts the capture session asynchronously with a timeout (ADR-30).
    ///
    /// Returns when startRunning() completes or when SESSION_LIFECYCLE_TIMEOUT_SECONDS
    /// elapses, whichever comes first. Never throws.
    func startRunningAsync() async {
        await runOnQueue(sessionQueue) { [self] in
            startRunning()
        }
    }

    /// Stops the capture session asynchronously with a timeout (ADR-30).
    ///
    /// Returns when stopRunning() completes or when SESSION_LIFECYCLE_TIMEOUT_SECONDS
    /// elapses, whichever comes first. Never throws.
    func stopRunningAsync() async {
        await runOnQueue(sessionQueue) { [self] in
            stopRunning()
        }
    }

    /// Re-select device format for new resolution.
    ///
    /// Stage 03 placeholder for `setResolution` (brief §4): re-select device format.
    /// Stage 06 replaces with pool-resize. Runs on `sessionQueue` (ADR-07).
    func reconfigureSize(_ size: Size) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                self.avSession.beginConfiguration()
                defer { self.avSession.commitConfiguration() }

                let currentInput = self.avSession.inputs
                    .compactMap { $0 as? AVCaptureDeviceInput }
                    .first
                guard let dev = currentInput?.device else {
                    cont.resume(throwing: EngineError.noBackCamera)
                    return
                }
                // Match on (FullRange pixel format, exact dimensions). FullRange-only
                // mirrors the initial open() filter (state.md Decision §63) so resolution
                // changes can't accidentally land on a VideoRange format.
                let match = dev.formats.first { fmt in
                    let subType = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
                    guard subType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
                        return false
                    }
                    let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                    return Int(d.width) == size.width && Int(d.height) == size.height
                }
                guard let match else {
                    cont.resume(
                        throwing: EngineError.noSupportedFormat(
                            reason: "no format matching \(size.width)x\(size.height)"))
                    return
                }
                do {
                    try dev.lockForConfiguration()
                    dev.activeFormat = match
                    dev.unlockForConfiguration()
                    cont.resume()
                } catch {
                    cont.resume(throwing: EngineError.lockForConfigurationFailed)
                }
            }
        }
    }

    // MARK: - Private event handlers

    /// Human-readable name for an interruption reason — diagnostics only.
    ///
    /// The engine treats every reason except `videoDeviceInUseByAnotherClient`
    /// through the same generic interrupted → reconcile path, so this is for the
    /// log, not control flow. `sensitiveContentMitigationActivated` is decoded for
    /// completeness but is not expected for CameraKit: it only fires when an
    /// `SCVideoStreamAnalyzer` is associated with the device input (CameraKit
    /// attaches none) and would not auto-recover via `interruptionEndedNotification`
    /// (it needs the analyzer's `continueStream`).
    private static func interruptionReasonName(_ raw: Int) -> String {
        guard let reason = AVCaptureSession.InterruptionReason(rawValue: raw) else {
            return "invalid(\(raw))"
        }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "videoDeviceNotAvailableInBackground"
        case .audioDeviceInUseByAnotherClient: return "audioDeviceInUseByAnotherClient"
        case .videoDeviceInUseByAnotherClient: return "videoDeviceInUseByAnotherClient"
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            return "videoDeviceNotAvailableWithMultipleForegroundApps"
        case .videoDeviceNotAvailableDueToSystemPressure:
            return "videoDeviceNotAvailableDueToSystemPressure"
        case .sensitiveContentMitigationActivated: return "sensitiveContentMitigationActivated"
        @unknown default: return "unknown(\(raw))"
        }
    }

    private func handleInterruption(note: Notification, ended: Bool) {
        let rawReason = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
        let keys = note.userInfo?.keys.map { "\($0)" } ?? []
        CameraKitLog.notice(
            .engine,
            "[interruption] ended=\(ended) reason=\(Self.interruptionReasonName(rawReason)) "
                + "rawReason=\(rawReason) keys=\(keys)")
        let reason = AVCaptureSession.InterruptionReason(rawValue: rawReason)
        if reason == .videoDeviceInUseByAnotherClient {
            onSessionEvent?(ended ? .cameraInUseEnded : .cameraInUseBegan)
        } else if ended {
            onSessionEvent?(.otherInterruptionEnded)
        } else {
            onSessionEvent?(.otherInterruption(reasonRawValue: rawReason))
        }
    }

    private func handleRuntimeError(note: Notification) {
        let err = note.userInfo?[AVCaptureSessionErrorKey] as? Error
        let msg = err.map { "\($0)" } ?? "unknown"
        CameraKitLog.error(.engine, "[session] runtime error: \(msg)")
        onSessionEvent?(.runtimeError(msg))
    }

    // MARK: - Frame rate control (U-16)

    /// Preview mode — lock frame rate to FRAME_RATE_TARGET_FPS on both min and max.
    ///
    /// Caller must dispatch onto `sessionQueue` (ADR-07).
    func setPreviewFrameRateRange() async throws {
        guard let device = device else { return }
        try await device.lockForConfiguration()
        do {
            try await device.setVideoFrameDurationRange(
                minFrameDurationFps: Constants.frameRateTargetFPS,
                maxFrameDurationFps: Constants.frameRateTargetFPS
            )
            await device.unlockForConfiguration()
        } catch {
            await device.unlockForConfiguration()
            throw error
        }
    }

    /// Recording mode — allow AE to halve frame rate in low light.
    ///
    /// Min = 1/FRAME_RATE_TARGET_FPS, Max = 1/FRAME_RATE_RECORDING_MIN_FPS.
    ///
    /// Caller must dispatch onto `sessionQueue` (ADR-07).
    func setRecordingFrameRateRange() async throws {
        guard let device = device else { return }
        try await device.lockForConfiguration()
        do {
            try await device.setVideoFrameDurationRange(
                minFrameDurationFps: Constants.frameRateTargetFPS,
                maxFrameDurationFps: Constants.frameRateRecordingMinFps
            )
            await device.unlockForConfiguration()
        } catch {
            await device.unlockForConfiguration()
            throw error
        }
    }

    // MARK: - Settings commit

    /// Commits a fully-resolved `CameraSettings` to the device inside a single
    /// `lockForConfiguration()` window on `sessionQueue` (ADR-07).
    ///
    /// The caller (`CameraEngine.updateSettings`) is responsible for having
    /// already run `merging(onto:)`, `SettingsCoupling.apply(rules:latched:)`,
    /// and range validation — this function only commits.
    ///
    /// ISO + exposure are coupled by `setIsoExposureManual(durationNs:iso:)`'s
    /// API shape (07-settings.md §Commit shape). Focus, white balance, zoom,
    /// and EV bias commit independently inside the same lock window.
    func applySettings(
        _ settings: CameraSettings,
        on device: any CaptureDeviceProviding
    ) async throws {
        try await device.lockForConfiguration()
        do {
            // Exposure + ISO — coupled commit when both manual.
            if settings.exposureMode == .manual,
                let durationNs = settings.exposureTimeNs,
                let iso = settings.iso
            {
                try await device.setIsoExposureManual(
                    durationNs: durationNs,
                    iso: Float(iso))
            } else if settings.exposureMode == .auto {
                try await device.setContinuousAutoExposure()
            }

            // Focus.
            if settings.focusMode == .manual, let d = settings.focusDistance {
                try await device.setFocusModeLocked(lensPosition: Float(d))
            } else if settings.focusMode == .auto {
                try await device.setContinuousAutoFocus()
            }

            // White balance.
            if let mode = settings.wbMode {
                switch mode {
                case .manual:
                    if let r = settings.wbGainR,
                        let g = settings.wbGainG,
                        let b = settings.wbGainB
                    {
                        // Bug 7: AVFoundation requires each gain in [1.0, maxWhiteBalanceGain]
                        // and throws NSInvalidArgumentException → SIGABRT otherwise.
                        // grayWorldGains() can produce out-of-range values for any
                        // non-gray sample, so clamp here regardless of source.
                        let maxGain = await device.maxWhiteBalanceGain
                        let clamp: (Double) -> Float = { v in
                            min(maxGain, max(1.0, Float(v)))
                        }
                        try await device.setWhiteBalanceModeLocked(
                            gains: WhiteBalanceGains(
                                red: clamp(r),
                                green: clamp(g),
                                blue: clamp(b)))
                    }
                case .locked:
                    try await device.setWhiteBalanceLocked()
                case .auto:
                    try await device.setContinuousAutoWhiteBalance()
                }
            }

            // Zoom.
            if let z = settings.zoomRatio {
                try await device.setZoomFactor(z)
            }

            // EV compensation (effective only in auto exposure per domain).
            if let ev = settings.evCompensation {
                try await device.setExposureCompensation(ev)
            }

            await device.unlockForConfiguration()
        } catch {
            await device.unlockForConfiguration()
            throw error
        }
    }
}
