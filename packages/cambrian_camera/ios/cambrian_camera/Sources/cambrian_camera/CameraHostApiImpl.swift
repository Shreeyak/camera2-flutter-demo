import CameraKit
import Flutter
import Foundation

/// Pigeon `CameraHostApi` impl — the bridge between Dart calls and
/// `CameraEngine`. Every method translates the Pigeon-level inputs through
/// `PigeonValueMapping`, dispatches to the engine, and surfaces the result
/// (or a mapped `PigeonError`) back through the wire.
///
/// ## Threading
///
/// Pigeon dispatches each call on the binary-messenger queue. Async work is
/// performed in detached `Task`s so the Pigeon completion handler can be
/// invoked from any context. `statesLock` (NSLock) guards `states`;
/// `openInFlightLock` guards `openInFlight`. `HandleRegistry` is itself an
/// actor and self-serializes.
final class CameraHostApiImpl: CameraHostApi {

    // MARK: - Dependencies

    private let registry: HandleRegistry
    private let textureRegistry: FlutterTextureRegistry
    private let flutterApi: CameraFlutterApi

    // MARK: - Per-handle state

    /// Map of open handles → their backing state. Keyed by the same `Int64`
    /// `HandleRegistry` issues. Guarded by `statesLock`.
    private var states: [Int64: CameraHandleState] = [:]
    private let statesLock = NSLock()

    // MARK: - Open-in-flight guard

    /// Impl-edge single-engine open guard (D-2P decisions §). A second
    /// concurrent `open()` while the first is still resolving fails fast
    /// with `open_in_flight`. Plain `Bool` + `NSLock` rather than an actor
    /// — the critical sections are O(1) and the guard never `await`s.
    private var openInFlight: Bool = false
    private let openInFlightLock = NSLock()

    // MARK: - Initialization

    init(
        registry: HandleRegistry,
        textureRegistry: FlutterTextureRegistry,
        flutterApi: CameraFlutterApi
    ) {
        self.registry = registry
        self.textureRegistry = textureRegistry
        self.flutterApi = flutterApi
    }

    // MARK: - open

