import CoreMedia
import Testing

@testable import CameraKit

// MARK: - FakeCaptureDevice (ADR-32 test seam)
// Never constructed in production code. Supplies canned values without touching AVFoundation.

actor FakeCaptureDevice: CaptureDeviceProviding {
    var uniqueID: String { "fake-001" }
    var activeFormatSize: Size { Size(width: 4160, height: 3120) }
    var supportedSizes: [Size] {
        [
            Size(width: 4160, height: 3120),
            Size(width: 1920, height: 1080),
        ]
    }
    var isoRange: ClosedRange<Float> { 20.0...800.0 }
    var exposureDurationRangeNs: ClosedRange<Int64> { 1_000...500_000_000 }
    var maxWhiteBalanceGain: Float { 4.0 }
    var minAvailableVideoZoomFactor: Double { 1.0 }
    var maxAvailableVideoZoomFactor: Double { 8.0 }
    var minExposureTargetBias: Float { -3.0 }
    var maxExposureTargetBias: Float { 3.0 }
    var lensAperture: Float { 0 }

    func installKVOIngest() {}
    func cancelKVO() {}
    func dumpAllFormats() -> [String] { [] }

    func lockForConfiguration() throws {}
    func unlockForConfiguration() {}

    func setIsoExposureManual(durationNs: Int64, iso: Float) throws {}
    func setContinuousAutoExposure() throws {}

    func setFocusModeLocked(lensPosition: Float) throws {}
    func setContinuousAutoFocus() throws {}

    func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) throws {}
    func setContinuousAutoWhiteBalance() throws {}
    func setWhiteBalanceLocked() throws {}
    func setWhiteBalanceModeLockedToPresetAwaitingApply(_ preset: WhiteBalancePreset) async -> CMTime { .invalid }
    func setWhiteBalanceModeLockedToGainsAwaitingApply(_ gains: WhiteBalanceGains) async -> CMTime { .invalid }
    func awaitAESettled() async {}

    var currentDeviceWBGains: WhiteBalanceGains {
        WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0)
    }
    var grayWorldDeviceWBGains: WhiteBalanceGains {
        WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0)
    }
    func awaitWBSettled() async {}

    func setZoomFactor(_ factor: Double) throws {}
    func setExposureCompensation(_ steps: Int) throws {}
    func setVideoFrameDurationRange(minFrameDurationFps: Int, maxFrameDurationFps: Int) throws {}

    var lastSnapshot: DeviceStateSnapshot? { nil }
    nonisolated func snapshotStream() -> AsyncStream<DeviceStateSnapshot> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Format selection helper (mirrors the rule in CameraSession.configure)

/// Among supported sizes, select the largest 4:3 candidate.
///
/// Falls back to Constants.captureFallbackWidthPx × captureFallbackHeightPx if none qualify.
private func selectBest4x3(from sizes: [Size]) -> Size {
    let candidates =
        sizes
        .filter { $0.width * 3 == $0.height * 4 }
        .sorted { $0.width * $0.height > $1.width * $1.height }
    return candidates.first
        ?? Size(
            width: Constants.captureFallbackWidthPx,
            height: Constants.captureFallbackHeightPx
        )
}

// MARK: - Stage01Tests

@Suite("Stage01Tests", .progressLogged)
struct Stage01Tests {

    // MARK: Test 1 — 01:capture-device-provider-seam

    /// Verifies FakeCaptureDevice conforms to CaptureDeviceProviding and returns canned values.
    ///
    /// No AVCaptureDevice or LiveCaptureDevice is touched anywhere in this test. (ADR-32.)
    @Test func captureDeviceProviderSeam() async {
        let fake = FakeCaptureDevice()

        let uid = await fake.uniqueID
        #expect(uid == "fake-001")

        let sizes = await fake.supportedSizes
        #expect(
            sizes == [
                Size(width: 4160, height: 3120),
                Size(width: 1920, height: 1080),
            ])

        let isoRange = await fake.isoRange
        #expect(isoRange == 20.0...800.0)

        let exposureRange = await fake.exposureDurationRangeNs
        #expect(exposureRange == 1_000...500_000_000)

