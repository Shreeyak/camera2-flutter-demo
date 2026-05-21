import CoreMedia
import CoreVideo
import Foundation
import Metal
import Testing

@testable import CameraKit

// MARK: - §2a — OpenConfiguration.initialSettings widening

// MARK: - §2c — streamConfigurationStream()

@Suite("Stage 13 Phase 2 — Stream configuration stream")
struct Stage13Phase2StreamConfigurationStreamTests {

    @Test("streamConfigurationStream() returns a cached AsyncStream that terminates cleanly")
    func streamConfigurationStreamCachesAndTerminates() async {
        let engine = CameraEngine()
        let s1 = await engine.streamConfigurationStream()
        let s2 = await engine.streamConfigurationStream()
        // Cached: subsequent calls don't crash and return a stream we can iterate.
        let drainer = Task {
            for await _ in s1 { break }
            for await _ in s2 { break }
        }
        drainer.cancel()
        _ = await drainer.value
    }

    @Test("StreamConfiguration carries resolution + crop")
    func streamConfigurationCarriesResolutionAndCrop() {
        let cfg = StreamConfiguration(
            activeCaptureResolution: Size(width: 4032, height: 3024),
            activeCropRegion: Rect(x: 100, y: 200, width: 1920, height: 1080))
        #expect(cfg.activeCaptureResolution == Size(width: 4032, height: 3024))
        #expect(cfg.activeCropRegion.x == 100)
        #expect(cfg.activeCropRegion.width == 1920)
    }
}

// MARK: - §2d.7 — Lane pixel-format regression (pre-Phase-3 RGBA8 split)

@Suite("Stage 13 Phase 2 — Lane pixel format")
struct Stage13Phase2PixelFormatTests {

    /// Phase-3's zero-copy `FlutterTexture` bridge wraps the lane `CVPixelBuffer`.
    ///
    /// BGRA8 (`kCVPixelFormatType_32BGRA`) is the unconditional wire format on
    /// `currentPixelBuffer(stream:)`. The string value is pinned here so a
    /// future format change without updating the constant fails this regression
    /// rather than silently breaking Phase-3.
    @Test("SessionCapabilities.streamPixelFormat is always BGRA8")
    func laneFormatIsUnconditionallyBgra8() {
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: Constants.streamPixelFormatString,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...1.0,
            evCompensationRange: -3.0...3.0)
        #expect(cap.streamPixelFormat == "BGRA8")
    }
}

// MARK: - §2c — currentPixelBuffer(stream:)

@Suite("Stage 13 Phase 2 — currentPixelBuffer")
struct Stage13Phase2CurrentPixelBufferTests {

    @Test("currentPixelBuffer returns nil for every lane before any frame is delivered")
    func currentPixelBufferIsNilBeforeFirstFrame() {
        let engine = CameraEngine()
        #expect(engine.currentPixelBuffer(stream: .natural) == nil)
        #expect(engine.currentPixelBuffer(stream: .processed) == nil)
        #expect(engine.currentPixelBuffer(stream: .tracker) == nil)
    }
}

// MARK: - §2d.6 — Permission helpers

@Suite("Stage 13 Phase 2 — Permissions")
struct Stage13Phase2PermissionsTests {

    @Test("cameraPermissionStatus returns one of the four valid statuses")
    func cameraPermissionStatusReturnsValidValue() {
        let s = CameraEngine.cameraPermissionStatus()
        let valid: Set<CameraPermissionStatus> = [.notDetermined, .denied, .restricted, .authorized]
        #expect(valid.contains(s), "got \(s)")
    }

    @Test("photosAddPermissionStatus returns one of the four valid statuses")
    func photosAddPermissionStatusReturnsValidValue() {
        let s = CameraEngine.photosAddPermissionStatus()
        let valid: Set<CameraPermissionStatus> = [.notDetermined, .denied, .restricted, .authorized]
        #expect(valid.contains(s), "got \(s)")
    }
}

// MARK: - §2d.5 — SessionState.interrupted

@Suite("Stage 13 Phase 2 — Interrupted state")
struct Stage13Phase2InterruptedStateTests {