    /// Opens a new camera session and returns a handle.
    ///
    /// Construction order matters: register the handle BEFORE constructing
    /// the pump so the pump's per-task closures bake in the real handle
    /// rather than a placeholder. Texture IDs are minted between engine open
    /// and pump construction; they're independent of the handle.
    func open(
        cameraId: String?,
        settings: CamSettings?,
        completion: @escaping (Result<Int64, Error>) -> Void
    ) {
        // 1. Impl-edge open-in-flight guard.
        openInFlightLock.lock()
        if openInFlight {
            openInFlightLock.unlock()
            completion(.failure(PigeonError(
                code: "open_in_flight",
                message: "open() is already in flight",
                details: nil
            )))
            return
        }
        openInFlight = true
        openInFlightLock.unlock()

        // Hoist locals so the Task doesn't capture `self` strongly — mirrors
        // `CameraLaneBridge.start()` (CameraLaneBridge.swift:78-95).
        let registry = self.registry
        let textureRegistry = self.textureRegistry
        let flutterApi = self.flutterApi

        Task { [weak self] in
            defer {
                // Reset the in-flight flag whether we succeeded or threw.
                self?.openInFlightLock.lock()
                self?.openInFlight = false
                self?.openInFlightLock.unlock()
            }

            do {
                // 2. Construct engine + OpenConfiguration.
                // Seed the engine with the app's ACTUAL current lifecycle phase:
                // `open()` reconciles hardware against this phase (CameraKit
                // `CameraEngine.open` step 9b), and opening into `.background`
                // skips `startRunning`. The scene-delegate observer only forwards
                // subsequent *transitions*, so a blind `.background` here would
                // leave the camera open-but-not-streaming when the app is already
                // foreground at open() (the common case). Reading the real phase
                // streams when foreground and stays gated when not — preserving
                // the README's privacy guarantee without its streaming gap.
                let initialPhase = await LifecycleObserver.currentPhase()
                let engine = CameraEngine(initialPhase: initialPhase)

                // Hardcoded capture resolution per Plan 2 — matches the
                // natural-stream default the rest of the pipeline assumes.
                let captureW = 4032
                let captureH = 3024
                let cropRegion: Rect? = settings?.cropOutputSize.map { cs in
                    let cw = Int(cs.width)
                    let ch = Int(cs.height)
                    // Centered crop: caller specifies width/height; we
                    // compute the offset relative to the full capture frame.
                    return Rect(
                        x: (captureW - cw) / 2,
                        y: (captureH - ch) / 2,
                        width: cw,
                        height: ch
                    )
                }
                let initialSettings: CameraSettings? = settings.map {
                    PigeonValueMapping.toCameraSettings($0)
                }
                let config = OpenConfiguration(
                    cameraId: cameraId,
                    captureResolution: Size(width: captureW, height: captureH),
                    cropRegion: cropRegion,
                    initialSettings: initialSettings
                    // `lanesEightBit` defaults to true (BGRA8) — matches the
                    // Phase-3 zero-copy wire format on the Flutter side.
                )

                // 3. Open the engine. Throws on permission/hardware errors.
                let capabilities = try await engine.open(configuration: config)

                // 4. Register the handle FIRST so the pump can be constructed
                //    with the real handle baked into its per-task captures.
                let handle = await registry.register(engine)

                // 5. Mint two texture IDs. Texture registration is independent
                //    of the handle; FlutterTextureRegistry assigns its own IDs.
                let naturalTexture = CameraLaneTexture(engine: engine, stream: .natural)
                let processedTexture = CameraLaneTexture(engine: engine, stream: .processed)
                let naturalId = await MainActor.run {
                    textureRegistry.register(naturalTexture)
                }
                let previewId = await MainActor.run {
                    textureRegistry.register(processedTexture)
                }

                // 6. Construct pump + bridges with the real handle and IDs.
                let pump = FlutterApiPump(
                    handle: handle,
                    engine: engine,
                    flutterApi: flutterApi,
                    textureIds: { (natural: naturalId, preview: previewId) }
                )
                let naturalBridge = CameraLaneBridge(
                    textureRegistry: textureRegistry,
                    textureId: naturalId,
                    engine: engine,
                    stream: .natural
                )
                let processedBridge = CameraLaneBridge(
                    textureRegistry: textureRegistry,
                    textureId: previewId,
                    engine: engine,
                    stream: .processed
                )

                // 7. Build state, store under lock.
                let state = CameraHandleState(
                    engine: engine,
                    capabilities: capabilities,
                    naturalTextureId: naturalId,
                    previewTextureId: previewId,
                    pump: pump,
                    naturalBridge: naturalBridge,
                    processedBridge: processedBridge
                )
                self?.storeState(state, for: handle)

                // 8. Start pump + bridges AFTER state is stored so any
                //    immediate stream event finds the state available.
                pump.start()
                naturalBridge.start()
                processedBridge.start()

                completion(.success(handle))
            } catch let e as EngineError {
                completion(.failure(Self.mapEngineError(e)))
            } catch {
                completion(.failure(PigeonError(
                    code: "open_failed",
                    message: String(describing: error),
                    details: nil
                )))
            }
        }
    }

    // MARK: - close

    /// Minimal close — sufficient for the open → close → open round-trip
    /// test path. Subsequent tasks (E-series) flesh out the rest of the
    /// HostApi methods that need access to per-handle state.
    func close(
        handle: Int64,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let registry = self.registry
        Task { [weak self] in
            // 1. Unregister handle in the registry FIRST so any concurrent
            //    method call resolving the same handle fails fast.
            await registry.unregister(handle)

            // 2. Yank state.
            guard let state = self?.takeState(for: handle) else {
                // Idempotent close — unknown / already-closed handle.
                completion(.success(()))
                return
            }

            // 3. Stop pump + bridges (bridges also unregister textures from
            //    FlutterTextureRegistry).
            await state.stopBridgesAndPump()

            // 4. Close engine.
            await state.engine.close()

            completion(.success(()))
        }
    }

    // MARK: - Not-yet-implemented stubs (filled in by later tasks)