        let maxGain = await fake.maxWhiteBalanceGain
        #expect(maxGain == 4.0)
    }

    // MARK: Test 1b — protocol surface added by Family B follow-ups

    /// `CaptureDeviceProviding` now owns four members that previously required
    /// an `as? LiveCaptureDevice` cast in `CameraEngine` (`installKVOIngest`,
    /// `cancelKVO`, `dumpAllFormats`, `lensAperture`). The fake must implement
    /// all four — this test pins the seam contract for future fakes.
    @Test func captureDeviceProviderSeamFamilyBSurface() async throws {
        let fake = FakeCaptureDevice()

        let aperture = await fake.lensAperture
        #expect(aperture == 0)

        let formats = await fake.dumpAllFormats()
        #expect(formats.isEmpty)

        // Both lifecycle methods must complete without throwing on a fake that
        // doesn't model KVO — they're no-ops by construction.
        await fake.installKVOIngest()
        await fake.cancelKVO()
    }

    // MARK: Test 1c — engine routes through the protocol, not the concrete type

    /// `CameraEngine.dumpDeviceFormats()` on a closed engine returns `[]`
    /// without crashing. Pre-Family-B follow-up this routed through an
    /// `as? LiveCaptureDevice` cast that silently returned `[]` on fakes; now
    /// it forwards to the protocol's `dumpAllFormats()`.
    @Test func engineDumpDeviceFormatsReturnsEmptyWhenClosed() async {
        let engine = CameraEngine(initialPhase: .active)
        let formats = await engine.dumpDeviceFormats()
        #expect(formats.isEmpty)
    }

    // MARK: Test 2 — 01:largest-4x3-format-selected

    /// Verifies the 4:3 format-selection rule using the helper above.
    @Test func largest4x3FormatSelected() {
        // Given a mix of 4:3 and 16:9 sizes, the largest 4:3 wins.
        let mixed: [Size] = [
            Size(width: 4160, height: 3120),  // 4:3
            Size(width: 3840, height: 2160),  // 16:9
        ]
        #expect(selectBest4x3(from: mixed) == Size(width: 4160, height: 3120))

        // Given only 16:9 sizes, fall back to the constants-defined fallback.
        let noFourThree: [Size] = [
            Size(width: 3840, height: 2160)
        ]
        #expect(
            selectBest4x3(from: noFourThree)
                == Size(
                    width: Constants.captureFallbackWidthPx,
                    height: Constants.captureFallbackHeightPx
                ))

        // Sanity-check the fallback dimensions themselves match the brief spec.
        #expect(Constants.captureFallbackWidthPx == 1280)
        #expect(Constants.captureFallbackHeightPx == 960)
    }

    // MARK: Test 3 — 01:engine-open-close-transitions

    /// Verifies CameraEngine initializes without throwing and exposes stateStream(),
    /// and that close() on a non-open engine completes without throwing.
    @Test func engineOpenCloseTransitions() async throws {
        let engine = CameraEngine(initialPhase: .active)

        // stateStream() must return an AsyncStream<SessionState> (type-checks at compile time).
        let stream: AsyncStream<SessionState> = await engine.stateStream()
        _ = stream  // silence unused-variable warning; type assertion is the test.

        // close() on a non-open engine must not throw (it silently returns per brief).
        await engine.close()
    }

    // MARK: Test 4 — 01:landscape-right-rotation-applied

    /// Verifies the capture orientation constant matches Stage 06 HITL.
    ///
    /// Stage 06 commit `e09c1f3` ("fix(stage-06): green artifact, FPS regression,
    /// landscape lock — HITL PASS") changed this from 90 → 0 to fix landscape
    /// rendering on iPad Pro M1. The Stage 01 brief still names 90; the HITL
    /// fix wins over the brief, and the deviation is logged in `state.md`
    /// ("Decisions taken that weren't in briefs"). Test updated during the
    /// Stage 11 regression sweep.
    @Test func landscapeRightRotationApplied() {
        #expect(Constants.captureOrientationAngleDeg == 0)
    }

    // MARK: Test 5 — Consumer registry subscribe / unregister (Stage 06 actor API)

    /// Verifies ConsumerRegistry.subscribe returns an AsyncStream and unregister does not crash.
    ///
    /// Stage 06 replaced the Stage-01 class-based ConsumerRegistry with an actor.
    /// The old register/deregister API is gone; subscribe(stream:)/unregister(token:) are the
    /// production paths. This test verifies the new contract.
    @Test func consumerRegistrySubscribeUnregister() async {
        let registry = ConsumerRegistry()

        // subscribe() returns an AsyncStream — verified at compile time.
        let stream1: AsyncStream<FrameSet> = await registry.subscribe(stream: .natural)
        _ = stream1

        // subscriberCount nonisolated accessor reflects the registration.
        #expect(registry.subscriberCount(for: .natural) == 1)

        // A second subscription increments the count.
        let stream2: AsyncStream<FrameSet> = await registry.subscribe(stream: .natural)
        _ = stream2
        #expect(registry.subscriberCount(for: .natural) == 2)

        // release() finishes all continuations — does not crash.
        await registry.release()
        #expect(registry.subscriberCount(for: .natural) == 0)
    }
}