    @Test(".otherInterruption publishes .interrupted; .otherInterruptionEnded reverts to .streaming")
    func otherInterruptionTogglesInterruptedState() async {
        let engine = CameraEngine()
        // Post-Stage-12: SessionStateMachine treats `.closed → .interrupted
        // (event)` as off-map (AVF only fires `.otherInterruption` against a
        // running session; the test was bypassing that precondition). Set the
        // realistic precondition via the existing test seam.
        await engine._markOpenForTest()
        let states = await engine.stateStream()
        // Drain in this task; post events from a child task with a tiny stagger
        // so the stream is being consumed when the events fire.
        let poster = Task {
            try? await Task.sleep(for: .milliseconds(50))
            await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 4))
            await engine._postSessionEventForTest(.otherInterruptionEnded)
        }
        var observed: [SessionState] = []
        for await s in states {
            observed.append(s)
            if observed.count >= 2 { break }
        }
        _ = await poster.value
        #expect(observed.contains(.interrupted), "observed=\(observed)")
        #expect(observed.last == .streaming, "observed=\(observed)")
    }
}

// MARK: - §2c — SessionCapabilities range fields

@Suite("Stage 13 Phase 2 — SessionCapabilities")
struct Stage13Phase2SessionCapabilitiesTests {

    @Test("SessionCapabilities carries focus/zoom/EV-comp ranges")
    func carriesRangeFields() {
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: Constants.streamPixelFormatString,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...8.0,
            evCompensationRange: -3.0...3.0)
        #expect(cap.focusRange == 0.0...1.0)
        #expect(cap.zoomRange == 1.0...8.0)
        #expect(cap.evCompensationRange == -3.0...3.0)
    }
}

@Suite("Stage 13 Phase 2 — OpenConfiguration")
struct Stage13Phase2OpenConfigurationTests {

    @Test("OpenConfiguration legacy init still compiles; initialSettings defaults to nil")
    func legacyInitStillCompiles() {
        let legacy = OpenConfiguration(
            cameraId: "back",
            captureResolution: Size(width: 1920, height: 1080))
        #expect(legacy.initialSettings == nil)
        #expect(legacy.cameraId == "back")
        #expect(legacy.captureResolution == Size(width: 1920, height: 1080))
    }

    @Test("OpenConfiguration carries initialSettings through")
    func carriesInitialSettings() {
        var s = CameraSettings()
        s.iso = 400
        s.isoMode = .manual
        s.exposureMode = .manual
        s.exposureTimeNs = 16_000_000
        let cfg = OpenConfiguration(initialSettings: s)
        #expect(cfg.initialSettings?.iso == 400)
        #expect(cfg.initialSettings?.isoMode == .manual)
        #expect(cfg.initialSettings?.exposureTimeNs == 16_000_000)
    }
}

// MARK: - scenePhase × interruption off-map race regression

/// Regression for the `interrupted → streaming (command)` off-map trap.
///
/// Caught under `test_device`: a harness/bring-up AVF interruption drives the
/// engine to `.interrupted`, then a `.active` scenePhase made
/// `notifyScenePhasePaused` publish `.streaming (command)` — off-map from
/// `.interrupted`, which tripped the `publishState` `assertionFailure` before
/// Fix 2 (off-map is now logged + applied, not fatal) and would still overwrite
/// the OS-authoritative state. The mirror now defers to the classifier
/// (`SessionStateMachine` is SSOT) when the origin is OS-owned.
@Suite("Stage 13 Phase 2 — scenePhase mirror off-map guard")
struct Stage13Phase2ScenePhaseMirrorGuardTests {

    /// Drive engine `.streaming → .interrupted` via the same seam the existing
    /// interrupted-state test uses, mirroring the `test_device` precondition.
    private func makeInterruptedEngine() async -> CameraEngine {
        let engine = CameraEngine()
        await engine._markOpenForTest()
        await engine._postSessionEventForTest(.otherInterruption(reasonRawValue: 4))
        #expect(await engine._currentStateForTest == .interrupted)
        return engine
    }