    /// Returns the `SessionCapabilities` cached at `open()` time, repackaged
    /// as the wire-level `CamCapabilities` and decorated with the natural-lane
    /// texture ID minted by the texture bridge. Capabilities are immutable
    /// for the lifetime of an open session, so we never need to refetch from
    /// the engine.
    func getCapabilities(
        handle: Int64,
        completion: @escaping (Result<CamCapabilities, Error>) -> Void
    ) {
        guard let state = resolveState(for: handle) else {
            completion(.failure(Self.handleNotFound(handle)))
            return
        }
        let payload = PigeonValueMapping.toCamCapabilities(
            state.capabilities,
            naturalTextureId: state.naturalTextureId,
            previewTextureId: state.previewTextureId
        )
        completion(.success(payload))
    }

    /// Applies a settings delta to the engine. Pigeon signature is
    /// synchronous-throws so the call blocks on the engine's async
    /// `updateSettings(_:)` via `runAsyncBlocking` (see helper docs).
    ///
    /// If `settings.cropOutputSize` is set, the crop is applied FIRST via
    /// `engine.setCropRegion(_:)` — spec §5 ordering recommendation. Doing it
    /// first means a subsequent `updateSettings` failure (e.g.
    /// `calibrationInProgress`) leaves the crop already committed, matching
    /// the documented partial-commit behavior.
    func updateSettings(handle: Int64, settings: CamSettings) throws {
        guard let state = resolveState(for: handle) else {
            throw Self.handleNotFound(handle)
        }

        let pigeonError: Error? = runAsyncBlocking { () -> Error? in
            do {
                if let cropSize = settings.cropOutputSize {
                    // Centered crop within the active capture frame. The
                    // caller specifies width/height only; offset is derived
                    // here so the crop is symmetric around the sensor center.
                    let captureW = state.capabilities.activeCaptureResolution.width
                    let captureH = state.capabilities.activeCaptureResolution.height
                    let cw = Int(cropSize.width)
                    let ch = Int(cropSize.height)
                    let crop = Rect(
                        x: (captureW - cw) / 2,
                        y: (captureH - ch) / 2,
                        width: cw,
                        height: ch
                    )
                    try await state.engine.setCropRegion(crop)
                }
                let engineSettings = PigeonValueMapping.toCameraSettings(settings)
                try await state.engine.updateSettings(engineSettings)
                return nil
            } catch let e as EngineError {
                return Self.mapEngineError(e)
            } catch {
                return PigeonError(
                    code: "update_settings_failed",
                    message: String(describing: error),
                    details: nil
                )
            }
        }
        if let pigeonError {
            throw pigeonError
        }
    }

    /// Restarts the capture session at the requested resolution. Completion-
    /// based on the Pigeon side, so this is a clean async-to-completion
    /// adapter — no semaphore needed.
    func setResolution(
        handle: Int64, width: Int64, height: Int64,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let state = resolveState(for: handle) else {
            completion(.failure(Self.handleNotFound(handle)))
            return
        }
        Task {
            do {
                try await state.engine.setResolution(
                    size: Size(width: Int(width), height: Int(height))
                )
                completion(.success(()))
            } catch let e as EngineError {
                completion(.failure(Self.mapEngineError(e)))
            } catch {
                completion(.failure(PigeonError(
                    code: "set_resolution_failed",
                    message: String(describing: error),
                    details: nil
                )))
            }
        }
    }

    /// Wholesale replacement of color-grading uniforms (engine's
    /// `setProcessingParams(_:)` is non-throwing). Pigeon signature is
    /// synchronous so we block on a one-shot semaphore. We don't use
    /// `runAsyncBlocking` here because the engine method returns Void —
    /// avoiding type-inference noise around `T = Void` keeps the call site
    /// simpler.
    func setProcessingParams(handle: Int64, params: CamProcessingParams) throws {
        guard let state = resolveState(for: handle) else {
            throw Self.handleNotFound(handle)
        }
        let engineParams = PigeonValueMapping.toProcessingParameters(params)
        let sem = DispatchSemaphore(value: 0)
        Task {
            await state.engine.setProcessingParams(engineParams)
            sem.signal()
        }
        sem.wait()
    }

