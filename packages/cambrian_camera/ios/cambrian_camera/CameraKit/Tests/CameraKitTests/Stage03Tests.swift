import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import CameraKit

@Suite("Stage03Tests", .progressLogged)
struct Stage03Tests {

    // MARK: Test 1 — 03:settings-merge-non-nil-fields

    /// Non-nil-field overlay (07-settings.md §Merge model):
    /// prior {iso: 200, ev: 0} + incoming {zoom: 2.0} → {iso: 200, ev: 0, zoom: 2.0}.
    /// nil in incoming preserves prior.
    @Test func settingsMergeNonNilFields() {
        var prior = CameraSettings()
        prior.iso = 200
        prior.evCompensation = 0

        var incoming = CameraSettings()
        incoming.zoomRatio = 2.0
        // incoming.iso left nil — prior must survive.

        let merged = incoming.merging(onto: prior)

        #expect(merged.iso == 200)
        #expect(merged.evCompensation == 0)
        #expect(merged.zoomRatio == 2.0)
    }

    // MARK: Test 2 — 03:userdefaults-persistence-roundtrip

    /// save → load returns identical struct; fresh (empty) UserDefaults returns nil.
    @Test func userDefaultsPersistenceRoundtrip() throws {
        let suiteName = "CameraKit.Test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Empty store → nil.
        #expect(SettingsPersistence.load(defaults: defaults) == nil)

        var settings = CameraSettings()
        settings.iso = 400
        settings.exposureTimeNs = 8_333_333  // ~1/120s
        settings.focusDistance = 0.5
        settings.zoomRatio = 1.5

        SettingsPersistence.save(settings, defaults: defaults)
        let loaded = SettingsPersistence.load(defaults: defaults)

        #expect(loaded == settings)
    }

    // MARK: Test 3 — 03:iso-shutter-auto-switch (Rules 1 & 2)

    /// Rule 1: toggling ISO to manual → shutter auto-switches to manual (with latched value).
    /// Rule 2: toggling shutter to manual → ISO auto-switches to manual.
    /// Both toggles to auto → the other flips to auto.
    @Test func isoShutterAutoSwitch() throws {
        let latched = DeviceStateSnapshot(
            iso: 400, exposureDurationNs: 8_333_333, lensPosition: 0.5,
            whiteBalanceGains: WhiteBalanceGains(red: 1, green: 1, blue: 1),
            isAdjustingExposure: false, systemPressureLevel: .nominal)

        // Rule 1: ISO → manual forces exposure → manual.
        var r1 = CameraSettings()
        r1.isoMode = .manual
        r1.iso = 200
        let resolved1 = try SettingsCoupling.apply(rules: r1, latched: latched)
        #expect(resolved1.isoMode == .manual)
        #expect(resolved1.exposureMode == .manual)
        #expect(resolved1.iso == 200)
        #expect(resolved1.exposureTimeNs == latched.exposureDurationNs)  // Rule 3 latch

        // Rule 2: shutter → manual forces ISO → manual.
        var r2 = CameraSettings()
        r2.exposureMode = .manual
        r2.exposureTimeNs = 4_000_000
        let resolved2 = try SettingsCoupling.apply(rules: r2, latched: latched)
        #expect(resolved2.isoMode == .manual)
        #expect(resolved2.exposureMode == .manual)
        #expect(resolved2.iso == Int(latched.iso))  // Rule 3 latch
        #expect(resolved2.exposureTimeNs == 4_000_000)

        // Rule 1 inverse: ISO → auto flips exposure → auto.
        var r3 = CameraSettings()
        r3.isoMode = .auto
        let resolved3 = try SettingsCoupling.apply(rules: r3, latched: latched)
        #expect(resolved3.isoMode == .auto)
        #expect(resolved3.exposureMode == .auto)
    }

    // MARK: Test 4 — 03:rule3-manual-latch-from-last-readback (failure path)

