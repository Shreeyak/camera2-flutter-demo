import AVFoundation
import Atomics
import CoreMedia
import CoreVideo
import Metal
import Photos
import Synchronization
import UniformTypeIdentifiers

/// The public actor that orchestrates the entire camera pipeline.
/// This is the ONLY type callers interact with at the API layer.
///
/// ADR-07: All AVCaptureSession mutations go through sessionQueue.
/// ADR-09: submissionGate guards every commandBuffer.commit() on the delivery queue.
/// ADR-22: stateStream() returns AsyncStream<SessionState> buffered with .bufferingOldest.
/// ADR-30: backgroundSuspend() / backgroundResume() use async-with-timeout for session lifecycle.
/// ADR-32: Production code never creates AVCaptureDevice directly — CameraSession handles that.
public actor CameraEngine {

    // MARK: - Private state

    private var cameraSession: CameraSession?
    private var captureDelegate: CaptureDelegate?
    private var metalPipeline: MetalPipeline?
    private var stillCapture: StillCapture?
    /// Stage 06: public consumer registry per D-01 / D-03.
    ///
    /// Lifetime matches the engine; every `open()` passes this same instance to
    /// the `MetalPipeline` so publication (nonisolated `yield` on the delivery
    /// queue) and subscription (actor-isolated `subscribe` from Swift callers)
    /// share state.
    public nonisolated let consumers: ConsumerRegistry = ConsumerRegistry()
    private var deliveryQueue: DispatchQueue?
    // Bug 3 fix (docs/stage-11-pre-existing-bugs.md): continuations live in nonisolated
    // Mutex boxes so the AsyncStream init closure can install them synchronously. The
    // previous `Task { await self?.setXContinuation(c) }` hop returned to the caller
    // before the continuation was non-nil; emits during that window were dropped.
    private nonisolated let stateContinuationBox =
        Mutex<AsyncStream<SessionState>.Continuation?>(nil)
    // Bug 5: eagerly constructed in init() so the continuation is installed in
    // the box BEFORE any publishX(...) can fire. Write-once-before-read mailbox
    // per `Mailbox<T>` contract.
    private let cachedStateStream = Mailbox<AsyncStream<SessionState>>()
    private nonisolated let errorContinuationBox =
        Mutex<AsyncStream<CameraError>.Continuation?>(nil)
    private let cachedErrorStream = Mailbox<AsyncStream<CameraError>>()
    /// Authoritative SessionState — see `SessionStateMachine`.
    private var stateMachine = SessionStateMachine()

    /// Derived: open if any state other than `.closed`.
    ///
    /// Post-Stage-12 hardening: the prior stored `isOpen: Bool` was a
    /// 2-state degenerate view of a 7-case enum; `SessionStateMachine` is
    /// now the single source of truth. See DECISIONS entry 2026-05-15.
    private var isOpen: Bool { stateMachine.current != .closed }
    private var currentSettings: CameraSettings?
    /// Latest `ProcessingParameters` applied via `setProcessingParams(_:)`.
    ///
    /// `nil` until first apply / post-`close()`. Read by
    /// `currentProcessingParametersSnapshot()` (Phase-2 §2b — VM mirror sync
    /// after engine-side `calibrateBlackBalance()`).
    private var currentProcessing: ProcessingParameters?
    /// In-flight calibration sentinel (Phase-2 §2b).
    ///
    /// Non-nil while `calibrateWhiteBalance()` / `calibrateBlackBalance()` is
    /// running — `updateSettings()` (when WB fields are present) and
    /// `setResolution()` throw `.calibrationInProgress`. `close()` and the
    /// `.interrupted` `SessionState` route call `cancel()` here.
    private var calibrationTask: Task<CalibrationResult, Error>?
    private nonisolated let frameResultContinuationBox =
        Mutex<AsyncStream<FrameResult>.Continuation?>(nil)
    private let cachedFrameResultStream = Mailbox<AsyncStream<FrameResult>>()
    private var frameCounter: UInt64 = 0

    // Phase-2 §2c — active stream-configuration stream.
    private nonisolated let streamConfigContinuationBox =
        Mutex<AsyncStream<StreamConfiguration>.Continuation?>(nil)
    private let cachedStreamConfigStream = Mailbox<AsyncStream<StreamConfiguration>>()
    private var currentCropRegion: Rect?

    private var watchdogs: WatchdogPair?
    private var recovery: RecoveryCoordinator?
    private let clock: any CameraKitClock
    private var aeMonitorTask: Task<Void, Never>?
    private var fpsWindowStartMs: UInt64 = 0
    private var fpsFrameCount: Int = 0
    private var fpsLowStreak: Int = 0

    // ADR-09: GPU submission gate. Shared by reference with MetalPipeline.
    // Reads: delivery queue (.acquiring load). Writes: engine actor (.sequentiallyConsistent store).
    // `let` — same instance for the lifetime of the engine; nonisolated for synchronous
    // access by tests and by MetalPipeline (which holds it as a reference).
    nonisolated let submissionGate: ManagedAtomic<Bool> = ManagedAtomic(true)

    /// Session identity.
    ///
    /// Bumped on every close() and on entry to recovery. Completion handlers,
    /// watchdogs, and retry tasks compare against this to detect that they were
    /// armed for a stale session (D-10, Inv 9, Inv 12).
    nonisolated let sessionToken: ManagedAtomic<UInt64> = ManagedAtomic(0)

    // Bug 4 fix: previewTex accessors forward live to MetalPipeline mailboxes
    // (`latestNaturalBgra8Tex` / `latestProcessedBgra8Tex`) — which the pipeline
    // rewrites every frame. The previous capture-once snapshot pattern sat on whichever
    // pool buffer was dequeued at open() time and froze whenever pool rotation
    // moved past it (typical after any transient back-pressure). Tracker tex
    // already followed this live-forward pattern (line ~565).

    // Bug 4 / G-13: pipeline handle lives in a `Mailbox<T>` — single writer
    // (engine actor in `open()` / `close()`); readers wherever the pipeline's
    // own mailboxes need to be consulted (`currentTexture(stream:)`,
    // `currentPixelBuffer(stream:)`). Written exactly once per open / cleared
    // once per close; the mailbox holds a single pointer-sized reference.
    private let _metalPipeline = Mailbox<MetalPipeline>()

    // MARK: - Public API

    public init(clock: any CameraKitClock = SystemClock()) {
        self.clock = clock
        // Bug 5 (docs/stage-11-pre-existing-bugs.md): eagerly construct each
        // cached stream so its continuation is installed in the box *before*
        // any publishX(...) can fire. The lazy first-call pattern dropped the
        // .streaming emit fired inside engine.open() because ViewModel.start()
        // did not call stateStream() until after open() returned.
        self.cachedStateStream.store(
            AsyncStream<SessionState>(
                SessionState.self,
                bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
            ) { [weak self] continuation in
                self?.stateContinuationBox.withLock { $0 = continuation }
            })
        self.cachedErrorStream.store(
            AsyncStream<CameraError>(
                CameraError.self,
                bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
            ) { [weak self] continuation in
                self?.errorContinuationBox.withLock { $0 = continuation }
            })
        self.cachedFrameResultStream.store(
            AsyncStream<FrameResult>(
                FrameResult.self,
                bufferingPolicy: .bufferingNewest(1)
            ) { [weak self] continuation in
                self?.frameResultContinuationBox.withLock { $0 = continuation }
            })
        self.cachedStreamConfigStream.store(
            AsyncStream<StreamConfiguration>(
                StreamConfiguration.self,
                bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
            ) { [weak self] continuation in
                self?.streamConfigContinuationBox.withLock { $0 = continuation }
            })
        self.cachedRecordingStream.store(
            AsyncStream<RecordingState>(
                RecordingState.self,
                bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
            ) { [weak self] continuation in
                self?.recordingContinuationBox.withLock { $0 = continuation }
            })
    }

    /// Returns the last successfully committed settings, or nil if none have been applied.
    public func currentSettingsSnapshot() -> CameraSettings? { currentSettings }

    /// Returns the last applied `ProcessingParameters`, or nil if none have been applied.
    ///
    /// Symmetric with `currentSettingsSnapshot()`. Used by
    /// `CalibrationViewModel` to refresh its mirror after engine-side
    /// `calibrateBlackBalance()`. Phase-2 §2b.
    public func currentProcessingParametersSnapshot() -> ProcessingParameters? {
        currentProcessing
    }

    /// Opens the camera session and returns capabilities.
    ///
    /// - Throws: `EngineError.alreadyOpen` if already open.
    /// - Throws: `EngineError.cameraDenied` if permission not granted.
    /// - Throws: `EngineError.noBackCamera` if no back camera found.
    /// - Throws: `EngineError.metal(_:)` if MetalPipeline fails to initialise.
    public func open(configuration: OpenConfiguration = OpenConfiguration()) async throws -> SessionCapabilities {
        guard !isOpen else { throw EngineError.alreadyOpen }
        CameraKitLog.notice(.engine, "open: requesting camera permission")

        // 1. Camera permission (ADR-32: permission check uses AVFoundation directly —
        //    it's a process-level gate, not a device operation).
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else { throw EngineError.cameraDenied }

        // 1b. Eager Photos auth — request alongside camera so the user sees both
        //     prompts at first launch, not mid-capture. Photos is optional;
        //     denial does not fail open() (RecordingOptions.photosDestination
        //     default is .none).
        let photosStatus = await PhotosLibraryClient.authorizationProvider()
        CameraKitLog.notice(.engine, "open: photos auth status=\(photosStatus.rawValue)")

        // 2. Set up queues and delegates.
        let session = CameraSession()
        let delegate = CaptureDelegate()
        let delivery = DispatchQueue(label: "com.cambrian.camerakit.delivery", qos: .userInitiated)

        // 3. Configure the session on sessionQueue (ADR-07, ADR-30).
        //    session.configure() runs synchronously on the queue; the closure only
        //    touches session internals — no actor re-entry.
        let (device, captureSize): (any CaptureDeviceProviding, Size) = try session.sessionQueue.sync {
            try session.configure(deliveryQueue: delivery, sampleBufferDelegate: delegate)
        }

        // 4. Metal pipeline — pass the shared submission gate (ADR-09).
        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            throw EngineError.metal(MetalError.unsupportedFormat)
        }
        // P2a — honor OpenConfiguration.cropRegion as a TRUE crop: validate it
        // against the sensor (same constraints as setCropRegion — in-bounds,
        // even coords for 4:2:0), then size the output textures to the crop.
        // nil → full-frame output (captureSize), the default.
        let openOutputSize: Size?
        let openCropOrigin: (x: Int, y: Int)
        if let crop = configuration.cropRegion {
            try validateCropRegion(crop, sensor: captureSize)
            openOutputSize = Size(width: crop.width, height: crop.height)
            openCropOrigin = (crop.x, crop.y)
        } else {
            openOutputSize = nil
            openCropOrigin = (0, 0)
        }
        let pipeline = try MetalPipeline(
            device: mtlDevice,
            captureSize: captureSize,
            outputSize: openOutputSize,
            cropOrigin: openCropOrigin,
            gate: submissionGate,
            consumers: consumers,
            engineSessionToken: sessionToken
        )
        pipeline.onMetalError = { [weak self] mErr in
            Task { [weak self] in
                let err = CameraError(
                    code: .unknownError,
                    message: "metal: \(mErr)",
                    isFatal: false
                )
                await self?.publishErrorAsync(err)
                await self?.recovery?.enterRecovery(error: err)
            }
        }

        // 5. Wire sample buffer → Metal encode.
        //    Closure runs on delivery queue (ADR-02); pipeline is @unchecked Sendable.
        //    Capture `self` and dispatch through `_metalPipeline` — that slot is
        //    rewritten by `setResolution()` when the pipeline is rebuilt, so the
        //    closure must read it live each frame rather than capture the original
        //    `pipeline` reference (which goes nil at the first `setResolution`).
        delegate.onSampleBuffer = { [weak self] sampleBuffer in
            try? self?._metalPipeline.latest?.encode(sampleBuffer: sampleBuffer)
        }
        delegate.engine = self

        // 6. Store state.
        self.cameraSession = session
        session.onSessionEvent = { [weak self] event in
            Task { [weak self] in await self?.onSessionEvent(event) }
        }
        self.captureDelegate = delegate
        self.metalPipeline = pipeline
        self._metalPipeline.store(pipeline)
        // Seed the preview mailboxes with blank pool buffers so the natural and
        // processed lanes are non-nil on first open(), before the first frame —
        // otherwise the Flutter texture bridge registers id 0 and the natural
        // lane stays black until a close→open cycle (measurements 2026-05-20 §1, P2b).
        pipeline.seedPreviewMailboxes()
        stillCapture = StillCapture()
        self.deliveryQueue = delivery

        // Install KVO ingest so `lastSnapshot` is populated for Rule 3.
        await device.installKVOIngest()

        // 7. Open the gate (idempotent — starts true; explicit after any prior close).
        submissionGate.store(true, ordering: .sequentiallyConsistent)

        // 8. Stage 09: watchdogs + recovery coordinator.
        let gpu = Watchdog(kind: .gpu, clock: clock) { [weak self] fire in
            Task { [weak self] in await self?.handleWatchdogFire(fire) }
        }
        let cap = Watchdog(kind: .capture, clock: clock) { [weak self] fire in
            Task { [weak self] in await self?.handleWatchdogFire(fire) }
        }
        let pair = WatchdogPair(gpu: gpu, capture: cap)
        self.watchdogs = pair
        delegate.watchdogs = pair
        let hooks = RecoveryCoordinator.Hooks(
            performTeardownAndReopen: { [weak self] in
                await self?.close()
                _ = try await self?.open(configuration: configuration)
            },
            emitStateRecovering: { [weak self] in
                await self?.publishStateAsync(.recovering)
            },
            emitError: { [weak self] err in
                await self?.publishErrorAsync(err)
            },
            disarmWatchdogs: { [weak self] in
                await self?.disarmWatchdogsAsync()
            },
            incrementSessionToken: { [weak self] in
                self?.sessionToken.wrappingIncrement(ordering: .sequentiallyConsistent)
            }
        )
        self.recovery = RecoveryCoordinator(clock: clock, hooks: hooks)
        armWatchdogs()

        startAEMonitor(device: device)

        // 9a. Apply initialSettings (Phase-2 §2a) BEFORE startRunning so the first
        //     frame is at the requested settings — no defaults-then-snap flicker.
        //     If the caller passes initialSettings, skip the persisted-load path:
        //     caller is authoritative (Phase-3 Flutter open(cameraId, settings) maps
        //     here directly). When initialSettings is nil, fall back to the
        //     existing dev-harness persisted-settings restore.
        if let initial = configuration.initialSettings {
            try await self.updateSettings(initial)
        } else if let persisted = SettingsPersistence.load() {
            // Apply persisted settings if any. Clamp ISO to the device's current range
            // before restoring — a stored ISO from a different session can exceed the new
            // device's max, causing a settingsConflict throw that silently aborts the entire
            // restore including zoom and focus. Swallow remaining failures (Rule 3).
            do {
                let deviceIsoRange = await device.isoRange
                var clamped = persisted
                if let iso = clamped.iso {
                    clamped.iso = Int(max(deviceIsoRange.lowerBound, min(deviceIsoRange.upperBound, Float(iso))))
                }
                try await self.updateSettings(clamped)
            } catch {
                // intentional — don't block open() on a transient Rule 3
            }
        }

        // 9b. Start running on sessionQueue (ADR-07).
        session.sessionQueue.async {
            session.startRunning()
        }

        // 10. Publish .streaming state.
        publishState(.streaming, kind: .command)

        // Apply persisted ProcessingParameters if any (07-settings.md §Persistence).
        if let persistedProcessing = SettingsPersistence.loadProcessing() {
            await self.setProcessingParams(persistedProcessing)
        }

        // Mirror the requested crop into `currentCropRegion` so subsequent
        // `publishStreamConfiguration()` callers reflect the open-time crop even
        // before any `setCropRegion(_:)`. Source of truth for published config is
        // pipeline state (`Self.activeCropRect(for:)`), not this mirror.
        currentCropRegion = configuration.cropRegion

        // 11. Build and return SessionCapabilities.
        let supportedSizes = await device.supportedSizes
        // P2a — the REAL crop rect, derived from the pipeline's outputSize +
        // cropOrigin: full-frame Rect(0,0,sensorW,sensorH) when uncropped.
        let activeCropRegion = Self.activeCropRect(for: pipeline)
        let isoRange = await device.isoRange
        let exposureDurationRangeNs = await device.exposureDurationRangeNs
        let zoomMin = await device.minAvailableVideoZoomFactor
        let zoomMax = await device.maxAvailableVideoZoomFactor
        let evMin = await device.minExposureTargetBias
        let evMax = await device.maxExposureTargetBias
        let poolPtr = consumers.nativePipelinePointer()
        CameraKitLog.notice(
            .engine,
            "open: pipeline ready — \(captureSize.width)×\(captureSize.height) pool=0x\(String(poolPtr, radix: 16))"
        )
        return SessionCapabilities(
            supportedSizes: supportedSizes,
            previewTextureId: 0,  // stub: texture IDs arrive Stage 05
            naturalTextureId: 0,  // stub: texture IDs arrive Stage 05
            activeCaptureResolution: captureSize,
            activeCropRegion: activeCropRegion,
            // Lane-buffer format (what `currentPixelBuffer(stream:)` returns),
            // NOT camera source format. Phase-2 §2d.7; BGRA8 is unconditional.
            streamPixelFormat: Constants.streamPixelFormatString,
            isoRange: isoRange,
            exposureDurationRangeNs: exposureDurationRangeNs,
            focusRange: 0.0...1.0,
            zoomRange: zoomMin...zoomMax,
            evCompensationRange: evMin...evMax
        )
    }

    /// Closes the camera session and releases all resources.
    public func close() async {
        sessionToken.wrappingIncrement(ordering: .sequentiallyConsistent)
        // Phase-2 §2b — abort any in-flight calibration.
        calibrationTask?.cancel()
        watchdogs?.disarmAll()
        aeMonitorTask?.cancel()
        aeMonitorTask = nil
        fpsWindowStartMs = 0
        fpsFrameCount = 0
        fpsLowStreak = 0
        await recovery?.cancelPendingRetry()
        watchdogs = nil
        recovery = nil
        guard isOpen else { return }
        CameraKitLog.notice(.engine, "close: tearing down pipeline")
        // Disarm watchdogs (placeholder; real watchdog disarm arrives Stage 09).
        submissionGate.store(false, ordering: .sequentiallyConsistent)
        if let session = cameraSession {
            session.sessionQueue.sync { session.stopRunning() }
        }
        if let device = cameraSession?.device {
            await device.cancelKVO()
        }
        frameResultContinuationBox.withLock {
            $0?.finish()
            $0 = nil
        }
        cachedFrameResultStream.store(nil)
        frameCounter = 0
        await consumers.release()
        cameraSession = nil
        captureDelegate = nil
        metalPipeline = nil
        stillCapture = nil
        _metalPipeline.store(nil)
        deliveryQueue = nil
        publishState(.closed, kind: .command)
    }

    /// Returns an AsyncStream of SessionState events.
    ///
    /// ADR-22: buffered with .bufferingOldest(Constants.stateStreamBufferSize).
    /// The stream is cached — multiple callers receive the same stream instance.
    public func stateStream() -> AsyncStream<SessionState> {
        if let existing = cachedStateStream.latest { return existing }
        let stream = AsyncStream<SessionState>(
            SessionState.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak self] continuation in
            // Synchronous install via nonisolated box — see Bug 3.
            self?.stateContinuationBox.withLock { $0 = continuation }
        }
        cachedStateStream.store(stream)
        return stream
    }

    /// Sensor-metadata heartbeat at `frameRateTargetFPS / frameResultHeartbeatIntervalFrames` Hz.
    /// `.bufferingNewest(1)` per ADR-22 (frame-rate stream).
    public func frameResultStream() -> AsyncStream<FrameResult> {
        if let existing = cachedFrameResultStream.latest { return existing }
        let stream = AsyncStream<FrameResult>(
            FrameResult.self,
            bufferingPolicy: .bufferingNewest(1)
        ) { [weak self] continuation in
            self?.frameResultContinuationBox.withLock { $0 = continuation }
        }
        cachedFrameResultStream.store(stream)
        return stream
    }

    /// Active stream configuration changes — fires when `setResolution(...)` resolves
    /// to a new size or `setCropRegion(...)` mutates the active crop.
    ///
    /// Phase-2 design §2c. Cached stream — multiple callers receive the same instance.
    /// `.bufferingOldest` so every config change is delivered.
    public func streamConfigurationStream() -> AsyncStream<StreamConfiguration> {
        if let s = cachedStreamConfigStream.latest { return s }
        let stream = AsyncStream<StreamConfiguration>(
            StreamConfiguration.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak self] continuation in
            self?.streamConfigContinuationBox.withLock { $0 = continuation }
        }
        cachedStreamConfigStream.store(stream)
        return stream
    }

    /// P2a — the REAL active crop rect for a pipeline: the sub-region the output
    /// textures cover.
    ///
    /// `Rect(cropOrigin.x, cropOrigin.y, outputSize.width, outputSize.height)`,
    /// which collapses to full-frame `Rect(0, 0, sensorW, sensorH)` when
    /// uncropped. Single source of truth for `activeCropRegion` in both
    /// `open()`'s `SessionCapabilities` and `publishStreamConfiguration()` —
    /// derived from pipeline state, not the `currentCropRegion` mirror.
    private static func activeCropRect(for pipeline: MetalPipeline) -> Rect {
        Rect(
            x: pipeline.cropOrigin.x,
            y: pipeline.cropOrigin.y,
            width: pipeline.outputSize.width,
            height: pipeline.outputSize.height)
    }

    private func publishStreamConfiguration() {
        guard let pipeline = metalPipeline else { return }
        let cfg = StreamConfiguration(
            activeCaptureResolution: pipeline.captureSize,
            activeCropRegion: Self.activeCropRect(for: pipeline))
        streamConfigContinuationBox.withLock { $0?.yield(cfg) }
    }

    /// Stream of error notifications (non-fatal + fatal).
    ///
    /// ADR-22: .bufferingOldest so every error is delivered. Subscribe once per consumer
    /// lifetime; same instance returned thereafter.
    public func errorStream() -> AsyncStream<CameraError> {
        if let cached = cachedErrorStream.latest { return cached }
        let stream = AsyncStream<CameraError>(
            CameraError.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak self] continuation in
            self?.errorContinuationBox.withLock { $0 = continuation }
        }
        cachedErrorStream.store(stream)
        return stream
    }

    private func publishError(_ err: CameraError) {
        errorContinuationBox.withLock { $0?.yield(err) }
    }

    /// Test-only: emit an arbitrary CameraError without driving the recovery machine.
    func _emitErrorForTest(_ err: CameraError) {
        publishError(err)
    }

    /// Publishes `.paused` (when `paused == true`) or `.streaming` for SwiftUI scenePhase pause/resume.
    ///
    /// Covers Control Center pull-down, Notification Center, app-switcher
    /// peek, etc. The camera stays bound across these transitions; only GPU
    /// submission is gated. Phase-2 follow-up to §2d.5 (distinct from the
    /// AVF-interruption `.interrupted` case).
    ///
    /// Caller (the app's SwiftUI `ScenePhase` observer) is still responsible
    /// for the gate via `setGate` — this method only mirrors the lifecycle
    /// transition into `SessionState` so downstream consumers
    /// (`ErrorPresenterViewModel`, Phase-3's Pigeon adapter) see a consistent
    /// pause/resume signal.
    ///
    /// The mirror defers to OS-driven events when the state machine sits in an
    /// OS-owned origin (`.interrupted`, `.recovering`, `.error`). From those
    /// states the only legitimate `.command` transition is `.closed`, so a
    /// scenePhase-driven `.streaming`/`.paused` is off-map — and worse, would
    /// overwrite the OS's truth with a wrong value. `SessionStateMachine` is the
    /// single source of truth: if `classify` rejects the mirrored transition we
    /// skip the publish (logged) and let the OS event path restore `.streaming`
    /// (`onSessionEvent(.otherInterruptionEnded)`, recovery completion). This
    /// also closes the symmetric `.opening → .paused` hole. Caught under
    /// `test_device`, where a harness/bring-up AVF interruption races a
    /// `.active` scenePhase into the off-map path in `publishState` — a
    /// wrong-value overwrite of OS-owned state (a DEBUG abort too, before Fix 2). The
    /// background stall-watchdog disarm (`.otherInterruption` / `backgroundSuspend`)
    /// is the complementary half of the HITL background-crash fix (measurements
    /// 2026-05-20 §1, case #12).
    ///
    /// Known gap (out of scope — D-06 gate owns correctness): if an interruption
    /// ends while the app is backgrounded, the OS publishes `.streaming (event)`
    /// but the ViewModel won't re-issue `notifyScenePhasePaused(true)` until the
    /// next scenePhase change — the machine reads `.streaming` while the gate is
    /// still closed. A truthfulness gap, not a crash.
    public func notifyScenePhasePaused(_ paused: Bool) {
        let target: SessionState = paused ? .paused : .streaming
        let from = stateMachine.current
        if SessionStateMachine.classify(from: from, to: target, kind: .command) == .offMap {
            CameraKitLog.notice(
                .engine,
                "[scenePhase] skipping mirror from=\(from.rawValue) "
                    + "to=\(target.rawValue) kind=command caller=\(#function) "
                    + "(deferring to OS-driven state)"
            )
            return
        }
        publishState(target, kind: .command)
    }

    /// Test-only: drive the state machine into `.streaming` so teardown paths
    /// (`close()` and the `.cameraInUseEnded` self-heal) can be exercised
    /// without real hardware.
    ///
    /// Pokes `SessionStateMachine` directly via `_setCurrentForTest` (bypasses
    /// classification — matches the prior `isOpen = true` intent of skipping
    /// the normal `.opening`/`.streaming` path). No emission on the state
    /// stream — preserves the original `isOpen = true` semantics where the
    /// seam mutated state without publishing. Tests that need a published
    /// `.streaming` should call `engine.open()` or subscribe before posting
    /// events that advance state. `cameraSession`, `metalPipeline`, etc.
    /// stay nil — `close()` is nil-safe for all of them, so the path runs
    /// cleanly and reaches `publishState(.closed)`. Reproduces the realistic
    /// D-14 precondition: a `.cameraInUse` interruption only ever reaches a
    /// running session, i.e. an already-open engine.
    func _markOpenForTest() {
        stateMachine._setCurrentForTest(.streaming)
    }

    /// Test-only: read the state machine's current `SessionState` (stateStream only yields on publish).
    var _currentStateForTest: SessionState { stateMachine.current }

    /// Called from `CaptureDelegate` on every sample buffer (nonisolated — delivery queue).
    nonisolated func tickFrame() {
        Task { await self.onFrameTick() }
    }

    private func onFrameTick() async {
        frameCounter &+= 1
        guard frameCounter % UInt64(Constants.frameResultHeartbeatIntervalFrames) == 0,
            let device = cameraSession?.device,
            let snap = await device.lastSnapshot
        else { return }
        let r = FrameResult(
            iso: Int(snap.iso),
            exposureTimeNs: snap.exposureDurationNs,
            focusDistance: Double(snap.lensPosition),
            wbGainR: Double(snap.whiteBalanceGains.red),
            wbGainG: Double(snap.whiteBalanceGains.green),
            wbGainB: Double(snap.whiteBalanceGains.blue))
        frameResultContinuationBox.withLock { $0?.yield(r) }
    }

    /// Full settings merge→couple→validate→commit→persist pipeline (Stage 03).
    ///
    /// - Merges onto prior state
    /// - Applies coupling rules (Rules 1/2/3 from 07-settings.md)
    /// - Validates ranges against device capabilities
    /// - Commits to device via sessionQueue (ADR-07)
    /// - Persists asynchronously (detached Task)
    ///
    /// - Throws: `EngineError.notOpen` if engine not open
    /// - Throws: `EngineError.settingsConflict` if range validation fails or Rule 3 pre-readback
    /// - Throws: `EngineError.calibrationInProgress` if a `calibrate*()` is in
    ///   flight and `settings` touches white balance (Phase-2 §2b).
    public func updateSettings(_ settings: CameraSettings) async throws {
        // Phase-2 §2b — block conflicting WB writes during in-flight calibration.
        if calibrationTask != nil && settingsTouchesWhiteBalance(settings) {
            throw EngineError.calibrationInProgress
        }
        try await _updateSettingsBypassingCalibrationGuard(settings)
    }

    /// Same body as `updateSettings(_:)` but skips the calibration-guard.
    ///
    /// Used by `calibrateWhiteBalance()` so the in-flight calibration can
    /// commit its own `.manual` lock without tripping its own guard.
    private func _updateSettingsBypassingCalibrationGuard(_ settings: CameraSettings) async throws {
        guard let session = cameraSession, let device = session.device else {
            throw EngineError.notOpen
        }

        // 1. Merge onto prior state, then promote a single-field manual request
        //    so it pins both ISO and exposure (iOS couples them in one
        //    setIsoExposureManual call — measurements 2026-05-20 §1, case #4).
        let prior = currentSettings ?? CameraSettings()
        let merged = SettingsCoupling.promoteSingleFieldManual(
            request: settings,
            merged: settings.merging(onto: prior))

        // 2. Couple (Rules 1/2/3). Reads the last KVO snapshot for Rule 3.
        let latched = await device.lastSnapshot
        let resolved = try SettingsCoupling.apply(rules: merged, latched: latched)

        // 3. Range-validate against the device's supported ranges (brief §7).
        let isoRange = await device.isoRange
        let expRange = await device.exposureDurationRangeNs
        if let iso = resolved.iso, !isoRange.contains(Float(iso)) {
            throw EngineError.settingsConflict(
                reason: "iso=\(iso) outside supported range \(isoRange)")
        }
        if let exp = resolved.exposureTimeNs, !expRange.contains(exp) {
            throw EngineError.settingsConflict(
                reason: "exposureTimeNs=\(exp) outside supported range \(expRange)")
        }
        if let focus = resolved.focusDistance, !(0.0...1.0).contains(focus) {
            throw EngineError.settingsConflict(
                reason: "focusDistance=\(focus) outside [0.0, 1.0]")
        }

        // 4. Commit through session (ADR-07).
        try await session.applySettings(resolved, on: device)
        currentSettings = resolved

        // 5. Persist. Detached so the actor doesn't block on I/O.
        let toSave = resolved
        Task.detached { SettingsPersistence.save(toSave) }
    }

    /// True when `settings` would mutate white-balance fields.
    ///
    /// Used by the calibration-guard in `updateSettings`. Phase-2 §2b.
    private func settingsTouchesWhiteBalance(_ settings: CameraSettings) -> Bool {
        settings.wbMode != nil
            || settings.wbGainR != nil
            || settings.wbGainG != nil
            || settings.wbGainB != nil
    }

    /// Session-only teardown + re-select format + restart for new resolution.
    ///
    /// Pool-resize is a placeholder until Stage 06 introduces the trio (brief §4).
    ///
    /// - Throws: `EngineError.notOpen` if not yet open.
    public func setResolution(size: Size) async throws {
        guard let session = cameraSession else { throw EngineError.notOpen }
        // Phase-2 §2b: setResolution restarts the session, which would invalidate
        // an in-flight calibration's pipeline reference.
        if calibrationTask != nil { throw EngineError.calibrationInProgress }

        submissionGate.store(false, ordering: .sequentiallyConsistent)
        await drainSubmittedFrame()

        await session.stopRunningAsync()
        metalPipeline = nil
        _metalPipeline.store(nil)

        try await session.reconfigureSize(size)

        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            throw EngineError.metal(MetalError.unsupportedFormat)
        }
        let pipeline = try MetalPipeline(
            device: mtlDevice,
            captureSize: size,
            gate: submissionGate,
            consumers: consumers,
            engineSessionToken: sessionToken
        )
        pipeline.onMetalError = { [weak self] mErr in
            Task { [weak self] in
                let err = CameraError(
                    code: .unknownError,
                    message: "metal: \(mErr)",
                    isFatal: false
                )
                await self?.publishErrorAsync(err)
                await self?.recovery?.enterRecovery(error: err)
            }
        }
        metalPipeline = pipeline
        _metalPipeline.store(pipeline)
        // Seed preview mailboxes for the new pipeline so the lanes don't blank
        // during a resolution change (measurements 2026-05-20 §1, P2b).
        pipeline.seedPreviewMailboxes()

        captureDelegate?.logNextFrame = true
        submissionGate.store(true, ordering: .sequentiallyConsistent)
        await session.startRunningAsync()
        CameraKitLog.notice(
            .engine,
            "[resolution] startRunning returned sessionRunning=\(session.avSession.isRunning)")
        // Phase-2 §2c: emit active-config-changed.
        publishStreamConfiguration()
    }

    /// Signals the app entered background.
    ///
    /// Gates GPU submission, drains any in-flight
    /// frame, and stops the capture session via sessionQueue with timeout (ADR-30).
    ///
    /// Disarms the stall watchdogs and cancels any pending recovery retry (Inv 9):
    /// the session is being stopped on purpose, so no frames are expected and a
    /// stall is not a fault. Leaving them armed fires spurious recovery while
    /// backgrounded, which collides with the OS-interruption state and aborts in
    /// DEBUG — the HITL background crash (measurements 2026-05-20 §1). Re-armed by
    /// `backgroundResume()`.
    public func backgroundSuspend() async {
        CameraKitLog.notice(.engine, "[bgsuspend] enter gate=false stopRunning")
        submissionGate.store(false, ordering: .sequentiallyConsistent)
        watchdogs?.disarmAll()
        await recovery?.cancelPendingRetry()
        if recording != nil {
            CameraKitLog.notice(
                .engine, "[bgsuspend] active recording — finalizing via background-task drain")
            _ = await finalizeActiveRecording(reason: .user)
        }
        await drainSubmittedFrame()
        if let session = cameraSession {
            captureDelegate?.logNextFrame = true
            await session.stopRunningAsync()
        }
        CameraKitLog.notice(.engine, "[bgsuspend] stopRunning returned")
    }

    /// Signals the app returned to foreground.
    ///
    /// Re-opens the GPU submission gate and restarts the capture session that was
    /// stopped by `backgroundSuspend()`.
    public func backgroundResume() async {
        CameraKitLog.notice(
            .engine,
            "[bgresume] enter gate=true sessionRunning=\(cameraSession?.avSession.isRunning == true)")
        submissionGate.store(true, ordering: .sequentiallyConsistent)
        CameraKitLog.notice(.engine, "[bgresume] gate opened")
        if let session = cameraSession {
            await session.startRunningAsync()
            CameraKitLog.notice(
                .engine,
                "[bgresume] startRunning returned sessionRunning=\(session.avSession.isRunning)")
            // Frames resume — re-arm the watchdogs disarmed by backgroundSuspend().
            armWatchdogs()
        }
    }

    /// Debug: dump every `AVCaptureDevice.Format` the active device exposes.
    ///
    /// Includes FourCC + dimensions + FPS ranges + bit-depth/range tag.
    /// Returns `[]` when no live device is bound (e.g., closed engine or
    /// fake provider in tests). Used by `ViewModel.dumpCapabilities` to
    /// snapshot the format table to `Documents/capabilities.txt`.
    public func dumpDeviceFormats() async -> [String] {
        guard let device = cameraSession?.device else { return [] }
        return await device.dumpAllFormats()
    }

    /// Exposes the live natural-lane texture for the MTKView draw pass.
    ///
    /// `.bgra8Unorm` — the same IOSurface delivered by
    /// `currentPixelBuffer(stream: .natural)`, exposed as an `MTLTexture` for
    /// the preview. One 8-bit surface per lane; the camera is 8-bit-locked, so
    /// there is no precision to preserve at the delivery boundary (RGBA16F
    /// survives only as an internal compute intermediate for the Metal math /
    /// calibration sampling). Forwards to `MetalPipeline.latestNaturalBgra8Tex`
    /// (single writer: delivery queue). MUST be re-evaluated each draw; do not
    /// cache (Bug 4: pool rotation strands cached pointers).
    public nonisolated func currentTexture() -> (any MTLTexture)? {
        _metalPipeline.latest?.latestNaturalBgra8Tex
    }

    /// Exposes the live processed-lane texture for the right-half MTKView draw.
    ///
    /// `.bgra8Unorm` — see `currentTexture()`. Same live-mailbox contract;
    /// re-evaluate per draw.
    public nonisolated func currentProcessedTexture() -> (any MTLTexture)? {
        _metalPipeline.latest?.latestProcessedBgra8Tex
    }

    /// Stage 06: returns the latest tracker texture for external consumers.
    ///
    /// Returns `.bgra8Unorm`. Pass-4's tracker downsample kernel writes `float4` via
    /// `texture2d<float, access::write>` into a BGRA8 pool texture — the hardware
    /// clamps [0,1] and stores 8-bit BGRA with no shader change. `nonisolated` so
    /// callers can access synchronously without an actor hop. Reads `latestTrackerTex`
    /// from the pipeline's `Mailbox<T>` (G-13). Returns nil if no frame has been
    /// encoded yet or the engine is closed.
    public nonisolated func currentTrackerTexture() -> (any MTLTexture)? {
        _metalPipeline.latest?.latestTrackerTex
    }

    /// Returns the latest IOSurface-backed `CVPixelBuffer` for the requested
    /// lane, or `nil` if no frame has been delivered yet (or post-pause/close).
    ///
    /// `nonisolated` + synchronous — Phase-3's `FlutterTexture.copyPixelBuffer()`
    /// is called on the GPU thread and must not suspend.
    ///
    /// **Format:** All three lanes return `kCVPixelFormatType_32BGRA` (BGRA8).
    ///
    /// - `.natural` / `.processed`: Pass-7 RGBA16F→BGRA8 conversion.
    /// - `.tracker`: fused — `trackerPool` is BGRA8; Pass-4 writes BGRA8 directly.
    public nonisolated func currentPixelBuffer(stream: StreamId) -> CVPixelBuffer? {
        switch stream {
        case .natural: return _metalPipeline.latest?.latestNaturalBuffer
        case .processed: return _metalPipeline.latest?.latestProcessedBuffer
        case .tracker: return _metalPipeline.latest?.latestTrackerBuffer
        }
    }

    /// Returns the raw C++ PixelSinkPool pointer as UInt64 while holding the engine actor (D-15).
    ///
    /// Returns nil when the engine is not open.
    public func getNativePipelineHandle() -> UInt64? {
        guard isOpen else {
            CameraKitLog.warning(.engine, "getNativePipelineHandle: engine not open — returning nil")
            return nil
        }
        let ptr = consumers.nativePipelinePointer()
        return ptr
    }

    /// Stage 05: writes color-transform uniforms through `Mutex<UniformStorage>` (ADR-34, D-17, Inv 6).
    ///
    /// Wholesale replacement (no merge — `ProcessingParameters` is non-nullable per
    /// architecture/07-settings.md §ProcessingParameters).
    ///
    /// **Pipeline order (`Shaders/ColorShaders.metal`):**
    ///   1. Brightness → 2. Contrast → 3. Saturation → 4. Gamma → 5. Black balance.
    ///
    /// Black balance is the **last** step — pedestal is subtracted from the
    /// graded output, behaving like a final shadow lift rather than a
    /// pre-grade noise-floor compensation. Calibration sampling for BB must
    /// therefore read from a render where BCSG is applied and BB is zeroed
    /// (see `MetalPipeline.dispatchBBCalibrationSample`) so each calibrate
    /// isn't biased by the previously-applied pedestal.
    public func setProcessingParams(_ params: ProcessingParameters) async {
        // Route through the mutex so the delivery-queue snapshot in encode() is always coherent.
        metalPipeline?.uniforms.withLock { storage in
            storage.color = ColorUniform(params)
        }
        // Mirror for `currentProcessingParametersSnapshot()` (Phase-2 §2b).
        currentProcessing = params
        // Persist on every successful update (07-settings.md §Write path).
        let toSave = params
        Task.detached { SettingsPersistence.saveProcessing(toSave) }
    }

    /// Validates a P2a true-crop rect against the sensor bounds and the 4:2:0
    /// chroma-alignment constraint.
    ///
    /// - Throws: `EngineError.settingsConflict` if the rect is degenerate (zero
    ///   width/height), extends past the sensor bounds, or has any odd
    ///   coordinate. Odd luma offsets/extents skew the half-resolution chroma
    ///   plane sampling and cause color fringing, so all four fields must be
    ///   even (4:2:0). Shared by `open()` and `setCropRegion(_:)`.
    private func validateCropRegion(_ rect: Rect, sensor: Size) throws {
        guard rect.width > 0, rect.height > 0,
            rect.x >= 0, rect.y >= 0,
            rect.x + rect.width <= sensor.width,
            rect.y + rect.height <= sensor.height
        else {
            throw EngineError.settingsConflict(
                reason: "crop rect \(rect) outside sensor bounds \(sensor.width)x\(sensor.height)")
        }
        guard rect.x % 2 == 0, rect.y % 2 == 0,
            rect.width % 2 == 0, rect.height % 2 == 0
        else {
            throw EngineError.settingsConflict(
                reason: "crop rect \(rect) has odd coordinate(s); 4:2:0 chroma requires even x/y/width/height")
        }
    }

    /// P2a: applies a TRUE crop — the natural/processed output resolution becomes
    /// the crop-region size.
    ///
    /// The AVCaptureSession keeps producing full sensor-size buffers; Pass-1
    /// reads the `rect`-offset sub-region at 1:1 into `rect.width × rect.height`
    /// output textures (no zoom, no masking). Implemented by recreating the
    /// `MetalPipeline` with the new `outputSize`/`cropOrigin` — the sensor
    /// resolution is unchanged, so (unlike `setResolution`) the AVF session is
    /// NOT reconfigured. Overrides state.md #67 (which recommended dropping this
    /// API); see DECISIONS.md.
    ///
    /// - Throws: `EngineError.notOpen` if the session is not open.
    /// - Throws: `EngineError.calibrationInProgress` if a calibration is in
    ///   flight (the rebuild would invalidate its pipeline reference).
    /// - Throws: `EngineError.settingsConflict` if the rect is degenerate,
    ///   out of sensor bounds, or has odd coordinates (4:2:0 chroma).
    public func setCropRegion(_ rect: Rect) async throws {
        guard let pipeline = metalPipeline else { throw EngineError.notOpen }
        // A pipeline rebuild would strand an in-flight calibration's reference.
        if calibrationTask != nil { throw EngineError.calibrationInProgress }

        let sensor = pipeline.captureSize
        try validateCropRegion(rect, sensor: sensor)

        submissionGate.store(false, ordering: .sequentiallyConsistent)
        await drainSubmittedFrame()

        metalPipeline = nil
        _metalPipeline.store(nil)

        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            throw EngineError.metal(MetalError.unsupportedFormat)
        }
        let newPipeline = try MetalPipeline(
            device: mtlDevice,
            captureSize: sensor,
            outputSize: Size(width: rect.width, height: rect.height),
            cropOrigin: (rect.x, rect.y),
            gate: submissionGate,
            consumers: consumers,
            engineSessionToken: sessionToken
        )
        newPipeline.onMetalError = { [weak self] mErr in
            Task { [weak self] in
                let err = CameraError(
                    code: .unknownError,
                    message: "metal: \(mErr)",
                    isFatal: false
                )
                await self?.publishErrorAsync(err)
                await self?.recovery?.enterRecovery(error: err)
            }
        }
        metalPipeline = newPipeline
        _metalPipeline.store(newPipeline)
        // Seed preview mailboxes so the lanes don't blank during the crop change
        // (measurements 2026-05-20 §1, P2b).
        newPipeline.seedPreviewMailboxes()

        submissionGate.store(true, ordering: .sequentiallyConsistent)

        currentCropRegion = rect
        // Phase-2 §2c: emit active-config-changed.
        publishStreamConfiguration()
    }

    /// Stage 04: dispatches the center-patch sampler and returns per-channel trimmed mean.
    ///
    /// Samples processedTex's CENTER_PATCH_SIZE_PX x CENTER_PATCH_SIZE_PX center, awaits
    /// completion, sorts each channel and returns the trimmed mean per
    /// CENTER_PATCH_TRIM_PERCENT (07-settings.md §Center-patch sampling).
    ///
    /// - Throws: `EngineError.notOpen` if the session is not open.
    /// - Throws: `EngineError.metal(_:)` on Metal failures.
    public func sampleCenterPatch() async throws -> RgbSample {
        guard let pipeline = metalPipeline else { throw EngineError.notOpen }
        return try await pipeline.dispatchCenterPatch()
    }

    /// WB-calibration sampler — reads from `naturalTex` (Pass-1 output).
    ///
    /// See `MetalPipeline.dispatchCenterPatchOnNatural` for the rationale.
    /// Phase-2 §2b: demoted to `internal` — callers go through
    /// `calibrateWhiteBalance()` instead.
    func sampleCenterPatchOnNatural() async throws -> RgbSample {
        guard let pipeline = metalPipeline else { throw EngineError.notOpen }
        return try await pipeline.dispatchCenterPatchOnNatural()
    }

    /// BB-calibration sampler — reads from a one-shot scratch render of current
    /// BCSG with BB zeroed.
    ///
    /// See `MetalPipeline.dispatchBBCalibrationSample` for the rationale.
    /// Phase-2 §2b: demoted to `internal` — callers go through
    /// `calibrateBlackBalance()` instead.
    func sampleCenterPatchForBBCalibration() async throws -> RgbSample {
        guard let pipeline = metalPipeline else { throw EngineError.notOpen }
        return try await pipeline.dispatchBBCalibrationSample()
    }

    /// Current AVCaptureDevice WB gains — whatever continuous AWB or a prior
    /// manual lock most recently set.
    ///
    /// Phase-2 §2b: demoted to `internal`.
    func currentDeviceWBGains() async throws -> WhiteBalanceGains {
        guard let device = cameraSession?.device else {
            throw EngineError.notOpen
        }
        return await device.currentDeviceWBGains
    }

    /// Device's max legal WB gain.
    ///
    /// Feeds the per-channel clamp at the end of
    /// `CalibrationCompute.grayWorldGains`. Phase-2 §2b: demoted to `internal`.
    func maxWhiteBalanceGain() async throws -> Float {
        guard let device = cameraSession?.device else {
            throw EngineError.notOpen
        }
        return await device.maxWhiteBalanceGain
    }

    /// Apple's gray-world gains for the current scene.
    ///
    /// Phase-2 §2b: demoted to `internal`.
    func grayWorldDeviceWBGains() async throws -> WhiteBalanceGains {
        guard let device = cameraSession?.device else {
            throw EngineError.notOpen
        }
        return await device.grayWorldDeviceWBGains
    }

    /// Switches WB to continuous auto, awaits AWB convergence, then reads
    /// Apple's gray-world gains for the now-settled scene.
    ///
    /// `calibrateWhiteBalance()`'s seed. Phase-2 §2b: demoted to `internal`.
    func freshGrayWorldDeviceWBGains() async throws -> WhiteBalanceGains {
        guard let device = cameraSession?.device else {
            throw EngineError.notOpen
        }
        try await device.lockForConfiguration()
        do {
            try await device.setContinuousAutoWhiteBalance()
            await device.unlockForConfiguration()
        } catch {
            await device.unlockForConfiguration()
            throw error
        }
        await device.awaitWBSettled()
        return await device.grayWorldDeviceWBGains
    }

    /// Awaits AE/AWB convergence after a mode switch (KVO-backed, 2s timeout).
    ///
    /// Phase-2 §2b: demoted to `internal`.
    func awaitWBSettled() async {
        guard let device = cameraSession?.device else { return }
        await device.awaitWBSettled()
    }

    /// Locks WB to one of Apple's named presets via the one-shot AVF API.
    ///
    /// Awaits both (a) AVF's confirmation of the first buffer with new gains
    /// (handler-bridged) and (b) the natural-pipeline encode catching up to
    /// that buffer's PTS (`awaitNaturalAfter`). On return, sampling the natural
    /// texture is guaranteed to read post-preset content.
    ///
    /// Bypasses the `wbGainR/G/B` settings path — gains are computed inside
    /// AVFoundation from sensor-calibrated temperature/tint constants. Used as
    /// the stable baseline for `calibrateWB` (`.daylight`). Locks/unlocks the
    /// device for the call (ADR-07). Phase-2 §2b: demoted to `internal`.
    func setWBPreset(_ preset: WhiteBalancePreset) async throws {
        guard let device = cameraSession?.device else {
            throw EngineError.notOpen
        }
        try await device.lockForConfiguration()
        let tApply: CMTime
        do {
            tApply = await device.setWhiteBalanceModeLockedToPresetAwaitingApply(preset)
            await device.unlockForConfiguration()
        } catch {
            await device.unlockForConfiguration()
            throw error
        }
        await awaitNaturalAfter(tApply)
    }

    /// Locks WB to explicit manual gains via AVF's `setWhiteBalanceModeLocked(with:completionHandler:)`.
    ///
    /// Awaits AVF's confirmation of the first buffer with new gains
    /// (handler-bridged with 400 ms deadline), then awaits the natural pipeline
    /// catching up to that buffer's PTS. On return, sampling the natural texture
    /// is guaranteed to read post-gains content. Caller is responsible for
    /// clamping inputs to `[1.0, maxWhiteBalanceGain]` — this does *not* go
    /// through `CameraSession.applySettings` so no auto-clamp applies. Used by
    /// `calibrateWB` to apply scene-derived gains and wait for the natural
    /// texture before any subsequent sample. Phase-2 §2b: demoted to `internal`.
    func applyManualGainsAndAwait(_ gains: WhiteBalanceGains) async throws {
        guard let device = cameraSession?.device else {
            throw EngineError.notOpen
        }
        try await device.lockForConfiguration()
        let tApply: CMTime
        do {
            tApply = await device.setWhiteBalanceModeLockedToGainsAwaitingApply(gains)
            await device.unlockForConfiguration()
        } catch {
            await device.unlockForConfiguration()
            throw error
        }
        await awaitNaturalAfter(tApply)
    }

    /// Polls until the natural-pipeline encode has produced a frame at or after the given buffer PTS.
    ///
    /// Returns immediately if `pts` is invalid (preset handler missed) or no
    /// pipeline is active. Times out at 1 s (~30 frames at 30 fps); polling
    /// tick is 8 ms. Phase-2 §2b: demoted to `internal`.
    func awaitNaturalAfter(_ pts: CMTime) async {
        guard pts.isValid, pts.isNumeric else { return }
        guard let pipeline = metalPipeline else { return }
        let targetNs = Int64(CMTimeGetSeconds(pts) * 1_000_000_000)
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if pipeline.latestNaturalPTSNs.load(ordering: .acquiring) >= targetNs {
                return
            }
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    /// Awaits `isAdjustingExposure == false` after a WB-preset apply.
    ///
    /// AE drift (often triggered by the user repointing the camera at the gray
    /// card) can move the patch's overall brightness during the sample window;
    /// gating on AE settle pins the sample to a stable exposure.
    /// Phase-2 §2b: demoted to `internal`.
    func awaitAESettled() async {
        guard let device = cameraSession?.device else { return }
        await device.awaitAESettled()
    }

    // MARK: - Phase 2 §2b — Engine-side calibration orchestration

    /// Single-shot WB calibration (Phase-2 design §2b).
    ///
    /// Switches WB to continuous auto so AVF's hardware statistics engine
    /// recomputes against the current scene, awaits convergence, reads the
    /// device's gray-world gains, clamps to `[1.0, maxGain]`, locks the device
    /// to those gains. Future iterative-loop port: see
    /// `docs/superpowers/plans/2026-05-15-wb-calibration-dart-port.md`.
    ///
    /// Concurrency contract:
    /// - **Exclusive**: a second `calibrate*()` while one is in flight throws
    ///   `EngineError.calibrationInProgress`.
    /// - **Conflict guard**: `updateSettings(...)` touching white balance and
    ///   `setResolution(...)` throw `.calibrationInProgress` while live.
    /// - **Abort on lifecycle**: `close()` and the `.interrupted` SessionState
    ///   transition cancel the in-flight task. The task's catch path returns
    ///   WB to `.auto` before propagating `CancellationError`.
    public func calibrateWhiteBalance() async throws -> CalibrationResult {
        if calibrationTask != nil { throw EngineError.calibrationInProgress }
        let task = Task<CalibrationResult, Error> { [self] in
            do {
                let before = try await sampleCenterPatchOnNatural()
                try Task.checkCancellation()
                let maxGain = try await maxWhiteBalanceGain()
                let raw = try await freshGrayWorldDeviceWBGains()
                try Task.checkCancellation()
                let gains = WhiteBalanceGains(
                    red: min(maxGain, max(1.0, raw.red)),
                    green: min(maxGain, max(1.0, raw.green)),
                    blue: min(maxGain, max(1.0, raw.blue)))
                CameraKitLog.notice(
                    .engine,
                    "[wb] calibrate start max-gain=\(maxGain) raw=(\(raw.red), \(raw.green), \(raw.blue)) clamped=(\(gains.red), \(gains.green), \(gains.blue))"
                )
                try await applyManualGainsAndAwait(gains)
                try Task.checkCancellation()
                var manual = CameraSettings()
                manual.wbMode = .manual
                manual.wbGainR = Double(gains.red)
                manual.wbGainG = Double(gains.green)
                manual.wbGainB = Double(gains.blue)
                try await _updateSettingsBypassingCalibrationGuard(manual)
                let after = try await sampleCenterPatchOnNatural()
                CameraKitLog.notice(.engine, "[wb] calibrate done")
                return CalibrationResult(
                    before: before, after: after,
                    converged: true, iterations: 1)
            } catch is CancellationError {
                // Restore WB to auto on cancel/interruption.
                var auto = CameraSettings()
                auto.wbMode = .auto
                try? await _updateSettingsBypassingCalibrationGuard(auto)
                throw CancellationError()
            }
        }
        calibrationTask = task
        defer { calibrationTask = nil }
        return try await task.value
    }

    /// Single-shot BB calibration (Phase-2 design §2b).
    ///
    /// Samples the center patch through the current BCSG with BB temporarily
    /// zeroed, computes per-channel pedestal via `CalibrationCompute.blackBalanceOffsets`,
    /// writes into `ProcessingParameters.blackR/G/B` via `setProcessingParams`.
    /// Same exclusive + abort-on-lifecycle contract as `calibrateWhiteBalance()`.
    public func calibrateBlackBalance() async throws -> CalibrationResult {
        if calibrationTask != nil { throw EngineError.calibrationInProgress }
        let task = Task<CalibrationResult, Error> { [self] in
            let beforeSample = try await sampleCenterPatchForBBCalibration()
            try Task.checkCancellation()
            let offsets = CalibrationCompute.blackBalanceOffsets(sample: beforeSample)
            let prior = currentProcessing ?? .identity
            var next = prior
            next.blackR = offsets.r
            next.blackG = offsets.g
            next.blackB = offsets.b
            await setProcessingParams(next)
            try Task.checkCancellation()
            let afterSample = try await sampleCenterPatchForBBCalibration()
            return CalibrationResult(
                before: beforeSample, after: afterSample,
                converged: true, iterations: 1)
        }
        calibrationTask = task
        defer { calibrationTask = nil }
        return try await task.value
    }

    /// Stage 04: returns the persisted ProcessingParameters without requiring
    /// an active session. Implementation per architecture/07-settings.md
    /// §Load path: "static / nonisolated accessor so the UI can pre-populate
    /// sliders before `open()`."
    public nonisolated func getPersistedProcessingParameters() -> ProcessingParameters? {
        SettingsPersistence.loadProcessing()
    }

    /// Stage 07: captures the current processed frame as a still image.
    ///
    /// If `photosDestination` is `.copy` or `.move`, the file is also
    /// published to Photos before this method returns; failures emit on
    /// `errorStream()` and the file at `output.filePath` is always preserved
    /// (even when `.move` was requested and failed). See `PhotosLibraryClient`
    /// for the full contract and known error codes.
    ///
    /// - Parameters:
    ///   - outputURL: Resolved per `PhotosLibraryClient.resolve` (default ext
    ///     `tif`). `nil` → `<Documents>/<timestamp>.tif`.
    ///   - photosDestination: See `PhotosDestination`. Independent of
    ///     `outputURL`; defaults to `.none` (no Photos interaction).
    /// - Returns: A `StillCaptureOutput` with the on-disk file path. With
    ///   `.move` and a successful Photos publish, that file no longer exists.
    /// - Throws: `EngineError.notOpen` if the engine is not open or not running.
    /// - Throws: `EngineError.invalidOutputPath(_:)` if `outputURL` resolves
    ///   outside the app sandbox.
    /// - Throws: `EngineError.capture(_:)` wrapping any `StillCaptureError`.
    public func captureImage(
        outputURL: URL? = nil,
        photosDestination: PhotosDestination = .none
    ) async throws -> StillCaptureOutput {
        guard isOpen, let pipeline = metalPipeline, let capture = stillCapture else {
            throw EngineError.notOpen
        }
        // Source the latest processed-lane BGRA8 buffer directly (no Pass-6 GPU
        // readback). Like captureNaturalPicture, gating is by buffer
        // availability rather than session-running state — capture during pause
        // returns the last delivered frame, which is the right "capture the
        // current picture" semantics.
        guard let buffer = pipeline.latestProcessedBuffer else {
            CameraKitLog.warning(.engine, "[still] no processed-lane buffer available")
            throw EngineError.capture(.bufferUnavailable)
        }
        CameraKitLog.notice(
            .engine,
            "[still] capture start size=\(pipeline.captureSize.width)x\(pipeline.captureSize.height)"
        )

        let snap = await cameraSession?.device?.lastSnapshot

        let apertureValue: Double
        if let device = cameraSession?.device {
            apertureValue = Double(await device.lensAperture)
        } else {
            apertureValue = 0
        }

        let writeURL: URL
        do {
            writeURL = try PhotosLibraryClient.resolve(outputURL: outputURL, defaultExt: "tif")
        } catch let e as EngineError {
            throw e
        }

        let output: StillCaptureOutput
        do {
            output = try await capture.encode(
                buffer: buffer,
                captureSize: pipeline.captureSize,
                deviceSnapshot: snap,
                focalLengthMm: 0,
                apertureValue: apertureValue,
                outputURL: writeURL,
                format: .tiff,
                laneTag: "processed"
            )
        } catch let e as StillCaptureError {
            throw EngineError.capture(e)
        }

        // Optional Photos publish — non-fatal; file at output.filePath is
        // preserved. Failures emit on `errorStream()` so callers can react.
        if photosDestination != .none {
            let url = URL(fileURLWithPath: output.filePath)
            do {
                try await PhotosLibraryClient.publish(
                    url: url, kind: .photo, destination: photosDestination
                )
                CameraKitLog.notice(
                    .engine,
                    "[still] published-to-photos path=\(output.filePath) destination=\(photosDestination.rawValue)"
                )
            } catch {
                let detail = PhotosLibraryClient.describe(error)
                CameraKitLog.error(
                    .engine,
                    "[still] photos publish failed (destination=\(photosDestination.rawValue)): \(detail)"
                )
                publishError(
                    CameraError(
                        code: .unknownError,
                        message: "photos publish failed (destination=\(photosDestination.rawValue)): \(detail)",
                        isFatal: false
                    )
                )
            }
        }

        return output
    }

    /// Captures the current *natural* (unprocessed) frame as a JPEG.
    ///
    /// Pre-P3 sibling of `captureImage` for the Pigeon contract's
    /// `captureNaturalPicture` method. Reads the latest natural-lane buffer
    /// from `MetalPipeline` (BGRA8, IOSurface-backed — the single delivery
    /// format), JPEG-encodes via the shared `StillCapture.encode` path, and
    /// optionally publishes to Photos. Does NOT touch `AVCapturePhotoOutput`
    /// (`DECISIONS.md` D-2P-10).
    ///
    /// EXIF carries `"lane": "natural"` inside the `CamPlugin/v1` envelope so
    /// consumers can distinguish natural-lane stills from processed-lane
    /// stills written by `captureImage` (`"lane": "processed"`).
    ///
    /// Capture during `SessionState.paused` is permitted — the mailbox still
    /// holds the last frame from before the pause, which is the right
    /// semantics for "capture the natural picture." Gating is by buffer
    /// availability, not session state.
    ///
    /// - Parameters:
    ///   - outputURL: Resolved per `PhotosLibraryClient.resolve` (default ext
    ///     `jpg`). `nil` → `<Documents>/<timestamp>.jpg`.
    ///   - photosDestination: See `PhotosDestination`. Independent of
    ///     `outputURL`; defaults to `.none` (no Photos interaction).
    /// - Returns: A `StillCaptureOutput` with the on-disk file path. With
    ///   `.move` and a successful Photos publish, that file no longer exists.
    /// - Throws: `EngineError.notOpen` if the engine is `.closed`.
    /// - Throws: `EngineError.invalidOutputPath(_:)` if `outputURL` resolves
    ///   outside the app sandbox.
    /// - Throws: `EngineError.capture(.bufferUnavailable)` if no natural-lane
    ///   frame has been delivered yet (engine just opened, no sample fired).
    /// - Throws: `EngineError.capture(_:)` wrapping any other `StillCaptureError`.
    public func captureNaturalPicture(
        outputURL: URL? = nil,
        photosDestination: PhotosDestination = .none
    ) async throws -> StillCaptureOutput {
        guard isOpen, let pipeline = metalPipeline, let capture = stillCapture else {
            throw EngineError.notOpen
        }
        // Source the latest natural-lane BGRA8 buffer — the same surface
        // delivered to the preview/bridge. The camera is 8-bit-locked, so there
        // is no half-float precision to preserve at capture; StillCapture.encode
        // consumes BGRA8 directly.
        guard let buffer = pipeline.latestNaturalBuffer else {
            CameraKitLog.warning(.engine, "[natural] no natural-lane buffer available")
            throw EngineError.capture(.bufferUnavailable)
        }
        CameraKitLog.notice(
            .engine,
            "[natural] capture start size=\(pipeline.captureSize.width)x\(pipeline.captureSize.height)"
        )

        let snap = await cameraSession?.device?.lastSnapshot
        let apertureValue: Double
        if let device = cameraSession?.device {
            apertureValue = Double(await device.lensAperture)
        } else {
            apertureValue = 0
        }

        let writeURL: URL
        do {
            writeURL = try PhotosLibraryClient.resolve(outputURL: outputURL, defaultExt: "jpg")
        } catch let e as EngineError {
            throw e
        }

        let output: StillCaptureOutput
        do {
            output = try await capture.encode(
                buffer: buffer,
                captureSize: pipeline.captureSize,
                deviceSnapshot: snap,
                focalLengthMm: 0,
                apertureValue: apertureValue,
                outputURL: writeURL,
                format: .jpeg,
                laneTag: "natural"
            )
        } catch let e as StillCaptureError {
            throw EngineError.capture(e)
        }
        CameraKitLog.notice(.engine, "[natural] capture complete path=\(output.filePath)")

        // Optional Photos publish — same non-fatal contract as captureImage.
        if photosDestination != .none {
            let url = URL(fileURLWithPath: output.filePath)
            do {
                try await PhotosLibraryClient.publish(
                    url: url, kind: .photo, destination: photosDestination
                )
                CameraKitLog.notice(
                    .engine,
                    "[natural] published-to-photos path=\(output.filePath) destination=\(photosDestination.rawValue)"
                )
            } catch {
                let detail = PhotosLibraryClient.describe(error)
                CameraKitLog.error(
                    .engine,
                    "[natural] photos publish failed (destination=\(photosDestination.rawValue)): \(detail)"
                )
                publishError(
                    CameraError(
                        code: .unknownError,
                        message: "photos publish failed (destination=\(photosDestination.rawValue)): \(detail)",
                        isFatal: false
                    )
                )
            }
        }

        return output
    }

    // MARK: - Stage 10: Recording

    private var recording: Recording?
    private nonisolated let recordingContinuationBox =
        Mutex<AsyncStream<RecordingState>.Continuation?>(nil)
    private let cachedRecordingStream = Mailbox<AsyncStream<RecordingState>>()
    private var assetWriterFactory: AssetWriterFactory = DefaultAssetWriterFactory.make

    /// Returns a stream of `RecordingState` transitions.
    ///
    /// Buffered with `.bufferingOldest` per ADR-22. Cached — multiple callers receive the same stream.
    public func recordingStateStream() -> AsyncStream<RecordingState> {
        if let s = cachedRecordingStream.latest { return s }
        let stream = AsyncStream<RecordingState>(
            RecordingState.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak self] c in
            self?.recordingContinuationBox.withLock { $0 = c }
        }
        cachedRecordingStream.store(stream)
        return stream
    }

    private func publishRecordingState(_ s: RecordingState) {
        recordingContinuationBox.withLock { $0?.yield(s) }
    }

    /// Test seam — swap the writer factory before startRecording().
    func _setAssetWriterFactoryForTest(_ f: @escaping AssetWriterFactory) {
        assetWriterFactory = f
    }

    /// Starts a recording session using the current capture pipeline.
    ///
    /// - Throws: `EngineError.notOpen` if the engine has not been opened.
    public func startRecording(options: RecordingOptions) async throws -> RecordingStart {
        guard isOpen, let session = cameraSession, let pipeline = metalPipeline else {
            throw EngineError.notOpen
        }
        CameraKitLog.notice(
            .engine,
            "[recording] startRecording entry: pipeline.isRecording=\(pipeline.isRecording.load(ordering: .acquiring)) recording==nil:\(self.recording == nil)"
        )
        try await session.setRecordingFrameRateRange()
        pipeline.onEncodedBufferReady = { [weak self] buf, pts in
            Task { [weak self] in
                await self?.onEncodedBufferReady(buf, pts: pts)
            }
        }
        let hooks = Recording.Hooks(
            publishState: { [weak self] s in
                Task { [weak self] in await self?.publishRecordingStateFromHook(s) }
            },
            emitError: { [weak self] err in
                Task { [weak self] in await self?.publishErrorAsync(err) }
            }
        )
        let rec = Recording(clock: clock, hooks: hooks, writerFactory: assetWriterFactory)
        self.recording = rec
        let start = try await rec.start(options: options, captureSize: pipeline.captureSize)
        pipeline.isRecording.store(true, ordering: .sequentiallyConsistent)
        return start
    }

    /// Stops the active recording session and returns the output file URI.
    ///
    /// If `RecordingOptions.photosDestination` was `.copy` or `.move`, the
    /// resulting `.mp4` is also published to the Photos library before this
    /// method returns. The Photos round-trip adds a few hundred ms to wall
    /// time. Failures are non-fatal: the file at `uri` is always preserved
    /// (even when `.move` was requested), and a non-fatal `CameraError` is
    /// emitted on `errorStream()`. See `PhotosLibraryClient` for the full
    /// contract and known error codes.
    ///
    /// - Returns: The on-disk URI of the recorded file. With `.move` and a
    ///   successful Photos publish, the file at this URI no longer exists —
    ///   Photos owns the bytes.
    /// - Throws: `EngineError.notOpen` if no recording is active or the engine is not open.
    public func stopRecording() async throws -> String {
        guard recording != nil,
            metalPipeline != nil,
            let session = cameraSession
        else { throw EngineError.notOpen }
        let stopStartMs = clock.nowMs()
        CameraKitLog.notice(.engine, "[recording] stopRecording entry")
        let uri = await finalizeActiveRecording(reason: .user)
        try? await session.setPreviewFrameRateRange()
        let stopDurationMs = clock.nowMs() - stopStartMs
        CameraKitLog.notice(
            .engine,
            "[recording] stopRecording exit: durationMs=\(stopDurationMs)"
        )
        return uri
    }

    /// Finalizes the active recording.
    ///
    /// Drains the writer — the drain is wrapped in a `UIApplication`
    /// background-task assertion inside `Recording.stop`,
    /// 06-capture-and-recording.md §Background drain — then optionally
    /// publishes the result to Photos. Shared by `stopRecording()`, `pause()`,
    /// and `backgroundSuspend()`, the three triggers named in the Stage 12
    /// brief. Returns the output URI, or `""` when no recording is active.
    private func finalizeActiveRecording(reason: Recording.StopReason) async -> String {
        guard let rec = recording, let pipeline = metalPipeline else { return "" }
        pipeline.isRecording.store(false, ordering: .sequentiallyConsistent)
        let uri = await rec.stop(reason: reason)
        let destination = await rec.photosDestination
        self.recording = nil
        pipeline.onEncodedBufferReady = nil

        // Optional Photos publish — runs after Recording.stop so it does not
        // pin the recording state machine. Bug-14 stop-promptness is preserved
        // for `destination == .none` (the default); for `.copy`/`.move` this
        // adds the PHPhotoLibrary roundtrip latency, which is acceptable
        // because the caller opted into Photos.
        if destination != .none, let url = URL(string: uri) {
            do {
                try await PhotosLibraryClient.publish(
                    url: url, kind: .video, destination: destination
                )
                CameraKitLog.notice(
                    .engine,
                    "[recording] published-to-photos uri=\(uri) destination=\(destination.rawValue)"
                )
            } catch {
                // Non-fatal: file is safe at outputURL. Log richly + surface
                // to the public errorStream so the caller can react.
                let detail = PhotosLibraryClient.describe(error)
                CameraKitLog.error(
                    .engine,
                    "[recording] photos publish failed (destination=\(destination.rawValue)): \(detail)"
                )
                publishError(
                    CameraError(
                        code: .unknownError,
                        message: "photos publish failed (destination=\(destination.rawValue)): \(detail)",
                        isFatal: false
                    )
                )
            }
        }
        return uri
    }

    /// Pauses capture and finalizes any active recording.
    ///
    /// The finalize runs through `Recording.stop`, whose drain is wrapped in a
    /// `UIApplication` background-task assertion (06-capture-and-recording.md
    /// §Background drain) so a concurrent backgrounding cannot truncate it
    /// into a corrupt MP4.
    public func pause() async throws {
        _ = await finalizeActiveRecording(reason: .pause)
        await cameraSession?.stopRunningAsync()
        publishState(.paused, kind: .command)
    }

    /// Resumes capture after a pause().
    ///
    /// - Throws: `EngineError.notOpen` if the engine has not been opened.
    public func resume() async throws {
        guard isOpen, let session = cameraSession else { throw EngineError.notOpen }
        await session.startRunningAsync()
        publishState(.streaming, kind: .command)
    }

    func publishRecordingStateFromHook(_ s: RecordingState) {
        publishRecordingState(s)
    }

    func onEncodedBufferReady(_ buffer: CVPixelBuffer, pts: CMTime) async {
        guard let rec = recording else { return }
        _ = await rec.submitEncodedBuffer(buffer, pts: pts)
    }

    // MARK: - Internal helpers (accessible via @testable import)

    /// Sets the GPU submission gate (ADR-09, D-06).
    /// `.inactive` policy is strict — always gates, regardless of UIApplication state.
    public func setGate(_ open: Bool) {
        submissionGate.store(open, ordering: .sequentiallyConsistent)
    }

    /// Waits for the most recently committed command buffer to be scheduled.
    ///
    /// Bounds the drain window to FRAME_LATENCY_BUDGET_MS (ADR-09).
    /// No-op if no buffer has been committed yet this session.
    public func drainSubmittedFrame() async {
        metalPipeline?.drainLastBuffer()
    }

    /// Internal accessor for gate state — used by Stage02Tests.
    var isGateOpen: Bool {
        submissionGate.load(ordering: .acquiring)
    }

    // MARK: - Private helpers

    private func publishState(
        _ state: SessionState,
        kind: SessionStateMachine.Kind,
        function: String = #function
    ) {
        let from = stateMachine.current
        let classification = stateMachine.transition(to: state, kind: kind)
        if classification == .offMap {
            // Observability-first: log with full context, then apply. Off-map is
            // NOT fatal in any config — the OS event space (interruptions,
            // runtime errors, system-pressure orderings) is not fully
            // enumerable, and a DEBUG-only `assertionFailure` here aborted device
            // builds on legitimate-but-rare lifecycle races while RELEASE handled
            // the same transition gracefully (measurements 2026-05-20 §1: the
            // DEBUG/RELEASE divergence was itself the bug-amplifier). The log is
            // the diagnostic instrument; correlate an off-map entry with the
            // preceding OS notification to tell a legitimate ordering from a
            // genuine state-logic regression.
            CameraKitLog.warning(
                .engine,
                "[state] off-map transition from=\(from.rawValue) "
                    + "to=\(state.rawValue) kind=\(kind.rawValue) caller=\(function)"
            )
        }
        stateContinuationBox.withLock { $0?.yield(state) }
    }

    // MARK: - Stage 09 internal hooks

    /// Used by `RecoveryCoordinator.emitStateRecovering` — that hook always
    /// fires in response to an OS-driven recovery trigger, hence `.event`.
    func publishStateAsync(_ s: SessionState) {
        publishState(s, kind: .event)
    }
    func publishErrorAsync(_ e: CameraError) { publishError(e) }
    func disarmWatchdogsAsync() { watchdogs?.disarmAll() }

    /// Arm both stall watchdogs against the current session token.
    ///
    /// `Watchdog.arm` is self-canceling (it cancels any prior poller), so this
    /// is safe to call to (re-)arm on `open()`, on `backgroundResume()`, and on
    /// `.otherInterruptionEnded`. No-op when the engine is closed
    /// (`watchdogs == nil`).
    ///
    /// Gate-guarded: if `submissionGate` is closed, arming is skipped (HITL
    /// 2026-05-20 §1 case #14). On backgrounding, `stopRunning` triggers an OS
    /// interruption whose `.otherInterruptionEnded` fires while the app is still
    /// backgrounded; the unconditional re-arm armed the stall watchdog with no
    /// frames flowing, it fired ~9 s later, and drove `interrupted → recovering`
    /// (off-map — it aborted DEBUG builds before Fix 2, and still spuriously
    /// recovers a backgrounded session). The watchdog must only arm when frames
    /// can actually flow, which the gate tracks. `open()` and `backgroundResume()`
    /// both open the gate before calling this, so they are unaffected.
    private func armWatchdogs() {
        guard let pair = watchdogs else { return }
        guard submissionGate.load(ordering: .acquiring) else {
            CameraKitLog.notice(
                .engine, "[watchdog] arm skipped — submission gate closed (HITL §1 #14)")
            return
        }
        let token = sessionToken.load(ordering: .acquiring)
        pair.gpu.arm(sessionToken: token)
        pair.capture.arm(sessionToken: token)
    }

    private func startAEMonitor(device: any CaptureDeviceProviding) {
        aeMonitorTask?.cancel()
        let clock = self.clock
        let tokenAtStart = sessionToken.load(ordering: .acquiring)
        aeMonitorTask = Task { [weak self] in
            var searchStartMs: UInt64?
            for await snap in device.snapshotStream() {
                if Task.isCancelled { return }
                if snap.isAdjustingExposure {
                    if searchStartMs == nil { searchStartMs = clock.nowMs() }
                } else {
                    searchStartMs = nil
                }
                if let start = searchStartMs,
                    clock.nowMs() >= start + UInt64(Constants.aeConvergenceTimeoutMs)
                {
                    guard let self,
                        self.sessionToken.load(ordering: .acquiring) == tokenAtStart
                    else { return }
                    let err = CameraError(
                        code: .aeConvergenceTimeout,
                        message: "AE searching > \(Constants.aeConvergenceTimeoutMs)ms",
                        isFatal: false
                    )
                    await self.publishErrorAsync(err)
                    searchStartMs = nil
                }
            }
        }
    }

    func handleWatchdogFire(_ fire: WatchdogFire) async {
        let liveToken = sessionToken.load(ordering: .acquiring)
        guard fire.armedSessionToken == liveToken else { return }
        let msg = "\(fire.kind.messagePrefix) no frame in \(fire.thresholdMs)ms"
        let err = CameraError(code: .frameStall, message: msg, isFatal: false)
        publishError(err)
        if fire.kind == .capture {
            await recovery?.enterRecovery(error: err)
        }
    }

    func noteCaptureFailure(message: String) async {
        await recovery?.noteHardwareFailure(message: message)
    }

    func noteFrameDelivered() async {
        let now = clock.nowMs()
        if fpsWindowStartMs == 0 {
            fpsWindowStartMs = now
            fpsFrameCount = 1
            return
        }
        fpsFrameCount += 1
        if fpsFrameCount >= Constants.fpsMeasurementWindowFrames {
            let elapsedMs = max(1, now - fpsWindowStartMs)
            let fps = Double(fpsFrameCount) * 1000.0 / Double(elapsedMs)
            let expectedFps: Double
            if currentSettings?.exposureMode == .manual,
                let expNs = currentSettings?.exposureTimeNs, expNs > 0
            {
                expectedFps = min(1_000_000_000.0 / Double(expNs), Double(Constants.frameRateTargetFPS))
            } else {
                expectedFps = Double(Constants.frameRateTargetFPS)
            }
            let degradedThreshold = expectedFps * Constants.fpsDegradedFraction
            if fps < degradedThreshold {
                fpsLowStreak += 1
                if fpsLowStreak >= Constants.fpsDegradedStreakCount {
                    publishError(
                        CameraError(
                            code: .fpsDegraded,
                            message: String(
                                format: "%.1f fps over %d-frame window", fps, Constants.fpsMeasurementWindowFrames),
                            isFatal: false
                        ))
                    fpsLowStreak = 0
                }
            } else {
                fpsLowStreak = 0
            }
            fpsWindowStartMs = now
            fpsFrameCount = 0
        }
        await recovery?.noteHardwareSuccess()
    }

    func resetFromTerminal() async {
        await close()
    }

    func onSessionEvent(_ event: CameraSession.SessionEvent) async {
        switch event {
        case .cameraInUseBegan:
            let err = CameraError(
                code: .cameraInUse,
                message: "videoDeviceInUseByAnotherClient",
                isFatal: true
            )
            watchdogs?.disarmAll()
            await recovery?.cancelPendingRetry()
            publishError(err)
            publishState(.error, kind: .event)
        case .cameraInUseEnded:
            // D-14 + OQ-04: return to .closed; host must call open() again.
            await resetFromTerminal()
        case .runtimeError(let msg):
            let err = CameraError(code: .cameraAccessError, message: msg, isFatal: false)
            publishError(err)
            await recovery?.enterRecovery(error: err)
        case .otherInterruption(let raw):
            CameraKitLog.notice(
                .engine, "[interruption] entering .interrupted (raw=\(raw))")
            // Phase-2 §2b — abort any in-flight calibration on .interrupted.
            calibrationTask?.cancel()
            // HITL crash fix (measurements 2026-05-20 §1): the OS stopped frame
            // delivery, so the stall watchdogs would fire spuriously and drive
            // recovery — interrupted → recovering is off-map (it aborted DEBUG
            // builds before Fix 2; still a spurious recovery). Disarm them and
            // cancel any pending retry (mirror of the .cameraInUseBegan path);
            // re-armed on .otherInterruptionEnded only when the gate is open.
            watchdogs?.disarmAll()
            await recovery?.cancelPendingRetry()
            publishState(.interrupted, kind: .event)
        case .otherInterruptionEnded:
            CameraKitLog.notice(
                .engine, "[interruption] ended — reverting to .streaming")
            publishState(.streaming, kind: .event)
            // Frames resume — re-arm the watchdogs disarmed on .otherInterruption.
            armWatchdogs()
        }
    }

    /// Test-only: inject a session event directly (avoids needing avSession reference).
    func _postSessionEventForTest(_ event: CameraSession.SessionEvent) async {
        await onSessionEvent(event)
    }

    /// Test-only: armed token of the capture stall watchdog (nil when disarmed).
    ///
    /// Lets a test observe disarm-on-interruption / re-arm-on-resume directly.
    var _captureWatchdogArmedTokenForTest: UInt64? { watchdogs?.capture.armedSessionToken }

    /// Test-only: build and arm the stall watchdogs + recovery coordinator the
    /// way `open()` does, without a real `AVCaptureSession`.
    ///
    /// Exercises the lifecycle disarm/re-arm paths and the watchdog→recovery
    /// wiring under an injected clock. `performTeardownAndReopen` is a no-op —
    /// these tests assert that recovery is NOT spuriously triggered on the
    /// interrupted / background path.
    func _armWatchdogsForTest() {
        let gpu = Watchdog(kind: .gpu, clock: clock) { [weak self] fire in
            Task { [weak self] in await self?.handleWatchdogFire(fire) }
        }
        let cap = Watchdog(kind: .capture, clock: clock) { [weak self] fire in
            Task { [weak self] in await self?.handleWatchdogFire(fire) }
        }
        let pair = WatchdogPair(gpu: gpu, capture: cap)
        self.watchdogs = pair
        self.recovery = RecoveryCoordinator(
            clock: clock,
            hooks: RecoveryCoordinator.Hooks(
                performTeardownAndReopen: {},
                emitStateRecovering: { [weak self] in await self?.publishStateAsync(.recovering) },
                emitError: { [weak self] err in await self?.publishErrorAsync(err) },
                disarmWatchdogs: { [weak self] in await self?.disarmWatchdogsAsync() },
                incrementSessionToken: { [weak self] in
                    self?.sessionToken.wrappingIncrement(ordering: .sequentiallyConsistent)
                }
            )
        )
        armWatchdogs()
    }
}