    /// Captures the next GPU-processed frame as a JPEG.
    ///
    /// ## Wire contract (which `CamCaptureResult` field is populated)
    ///
    /// - `destination?.saveToLibrary == true`
    ///   → publishes to Photos, returns `filePath: nil, phAssetLocalId: <id>`.
    ///   The on-disk file written by the engine is deleted after the
    ///   successful Photos publish (the contract says `filePath` is null
    ///   when saved to the library).
    /// - `destination == nil` or `saveToLibrary == false`
    ///   → no Photos interaction, returns `filePath: <path>, phAssetLocalId: nil`.
    ///
    /// We always pass `photosDestination: .none` to the engine. The engine
    /// can publish to Photos itself but does NOT surface the PHAsset's
    /// `localIdentifier`, so the plugin owns the publish path to capture it.
    func captureImage(
        handle: Int64, outputDirectory: String?, fileName: String?,
        destination: CamPhotosDestination?,
        completion: @escaping (Result<CamCaptureResult, Error>) -> Void
    ) {
        guard let state = resolveState(for: handle) else {
            completion(.failure(Self.handleNotFound(handle)))
            return
        }
        let saveToLibrary = destination?.saveToLibrary == true
        Task {
            do {
                let url = Self.buildOutputURL(
                    directory: outputDirectory,
                    fileName: fileName,
                    defaultPrefix: "IMG",
                    defaultExt: "jpg"
                )
                // Engine writes the file but does NOT publish — plugin owns
                // the Photos path so it can capture phAssetLocalId.
                let output = try await state.engine.captureImage(
                    outputURL: url,
                    photosDestination: .none
                )
                let result = try await Self.finishStill(
                    output: output, saveToLibrary: saveToLibrary
                )
                completion(.success(result))
            } catch let e as EngineError {
                completion(.failure(Self.mapEngineError(e)))
            } catch let e as PhotosPublisher.PublishError {
                completion(.failure(PigeonError(
                    code: "photos_publish_failed",
                    message: String(describing: e),
                    details: nil
                )))
            } catch {
                completion(.failure(PigeonError(
                    code: "capture_failed",
                    message: String(describing: error),
                    details: nil
                )))
            }
        }
    }

    /// Captures the current natural-lane (un-processed) frame as a JPEG.
    ///
    /// ## Wire contract (which `CamCaptureResult` field is populated)
    ///
    /// Identical to `captureImage`:
    /// - `destination?.saveToLibrary == true`
    ///   → publishes to Photos, returns `filePath: nil, phAssetLocalId: <id>`;
    ///   on-disk file is deleted after publish.
    /// - `destination == nil` or `saveToLibrary == false`
    ///   → returns `filePath: <path>, phAssetLocalId: nil`.
    ///
    /// Engine is invoked with `photosDestination: .none` — see `captureImage`
    /// for the rationale (engine can publish but never surfaces the asset's
    /// local identifier).
    func captureNaturalPicture(
        handle: Int64, outputDirectory: String?, fileName: String?,
        destination: CamPhotosDestination?,
        completion: @escaping (Result<CamCaptureResult, Error>) -> Void
    ) {
        guard let state = resolveState(for: handle) else {
            completion(.failure(Self.handleNotFound(handle)))
            return
        }
        let saveToLibrary = destination?.saveToLibrary == true
        Task {
            do {
                let url = Self.buildOutputURL(
                    directory: outputDirectory,
                    fileName: fileName,
                    defaultPrefix: "NAT",
                    defaultExt: "jpg"
                )
                let output = try await state.engine.captureNaturalPicture(
                    outputURL: url,
                    photosDestination: .none
                )
                let result = try await Self.finishStill(
                    output: output, saveToLibrary: saveToLibrary
                )
                completion(.success(result))
            } catch let e as EngineError {
                completion(.failure(Self.mapEngineError(e)))
            } catch let e as PhotosPublisher.PublishError {
                completion(.failure(PigeonError(
                    code: "photos_publish_failed",
                    message: String(describing: e),
                    details: nil
                )))
            } catch {
                completion(.failure(PigeonError(
                    code: "capture_failed",
                    message: String(describing: error),
                    details: nil
                )))
            }
        }
    }

    /// Returns the C++ pipeline handle (an opaque pointer-shaped integer) for
    /// FFI consumers that subscribe directly to the engine's pixel sink pool.
    /// `UInt64?` on the engine side is reinterpreted to `Int64?` via
    /// `Int64(bitPattern:)` (spec §3) so the wire-level type matches Dart's
    /// platform-neutral integer.
    func getNativePipelineHandle(
        handle: Int64,
        completion: @escaping (Result<Int64?, Error>) -> Void
    ) {
        guard let state = resolveState(for: handle) else {
            completion(.failure(Self.handleNotFound(handle)))
            return
        }
        Task {
            let raw: UInt64? = await state.engine.getNativePipelineHandle()
            let mapped: Int64? = raw.map { Int64(bitPattern: $0) }
            completion(.success(mapped))
        }
    }

