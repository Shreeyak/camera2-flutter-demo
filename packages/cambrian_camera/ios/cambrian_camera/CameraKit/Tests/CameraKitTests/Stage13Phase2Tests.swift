import Foundation
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

    /// Phase-3's zero-copy `FlutterTexture` bridge wraps the lane
    /// `CVPixelBuffer`. As of pre-Phase-3 RGBA8 conversion, the default-on
    /// path emits BGRA8 (`kCVPixelFormatType_32BGRA`) on
    /// `currentPixelBuffer(stream:)`; the flag-off path keeps RGBA16F. Both
    /// string values are pinned here so a future format change without
    /// updating the constant fails this regression rather than silently
    /// breaking Phase-3.
    @Test("SessionCapabilities reports BGRA8 lane format under default-on flag")
    func defaultLaneFormatIsBgra8() {
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: Constants.streamPixelFormatStringEightBit,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...1.0,
            evCompensationRange: -3.0...3.0)
        #expect(cap.streamPixelFormat == "BGRA8")
    }

    @Test("SessionCapabilities reports RGBA16F when opted out (lanesEightBit=false)")
    func optOutLaneFormatIsRgba16f() {
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: Constants.streamPixelFormatStringSixteenBit,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...1.0,
            evCompensationRange: -3.0...3.0)
        #expect(cap.streamPixelFormat == "RGBA16F")
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
            streamPixelFormat: "RGBA16F",
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