    @Test("from .interrupted, notifyScenePhasePaused(false) does not force .streaming (command)")
    func scenePhaseActiveFromInterruptedIsSkipped() async {
        let engine = await makeInterruptedEngine()
        // Pre-fix: off-map `.interrupted → .streaming (command)` overwrote the
        // OS-authoritative state (and aborted DEBUG builds before Fix 2).
        await engine.notifyScenePhasePaused(false)
        #expect(await engine._currentStateForTest == .interrupted)
    }

    @Test("from .interrupted, notifyScenePhasePaused(true) does not force .paused (command)")
    func scenePhaseInactiveFromInterruptedIsSkipped() async {
        let engine = await makeInterruptedEngine()
        await engine.notifyScenePhasePaused(true)
        #expect(await engine._currentStateForTest == .interrupted)
    }

    @Test("OS event path still restores .streaming after the mirror deferred")
    func interruptionEndStillRestoresStreaming() async {
        let engine = await makeInterruptedEngine()
        await engine.notifyScenePhasePaused(false)  // deferred, no-op
        await engine._postSessionEventForTest(.otherInterruptionEnded)
        #expect(await engine._currentStateForTest == .streaming)
    }

    @Test("positive control: from .streaming the mirror still publishes .paused (command)")
    func scenePhaseMirrorStillWorksFromStreaming() async {
        let engine = CameraEngine()
        await engine._markOpenForTest()  // .streaming
        await engine.notifyScenePhasePaused(true)
        #expect(await engine._currentStateForTest == .paused)
        await engine.notifyScenePhasePaused(false)
        #expect(await engine._currentStateForTest == .streaming)
    }
}

// MARK: - §2d.7 — FrameSet lane delivery (C++/AsyncStream consumers)

@Suite("Stage 13 Phase 2 — FrameSet lane delivery")
struct Stage13Phase2FrameSetDeliveryTests {

    /// The `FrameSet` published to `consumers.yield` / the AsyncStream must
    /// carry BGRA8 for every lane — that is what the C++ `CannyConsumer`
    /// (`_32BGRA → COLOR_BGRA2GRAY`) and the Phase-3 bridge consume. A tracker
    /// subscriber is registered so the tracker lane is the fused BGRA8 buffer,
    /// not the natural fallback.
    @Test("FrameSet delivers _32BGRA buffers for natural, processed, and tracker")
    func frameSetLanesAreBgra8() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let consumers = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true,
            consumers: consumers)

        let naturalStream = await consumers.subscribe(stream: .natural)
        let trackerStream = await consumers.subscribe(stream: .tracker)

        let sample = try makeSyntheticYUVSampleBufferForStage13Tests(width: 256, height: 192)
        try pipeline.encode(sampleBuffer: sample)

        var received: FrameSet?
        for await fs in naturalStream {
            received = fs
            break
        }
        guard let fs = received else {
            Issue.record("no FrameSet delivered on the natural stream")
            return
        }
        #expect(CVPixelBufferGetPixelFormatType(fs.natural) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetPixelFormatType(fs.processed) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetPixelFormatType(fs.tracker) == kCVPixelFormatType_32BGRA)
        withExtendedLifetime(trackerStream) {}
    }
}

// MARK: - Helpers

/// IOSurface-backed YUV biplanar sample buffer for `encode(sampleBuffer:)`.
///
/// Named distinctly from the per-file helpers in the other suites to avoid
/// linker symbol overlap within the test target.
private func makeSyntheticYUVSampleBufferForStage13Tests(
    width: Int, height: Int
) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let cvStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attrs, &pixelBuffer)
    guard cvStatus == kCVReturnSuccess, let pb = pixelBuffer else {
        throw MetalError.unsupportedFormat
    }
    var fdOut: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fdOut)
    guard let fd = fdOut else { throw MetalError.unsupportedFormat }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid)
    var sbOut: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fd,
        sampleTiming: &timing, sampleBufferOut: &sbOut)
    guard let sb = sbOut else { throw MetalError.unsupportedFormat }
    return sb
}