    /// Starts a recording session. Returns the on-disk file path to which
    /// frames will be written. Photos publishing is not exposed on the
    /// Pigeon contract for recording — the file lives on disk only.
    func startRecording(
        handle: Int64, outputDirectory: String?, fileName: String?,
        bitrate: Int64?, fps: Int64?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let state = resolveState(for: handle) else {
            completion(.failure(Self.handleNotFound(handle)))
            return
        }
        let url = Self.buildOutputURL(
            directory: outputDirectory,
            fileName: fileName,
            defaultPrefix: "VID",
            defaultExt: "mp4"
        )
        let options = RecordingOptions(
            bitrateBps: bitrate.map { Int($0) },
            fps: fps.map { Int($0) },
            outputURL: url,
            photosDestination: .none
        )
        Task {
            do {
                let start = try await state.engine.startRecording(options: options)
                completion(.success(start.uri))
            } catch let e as EngineError {
                completion(.failure(Self.mapEngineError(e)))
            } catch {
                completion(.failure(PigeonError(
                    code: "recording_start_failed",
                    message: String(describing: error),
                    details: nil
                )))
            }
        }
    }

    /// Stops the active recording and returns the final on-disk file path.
    func stopRecording(
        handle: Int64,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let state = resolveState(for: handle) else {
            completion(.failure(Self.handleNotFound(handle)))
            return
        }
        Task {
            do {
                let uri = try await state.engine.stopRecording()
                completion(.success(uri))
            } catch let e as EngineError {
                completion(.failure(Self.mapEngineError(e)))
            } catch {
                completion(.failure(PigeonError(
                    code: "recording_stop_failed",
                    message: String(describing: error),
                    details: nil
                )))
            }
        }
    }

    /// Returns persisted `ProcessingParameters` from a prior session, or nil
    /// if no values have been persisted yet. The engine's accessor is
    /// `nonisolated` (read-only) so no `async` is needed.
    func getPersistedProcessingParams(handle: Int64) throws -> CamProcessingParams? {
        guard let state = resolveState(for: handle) else {
            throw Self.handleNotFound(handle)
        }
        guard let persisted = state.engine.getPersistedProcessingParameters() else {
            return nil
        }
        return PigeonValueMapping.toCamProcessingParams(persisted)
    }

    /// Samples the GPU-processed lane's center patch and returns
    /// trimmed-mean R/G/B in [0, 1].
    func sampleCenterPatch(
        handle: Int64,
        completion: @escaping (Result<CamRgbSample, Error>) -> Void
    ) {
        guard let state = resolveState(for: handle) else {
            completion(.failure(Self.handleNotFound(handle)))
            return
        }
        Task {
            do {
                let sample = try await state.engine.sampleCenterPatch()
                completion(.success(PigeonValueMapping.toCamRgbSample(sample)))
            } catch let e as EngineError {
                completion(.failure(Self.mapEngineError(e)))
            } catch {
                completion(.failure(PigeonError(
                    code: "sample_failed",
                    message: String(describing: error),
                    details: nil
                )))
            }
        }
    }