    /// Rule 3 failure: transitioning to manual with no prior snapshot throws settingsConflict,
    /// leaving no device mutation to roll back.
    @Test func rule3ManualWithoutLatchThrows() {
        var s = CameraSettings()
        s.isoMode = .manual
        // iso intentionally nil; no snapshot available.

        #expect {
            _ = try SettingsCoupling.apply(rules: s, latched: nil)
        } throws: { error in
            guard let e = error as? EngineError, case .settingsConflict = e else { return false }
            return true
        }
    }

    // MARK: Test 5 — 03:kvo-asyncstream-adapter-emits-on-change

    /// KVO change → AsyncStream yields one snapshot. After consumer cancel +
    /// all local strong references release, the observer must deinit (proving
    /// the Tokens box → KVO observations chain unwinds deterministically per
    /// the lifetime contract in `KVOAsyncStream.swift`).
    ///
    /// The SourceKit `weak-mutability` advisory on `weakObserver` is a known
    /// false positive: `weak let` doesn't compile because the runtime zeros
    /// the slot when the referent dies — that *is* a mutation, even though
    /// no user code writes to it. `weak var` is required.
    @Test func kvoAsyncStreamAdapterEmitsOnChange() async throws {
        let fake = FakeKVODevice()
        weak var weakObserver: DeviceKVOObserver?
        var capturedISO: Float = 0

        // Scope all strong references — observer, stream, the consumer task —
        // inside a `do` block so they release at the closing brace. Outside
        // the block, the only path to `observer` is the weak slot, which lets
        // us assert that nothing else retained it.
        do {
            let (stream, observer) = DeviceKVOObserver.makeStream(source: fake)
            weakObserver = observer

            let receivedOne = Task<Float, Error> {
                for await snap in stream {
                    return snap.iso
                }
                throw CancellationError()
            }

            // Mutate → expect one emission.
            try await Task.sleep(for: .milliseconds(50))
            fake.iso = 800
            capturedISO = try await receivedOne.value

            // Cancel the consumer; AsyncStream's `onTermination` releases its
            // strong ref to Tokens. ARC then drops observer when this
            // do-block exits.
            receivedOne.cancel()
        }

        #expect(capturedISO == 800)

        // All local strong refs are gone. Poll the weak slot. 500 ms is
        // generous — ARC + onTermination teardown typically completes within
        // a few ms; the window guards against scheduler jitter.
        var released = false
        for _ in 0..<20 {
            if weakObserver == nil { released = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(released == true)
    }

    // MARK: Test 6 — 03:focus-distance-identity

    /// focusDistance ∈ [0.0, 1.0] maps 1:1 to AVCaptureDevice.lensPosition.
    @Test func focusDistanceIdentity() async throws {
        let fake = FakeCaptureDeviceProviding()
        fake.stubbedSnapshot = DeviceStateSnapshot(
            iso: 100, exposureDurationNs: 33_333_333, lensPosition: 0,
            whiteBalanceGains: WhiteBalanceGains(red: 1, green: 1, blue: 1),
            isAdjustingExposure: false, systemPressureLevel: .nominal)
        let session = CameraSession()
        var s = CameraSettings()
        s.focusMode = .manual
        s.focusDistance = 0.5
        try await session.applySettings(s, on: fake)
        #expect(fake.lastLockedLensPosition == 0.5)
    }

    // MARK: Test 7 — 03:settings-conflict-throws

    /// Out-of-range ISO/shutter throws settingsConflict with no partial mutation.
    @Test func settingsConflictThrows() async throws {
        let engine = CameraEngine()
        var s = CameraSettings()
        s.isoMode = .manual
        s.iso = 10  // below any realistic minISO
        s.exposureMode = .manual
        s.exposureTimeNs = 1_000_000_000  // 1 second — exceeds typical maxExposureDuration
        await #expect(throws: EngineError.self) {
            try await engine.updateSettings(s)
        }
    }
}