    /// Runs the engine's single-shot gray-world white-balance calibration
    /// and returns the engine's `CalibrationResult` adapted into the
    /// Pigeon `CamCalibrationResult`, with the committed gains read from
    /// `engine.currentSettingsSnapshot()` so Dart consumers can re-apply
    /// them to manual mode without losing the calibration.
    ///
    /// Phase-3 spec §6 fallback shape — the iOS-only Pigeon-file
    /// approach was abandoned after Pigeon 22's per-file Swift output
    /// produced unavoidable module-level `PigeonError` / `CamRgbSample`
    /// redeclarations; the methods now live on the shared `CameraHostApi`,
    /// with the Android Kotlin plugin throwing `not_implemented`.
    ///
    /// ## Two-await snapshot read
    ///
    /// The calibration call and the snapshot read are separate actor
    /// hops. Between them another caller could in principle invoke
    /// `updateSettings(wbMode: .auto)` and clear the just-committed
    /// gains; the snapshot would then report nil, and the Dart-side
    /// `?? 1.0` fallback would surface as a silent calibration miss.
    /// In practice every caller `await`s the calibration before
    /// issuing the next host call, so the window is unreachable. If a
    /// concurrent caller is ever added, return both values from a
    /// single engine entry point instead of reading two snapshots.
    func calibrateWhiteBalance(
        handle: Int64,
        completion: @escaping (Result<CamCalibrationResult, Error>) -> Void
    ) {
        guard let state = resolveState(for: handle) else {
            completion(.failure(Self.handleNotFound(handle)))
            return
        }
        Task {
            do {
                let result = try await state.engine.calibrateWhiteBalance()
                // Read the gains the engine just committed so the Dart
                // caller can populate `WbCalibrationResult.gains` and
                // re-apply them via `WhiteBalance.manual(...)` without
                // overwriting them with sentinels. See engine field
                // `currentSettings` (CameraEngine.swift §"currentSettingsSnapshot()").
                let snapshot = await state.engine.currentSettingsSnapshot()
                completion(.success(CamCalibrationResult(
                    before: PigeonValueMapping.toCamRgbSample(result.before),
                    after: PigeonValueMapping.toCamRgbSample(result.after),
                    converged: result.converged,
                    iterations: Int64(result.iterations),
                    gainR: snapshot?.wbGainR,
                    gainG: snapshot?.wbGainG,
                    gainB: snapshot?.wbGainB,
                    blackR: nil,
                    blackG: nil,
                    blackB: nil
                )))
            } catch is CancellationError {
                completion(.failure(PigeonError(
                    code: "cancelled",
                    message: "Calibration cancelled",
                    details: nil
                )))
            } catch let e as EngineError {
                completion(.failure(Self.mapEngineError(e)))
            } catch {
                completion(.failure(PigeonError(
                    code: "unknown",
                    message: error.localizedDescription,
                    details: nil
                )))
            }
        }
    }

    /// Runs the engine's single-shot black-balance calibration and
    /// returns the result with the committed black-level offsets read
    /// from `engine.currentProcessingParametersSnapshot()` (symmetric
    /// with `calibrateWhiteBalance` above).
    func calibrateBlackBalance(
        handle: Int64,
        completion: @escaping (Result<CamCalibrationResult, Error>) -> Void
    ) {
        guard let state = resolveState(for: handle) else {
            completion(.failure(Self.handleNotFound(handle)))
            return
        }
        Task {
            do {
                let result = try await state.engine.calibrateBlackBalance()
                let snapshot = await state.engine.currentProcessingParametersSnapshot()
                completion(.success(CamCalibrationResult(
                    before: PigeonValueMapping.toCamRgbSample(result.before),
                    after: PigeonValueMapping.toCamRgbSample(result.after),
                    converged: result.converged,
                    iterations: Int64(result.iterations),
                    gainR: nil,
                    gainG: nil,
                    gainB: nil,
                    blackR: snapshot?.blackR,
                    blackG: snapshot?.blackG,
                    blackB: snapshot?.blackB
                )))
            } catch is CancellationError {
                completion(.failure(PigeonError(
                    code: "cancelled",
                    message: "Calibration cancelled",
                    details: nil
                )))
            } catch let e as EngineError {
                completion(.failure(Self.mapEngineError(e)))
            } catch {
                completion(.failure(PigeonError(
                    code: "unknown",
                    message: error.localizedDescription,
                    details: nil
                )))
            }
        }
    }

    /// §5.6 — Camera permission status. Routes to the engine's
    /// `nonisolated static` helper so the Dart side can query before an
    /// engine handle exists.
    func cameraPermissionStatus(completion: @escaping (Result<String, Error>) -> Void) {
        let status = CameraEngine.cameraPermissionStatus()
        completion(.success(PigeonValueMapping.toCamPermissionStatus(status)))
    }

    /// §5.6 — Triggers the system Camera permission prompt; resolves to the
    /// status after the prompt.
    func requestCameraPermission(completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            let status = await CameraEngine.requestCameraPermission()
            completion(.success(PigeonValueMapping.toCamPermissionStatus(status)))
        }
    }

    /// §5.6 — Photos add-only permission status.
    func photosAddPermissionStatus(completion: @escaping (Result<String, Error>) -> Void) {
        let status = CameraEngine.photosAddPermissionStatus()
        completion(.success(PigeonValueMapping.toCamPermissionStatus(status)))
    }

    /// §5.6 — Triggers the system Photos add-only permission prompt.
    func requestPhotosAddPermission(completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            let status = await CameraEngine.requestPhotosAddPermission()
            completion(.success(PigeonValueMapping.toCamPermissionStatus(status)))
        }
    }

    // MARK: - Private helpers

    /// Stores per-handle state under `statesLock`. Pulled out as a method
    /// so the `Task`-closure call site doesn't need to capture `self`
    /// strongly just to access the lock.
    private func storeState(_ state: CameraHandleState, for handle: Int64) {
        statesLock.lock()
        states[handle] = state
        statesLock.unlock()
    }

    /// Removes and returns per-handle state under `statesLock`. Returns nil
    /// if the handle is unknown / already closed.
    private func takeState(for handle: Int64) -> CameraHandleState? {
        statesLock.lock()
        defer { statesLock.unlock() }
        return states.removeValue(forKey: handle)
    }

    /// Looks up per-handle state under `statesLock` without mutating the map.
    /// Returns nil when the handle is unknown.
    private func resolveState(for handle: Int64) -> CameraHandleState? {
        statesLock.lock()
        defer { statesLock.unlock() }
        return states[handle]
    }

    /// Builds an absolute URL for a still-capture output file.
    ///
    /// Mirrors the engine's `PhotosLibraryClient.resolve` semantics but
    /// commits the plugin to a concrete path BEFORE the engine call so the
    /// Photos-publish + on-disk-cleanup path knows exactly which file to
    /// touch. (If we passed `nil`, the engine would generate its own
    /// timestamp-based filename and we'd have to read it back from
    /// `StillCaptureOutput.filePath` — same result, more coupling.)
    ///
    /// - `directory == nil`, `fileName == nil`
    ///   → `<Documents>/<defaultPrefix>_<timestamp>.<defaultExt>`
    /// - `directory != nil`, `fileName == nil`
    ///   → `<directory>/<defaultPrefix>_<timestamp>.<defaultExt>`
    /// - `fileName != nil`
    ///   → `<directory ?? Documents>/<fileName>`
    ///
    /// Sandbox enforcement is delegated to the engine's
    /// `PhotosLibraryClient.resolve`, which throws
    /// `EngineError.invalidOutputPath` for paths outside `NSHomeDirectory()`
    /// — the plugin doesn't duplicate that check here.
    private static func buildOutputURL(
        directory: String?,
        fileName: String?,
        defaultPrefix: String,
        defaultExt: String
    ) -> URL {
        let dirURL: URL = {
            if let directory {
                return URL(fileURLWithPath: directory, isDirectory: true)
            }
            return URL.documentsDirectory
        }()
        let name: String = {
            if let fileName, !fileName.isEmpty {
                return fileName
            }
            // ISO8601 with `:` swapped to `-` so the result is a valid
            // filename on every iOS filesystem (`:` is reserved on HFS+).
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            return "\(defaultPrefix)_\(timestamp).\(defaultExt)"
        }()
        return dirURL.appendingPathComponent(name)
    }

    /// Finalises a still capture: optionally publishes to Photos, deletes
    /// the on-disk file when published, and returns the wire-shaped
    /// `CamCaptureResult` per the contract documented on `captureImage` /
    /// `captureNaturalPicture`.
    ///
    /// Factored out so both methods share the exact same post-engine path.
    private static func finishStill(
        output: StillCaptureOutput,
        saveToLibrary: Bool
    ) async throws -> CamCaptureResult {
        if saveToLibrary {
            let fileURL = URL(fileURLWithPath: output.filePath)
            let localId = try await PhotosPublisher.publishStill(fileURL: fileURL)
            // Contract: `filePath` MUST be nil when the wire result carries
            // `phAssetLocalId`. Drop the on-disk file now that Photos owns a
            // copy — it would otherwise leak into Documents/ where the user
            // can see it via Files.app. Best-effort: a failed delete only
            // leaves a stray file (the asset is already in Photos).
            try? FileManager.default.removeItem(at: fileURL)
            return PigeonValueMapping.toCamCaptureResult(
                filePath: nil, phAssetLocalId: localId
            )
        } else {
            return PigeonValueMapping.toCamCaptureResult(
                filePath: output.filePath, phAssetLocalId: nil
            )
        }
    }

    /// `PigeonError` to throw when a HostApi call references a handle that
    /// is not currently registered.
    private static func handleNotFound(_ handle: Int64) -> PigeonError {
        PigeonError(
            code: "handle_not_found",
            message: "No open camera for handle \(handle)",
            details: nil
        )
    }

    /// `EngineError` → `PigeonError`. Subsequent tasks (E2-E11) reuse this
    /// helper when calling other engine methods that can throw.
    static func mapEngineError(_ e: EngineError) -> PigeonError {
        switch e {
        case .alreadyOpen:
            return PigeonError(code: "already_open", message: "Engine already open", details: nil)
        case .notOpen:
            return PigeonError(code: "not_open", message: "Engine not open", details: nil)
        case .cameraDenied:
            return PigeonError(code: "permission_denied", message: "Camera permission denied", details: nil)
        case .noBackCamera:
            return PigeonError(code: "camera_not_found", message: "No back camera found", details: nil)
        case .noSupportedFormat(let reason):
            return PigeonError(code: "configuration_failed", message: "No supported format: \(reason)", details: nil)
        case .lockForConfigurationFailed:
            return PigeonError(code: "configuration_failed", message: "lockForConfiguration failed", details: nil)
        case .settingsConflict(let reason):
            return PigeonError(code: "settings_conflict", message: reason, details: nil)
        case .sessionLifecycleTimeout:
            return PigeonError(code: "configuration_failed", message: "Session lifecycle timeout", details: nil)
        case .metal(let m):
            return PigeonError(code: "configuration_failed", message: "Metal: \(m)", details: nil)
        case .interop(let i):
            return PigeonError(code: "configuration_failed", message: "Interop: \(i)", details: nil)
        case .recording(let r):
            return PigeonError(code: "recording_failed", message: "Recording: \(r)", details: nil)
        case .capture(let c):
            return PigeonError(code: "capture_failed", message: "Capture: \(c)", details: nil)
        case .fatal(let ce):
            return PigeonError(code: "fatal", message: ce.message, details: nil)
        case .invalidOutputPath(let url):
            return PigeonError(code: "invalid_output_path", message: "Path outside sandbox: \(url.path)", details: nil)
        case .calibrationInProgress:
            return PigeonError(code: "calibration_in_progress", message: "A calibration is in progress", details: nil)
        }
    }

    /// Bridges async work to a synchronous-throws Pigeon entry point. Blocks
    /// the calling thread on a `DispatchSemaphore` until the inner async work
    /// completes, returning its result to the caller.
    ///
    /// IMPORTANT: only use this for Pigeon methods whose generated signature
    /// is `throws` (synchronous). Pigeon methods with a `completion:` handler
    /// should spawn a `Task { ... completion(...) }` instead — those are
    /// already non-blocking on the messenger thread, and blocking them would
    /// be a regression.
    ///
    /// Deadlock safety: `body` resolves entirely on the CameraKit actor's
    /// own executor; it never hops back to the Pigeon messenger thread we
    /// are blocked on, so the semaphore wait cannot self-deadlock. If you
    /// extend this helper to schedule work that returns to the messenger
    /// thread (e.g. for a Flutter platform call), you MUST switch to a
    /// non-blocking dispatch pattern instead.
    ///
    /// The `Box` indirection is a workaround for capturing the async result
    /// across the Task/semaphore boundary without `inout` parameters (which
    /// can't be captured by `@Sendable` Task closures).
    private func runAsyncBlocking<T>(_ body: @escaping () async -> T) -> T {
        let sem = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task {
            box.value = await body()
            sem.signal()
        }
        sem.wait()
        return box.value!
    }

    /// Reference-typed cell used by `runAsyncBlocking` to ferry an async
    /// result across the Task/semaphore boundary. The semaphore wait ensures
    /// the write happens-before the read, so concurrent access is impossible
    /// in practice.
    private final class Box<T> {
        var value: T?
    }
}