// Synthetic KVO source mirroring the `AVCaptureDevice` properties the adapter observes.
final class FakeKVODevice: NSObject, @unchecked Sendable {
    @objc dynamic var iso: Float = 100
    @objc dynamic var exposureDuration: CMTime = CMTime(value: 1, timescale: 30)
    @objc dynamic var lensPosition: Float = 0
    @objc dynamic var deviceWhiteBalanceGains: AVCaptureDevice.WhiteBalanceGains =
        AVCaptureDevice.WhiteBalanceGains(redGain: 1, greenGain: 1, blueGain: 1)
}

final class FakeCaptureDeviceProviding: CaptureDeviceProviding, @unchecked Sendable {
    var stubbedSnapshot: DeviceStateSnapshot?
    var lastLockedLensPosition: Float?

    var uniqueID: String { "fake.device" }
    var activeFormatSize: Size { Size(width: 1280, height: 960) }
    var supportedSizes: [Size] { [Size(width: 1280, height: 960)] }
    var isoRange: ClosedRange<Float> { 30...3200 }
    var exposureDurationRangeNs: ClosedRange<Int64> { 1_000_000...33_333_333 }
    var maxWhiteBalanceGain: Float { 4.0 }
    var minAvailableVideoZoomFactor: Double { 1.0 }
    var maxAvailableVideoZoomFactor: Double { 8.0 }
    var minExposureTargetBias: Float { -3.0 }
    var maxExposureTargetBias: Float { 3.0 }
    var lensAperture: Float { 0 }
    var lastSnapshot: DeviceStateSnapshot? { stubbedSnapshot }

    func installKVOIngest() async {}
    func cancelKVO() async {}
    func dumpAllFormats() async -> [String] { [] }

    func snapshotStream() -> AsyncStream<DeviceStateSnapshot> {
        AsyncStream { $0.finish() }
    }
    func lockForConfiguration() async throws {}
    func unlockForConfiguration() async {}
    func setExposureModeCustom(durationNs: Int64, iso: Float) async throws {}
    func setContinuousAutoExposure() async throws {}
    func setFocusModeLocked(lensPosition: Float) async throws { lastLockedLensPosition = lensPosition }
    func setContinuousAutoFocus() async throws {}
    func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) async throws {}
    func setContinuousAutoWhiteBalance() async throws {}
    func setWhiteBalanceLocked() async throws {}
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

    func setZoomFactor(_ factor: Double) async throws {}
    func setExposureCompensation(_ steps: Int) async throws {}
    func setVideoFrameDurationRange(minFrameDurationFps: Int, maxFrameDurationFps: Int) async throws {}
}

// Test-only factory over a synthetic NSObject source.
// Production entry is in KVOAsyncStream.swift.
extension DeviceKVOObserver {
    static func makeStream(
        source: FakeKVODevice
    ) -> (AsyncStream<DeviceStateSnapshot>, DeviceKVOObserver) {
        makeStreamFromObservations { cont, box in
            box.values = [
                source.observe(\.iso, options: [.new]) { obj, _ in
                    cont.yield(Self.snapshot(fake: obj))
                },
                source.observe(\.exposureDuration, options: [.new]) { obj, _ in
                    cont.yield(Self.snapshot(fake: obj))
                },
                source.observe(\.lensPosition, options: [.new]) { obj, _ in
                    cont.yield(Self.snapshot(fake: obj))
                },
                source.observe(\.deviceWhiteBalanceGains, options: [.new]) { obj, _ in
                    cont.yield(Self.snapshot(fake: obj))
                },
            ]
        }
    }

    static func snapshot(fake d: FakeKVODevice) -> DeviceStateSnapshot {
        let ns = Int64(CMTimeGetSeconds(d.exposureDuration) * 1_000_000_000)
        return DeviceStateSnapshot(
            iso: d.iso,
            exposureDurationNs: ns,
            lensPosition: d.lensPosition,
            whiteBalanceGains: WhiteBalanceGains(
                red: d.deviceWhiteBalanceGains.redGain,
                green: d.deviceWhiteBalanceGains.greenGain,
                blue: d.deviceWhiteBalanceGains.blueGain),
            isAdjustingExposure: false,
            systemPressureLevel: .nominal)
    }
}
