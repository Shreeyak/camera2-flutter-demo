import AVFoundation
import Atomics
import Foundation
import Synchronization

// MARK: - ADR-32 test seam

/// ADR-32: engine depends on this protocol, never on AVCaptureDevice directly.
///
/// The fake in tests supplies canned format data without touching AVFoundation.
public protocol CaptureDeviceProviding: AnyObject, Sendable {
    var uniqueID: String { get async }
    var activeFormatSize: Size { get async }
    var supportedSizes: [Size] { get async }
    var isoRange: ClosedRange<Float> { get async }
    var exposureDurationRangeNs: ClosedRange<Int64> { get async }
    var maxWhiteBalanceGain: Float { get async }

    // Phase-2 §2c capability range fields.
    /// `AVCaptureDevice.minAvailableVideoZoomFactor` for the active format.
    var minAvailableVideoZoomFactor: Double { get async }
    /// `AVCaptureDevice.maxAvailableVideoZoomFactor` for the active format.
    var maxAvailableVideoZoomFactor: Double { get async }
    /// `AVCaptureDevice.minExposureTargetBias` (EV stops, signed).
    var minExposureTargetBias: Float { get async }
    /// `AVCaptureDevice.maxExposureTargetBias` (EV stops, signed).
    var maxExposureTargetBias: Float { get async }

    func lockForConfiguration() async throws
    func unlockForConfiguration() async

    func setExposureModeCustom(durationNs: Int64, iso: Float) async throws
    func setContinuousAutoExposure() async throws

    func setFocusModeLocked(lensPosition: Float) async throws
    func setContinuousAutoFocus() async throws

    func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) async throws
    func setContinuousAutoWhiteBalance() async throws
    func setWhiteBalanceLocked() async throws

    /// Locks WB to one of Apple's named temperature/tint presets and awaits
    /// the first delivered buffer that has the new gains applied.
    ///
    /// Wraps `AVCaptureDevice.setWhiteBalanceModeLocked(whiteBalanceTemperatureAndTintValues:handler:)`
    /// (iOS 26.0+) and bridges its `handler` to async/await with a 400 ms
    /// deadline. AVF fires the handler within 1–3 frames in steady state; a
    /// longer deadline blocks the calibration flow unnecessarily on a genuine
    /// miss. Returns the buffer timestamp AVF reports as the first frame
    /// carrying the preset gains (`CMTime.invalid` if the deadline fired —
    /// logged at error level). Caller must hold `lockForConfiguration()`.
    func setWhiteBalanceModeLockedToPresetAwaitingApply(_ preset: WhiteBalancePreset) async -> CMTime

    /// Locks WB to explicit gains and awaits buffer-with-gains, same shape as
    /// the preset variant. Used inside `calibrateWB`'s iterative loop where
    /// each iteration writes computed gains and waits for the natural texture
    /// to reflect them before resampling.
    func setWhiteBalanceModeLockedToGainsAwaitingApply(_ gains: WhiteBalanceGains) async -> CMTime

    /// Awaits `isAdjustingExposure == false` via KVO. Returns immediately if
    /// already settled; times out after 2 s. Mirrors `awaitWBSettled`.
    func awaitAESettled() async

    /// Current WB gains applied by the device (continuous AWB or a prior manual lock).
    var currentDeviceWBGains: WhiteBalanceGains { get async }

    /// Apple's built-in gray-world gains for the current scene.
    ///
    /// `AVCaptureDevice.grayWorldDeviceWhiteBalanceGains` — assumes a neutral
    /// subject (gray card) fills the center 50% of the frame. Available
    /// regardless of WB mode. Apply via `setWhiteBalanceModeLocked(gains:)`.
    var grayWorldDeviceWBGains: WhiteBalanceGains { get async }

    /// Awaits AWB convergence. Returns immediately if already settled; times out after 2 s.
    func awaitWBSettled() async

    func setZoomFactor(_ factor: Double) async throws
    func setExposureCompensation(_ steps: Int) async throws

    func setVideoFrameDurationRange(
        minFrameDurationFps: Int,
        maxFrameDurationFps: Int
    ) async throws

    // Stage 03 — KVO-backed device-state stream (ADR-14). Rule 3 of
    // ISO/exposure coupling reads `lastSnapshot`.
    func snapshotStream() -> AsyncStream<DeviceStateSnapshot>
    var lastSnapshot: DeviceStateSnapshot? { get async }

    /// Begins ingesting KVO snapshots into `lastSnapshot`. No-op if already running.
    ///
    /// Called by `CameraEngine.open()` after the session is built so that Rule 3
    /// of the ISO/exposure coupling has a populated `lastSnapshot` to read.
    func installKVOIngest() async

    /// Cancels the KVO ingest task and drops the observer. No-op if not running.
    func cancelKVO() async

    /// Returns a per-format dump of every `AVCaptureDevice.Format`
    /// (FourCC, dimensions, FPS ranges, bit-depth tag, FOV, zoom, color spaces).
    ///
    /// Used by `ViewModel.dumpCapabilities` to snapshot the format table to
    /// `Documents/capabilities.txt`. Returns `[]` on fakes that don't surface
    /// real AVFoundation formats.
    func dumpAllFormats() async -> [String]

    /// Current lens aperture (f-number) reported by the device — written into
    /// still-capture EXIF. Returns `0` on fakes that don't model optics.
    var lensAperture: Float { get async }
}

// MARK: - DeviceStateSnapshot (ADR-14; KVO stream wired Stage 03)

public struct DeviceStateSnapshot: Sendable, Hashable {
    public let iso: Float
    public let exposureDurationNs: Int64
    public let lensPosition: Float
    public let whiteBalanceGains: WhiteBalanceGains
    public let isAdjustingExposure: Bool
    public let systemPressureLevel: SystemPressureLevel

    public init(
        iso: Float, exposureDurationNs: Int64, lensPosition: Float,
        whiteBalanceGains: WhiteBalanceGains, isAdjustingExposure: Bool,
        systemPressureLevel: SystemPressureLevel
    ) {
        self.iso = iso
        self.exposureDurationNs = exposureDurationNs
        self.lensPosition = lensPosition
        self.whiteBalanceGains = whiteBalanceGains
        self.isAdjustingExposure = isAdjustingExposure
        self.systemPressureLevel = systemPressureLevel
    }
}

public enum SystemPressureLevel: String, Sendable, Hashable {
    case nominal
    case fair
    case serious
    case critical
    case shutdown
}

// MARK: - Production implementation

/// Production implementation: wraps a single back-facing wide-angle AVCaptureDevice (D-08).
/// CameraSession receives avDevice for sessionQueue work; tests never reach this type.
final actor LiveCaptureDevice: CaptureDeviceProviding {
    // nonisolated(unsafe): accessed from nonisolated snapshotStream() factory;
    // AVCaptureDevice mutations always gate through lockForConfiguration() on
    // sessionQueue (ADR-07), so cross-isolation reads are safe.
    nonisolated(unsafe) let avDevice: AVCaptureDevice

    init(avDevice: AVCaptureDevice) {
        self.avDevice = avDevice
    }

    var uniqueID: String { avDevice.uniqueID }

    var activeFormatSize: Size {
        let dims = CMVideoFormatDescriptionGetDimensions(avDevice.activeFormat.formatDescription)
        return Size(width: Int(dims.width), height: Int(dims.height))
    }

    var supportedSizes: [Size] {
        // `avDevice.formats` returns one entry per (dimensions, FPS range,
        // binned/full readout, pixel-range) combination — so each resolution
        // typically appears 4–8 times. Callers (and the public picker) want
        // a *unique* list of selectable resolutions, sorted by area.
        //
        // Filter: FullRange ('420f') only; VideoRange ('420v') is rejected
        // per user directive 2026-05-13. Minimum 640×480 ("480p floor") —
        // smaller formats (352×288, 480×360) are not user-meaningful for
        // this app. Contradicts G-17 / architecture/03-camera-session.md
        // §Enumeration which accepts VideoRange.
        var seen: Set<Size> = []
        var unique: [Size] = []
        for format in avDevice.formats {
            let desc = format.formatDescription
            let pixelFormat = CMFormatDescriptionGetMediaSubType(desc)
            guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let w = Int(dims.width)
            let h = Int(dims.height)
            guard w >= 640 && h >= 480 else { continue }
            let size = Size(width: w, height: h)
            if seen.insert(size).inserted {
                unique.append(size)
            }
        }
        return unique.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
    }

    /// Internal debug helper — enumerates every `AVCaptureDevice.Format`.
    ///
    /// Each entry: FourCC, dimensions, FPS ranges, and bit-depth/range tag.
    /// Called from `ViewModel.dumpCapabilities` to write a one-shot
    /// snapshot to `Documents/capabilities.txt`. No filtering — includes
    /// formats we explicitly reject (VideoRange, 10-bit, sub-480p) so we
    /// can see what the device actually surfaces.
    func dumpAllFormats() -> [String] {
        avDevice.formats.map { format in
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let pixelFormat = CMFormatDescriptionGetMediaSubType(desc)
            let four = fourCC(pixelFormat)
            let tag = bitDepthRangeTag(pixelFormat)
            let fps = format.videoSupportedFrameRateRanges
                .map { r -> String in
                    let mn = Int(r.minFrameRate.rounded())
                    let mx = Int(r.maxFrameRate.rounded())
                    return mn == mx ? "\(mn)" : "\(mn)-\(mx)"
                }
                .joined(separator: ",")
            let binned = format.isVideoBinned ? "binned" : "full"
            let hdr = format.isVideoHDRSupported ? " hdr" : ""
            let fov = String(format: "%.0f°", format.videoFieldOfView)
            let zoom = String(format: "%.1fx", format.videoMaxZoomFactor)
            let colorSpaces = format.supportedColorSpaces
                .map { space -> String in
                    switch space {
                    case .sRGB: return "sRGB"
                    case .P3_D65: return "P3"
                    case .HLG_BT2020: return "HLG"
                    case .appleLog: return "AppleLog"
                    @unknown default: return "cs?"
                    }
                }
                .joined(separator: "+")
            return
                "'\(four)' \(dims.width)×\(dims.height) fps=\(fps) \(tag) "
                + "[\(binned)\(hdr) fov=\(fov) zoom≤\(zoom) cs=\(colorSpaces)]"
        }
    }

    var isoRange: ClosedRange<Float> {
        avDevice.activeFormat.minISO...avDevice.activeFormat.maxISO
    }

    var exposureDurationRangeNs: ClosedRange<Int64> {
        let minNs = Int64(CMTimeGetSeconds(avDevice.activeFormat.minExposureDuration) * 1_000_000_000)
        let maxNs = Int64(CMTimeGetSeconds(avDevice.activeFormat.maxExposureDuration) * 1_000_000_000)
        return minNs...maxNs
    }

    var maxWhiteBalanceGain: Float { avDevice.maxWhiteBalanceGain }

    var minAvailableVideoZoomFactor: Double { Double(avDevice.minAvailableVideoZoomFactor) }
    var maxAvailableVideoZoomFactor: Double { Double(avDevice.maxAvailableVideoZoomFactor) }
    var minExposureTargetBias: Float { avDevice.minExposureTargetBias }
    var maxExposureTargetBias: Float { avDevice.maxExposureTargetBias }

    var lensAperture: Float { avDevice.lensAperture }

    func lockForConfiguration() throws { try avDevice.lockForConfiguration() }
    func unlockForConfiguration() { avDevice.unlockForConfiguration() }

    func setExposureModeCustom(durationNs: Int64, iso: Float) throws {
        let duration = CMTimeMake(value: durationNs, timescale: 1_000_000_000)
        avDevice.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
    }

    func setContinuousAutoExposure() throws {
        guard avDevice.isExposureModeSupported(.continuousAutoExposure) else { return }
        avDevice.exposureMode = .continuousAutoExposure
    }

    func setFocusModeLocked(lensPosition: Float) throws {
        avDevice.setFocusModeLocked(lensPosition: lensPosition, completionHandler: nil)
    }

    func setContinuousAutoFocus() throws {
        guard avDevice.isFocusModeSupported(.continuousAutoFocus) else { return }
        avDevice.focusMode = .continuousAutoFocus
    }

    func setWhiteBalanceModeLocked(gains: WhiteBalanceGains) throws {
        let avGains = AVCaptureDevice.WhiteBalanceGains(
            redGain: gains.red, greenGain: gains.green, blueGain: gains.blue)
        avDevice.setWhiteBalanceModeLocked(with: avGains, completionHandler: nil)
    }

    func setContinuousAutoWhiteBalance() throws {
        guard avDevice.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return }
        avDevice.whiteBalanceMode = .continuousAutoWhiteBalance
    }

    func setWhiteBalanceLocked() throws {
        guard avDevice.isWhiteBalanceModeSupported(.locked) else { return }
        avDevice.whiteBalanceMode = .locked
    }

    func setWhiteBalanceModeLockedToPresetAwaitingApply(_ preset: WhiteBalancePreset) async -> CMTime {
        let avPreset: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues
        switch preset {
        case .daylight: avPreset = .daylight
        case .cloudy: avPreset = .cloudy
        case .shadow: avPreset = .shadow
        case .tungsten: avPreset = .tungsten
        case .fluorescent: avPreset = .fluorescent
        }
        return await wbApplyAwait(avDevice: avDevice, kind: .preset(avPreset, label: preset.rawValue))
    }

    func setWhiteBalanceModeLockedToGainsAwaitingApply(_ gains: WhiteBalanceGains) async -> CMTime {
        let avGains = AVCaptureDevice.WhiteBalanceGains(
            redGain: gains.red, greenGain: gains.green, blueGain: gains.blue)
        return await wbApplyAwait(avDevice: avDevice, kind: .gains(avGains))
    }

    func awaitAESettled() async {
        await aeSettledWait(avDevice: avDevice)
    }

    func setZoomFactor(_ factor: Double) throws {
        avDevice.videoZoomFactor = CGFloat(factor)
    }

    func setExposureCompensation(_ steps: Int) throws {
        avDevice.setExposureTargetBias(Float(steps), completionHandler: nil)
    }

    func setVideoFrameDurationRange(minFrameDurationFps: Int, maxFrameDurationFps: Int) throws {
        avDevice.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(minFrameDurationFps))
        avDevice.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(maxFrameDurationFps))
    }

    private var kvoObserver: DeviceKVOObserver?
    private var _lastSnapshot: DeviceStateSnapshot?
    private var ingestTask: Task<Void, Never>?

    var lastSnapshot: DeviceStateSnapshot? { _lastSnapshot }

    nonisolated func snapshotStream() -> AsyncStream<DeviceStateSnapshot> {
        let (stream, _) = DeviceKVOObserver.makeStream(avDevice: avDevice)
        return stream
    }

    func installKVOIngest() {
        guard ingestTask == nil else { return }
        let (stream, observer) = DeviceKVOObserver.makeStream(avDevice: avDevice)
        kvoObserver = observer
        ingestTask = Task { [weak self] in
            for await snap in stream {
                if Task.isCancelled { return }
                await self?.setLastSnapshot(snap)
            }
        }
    }

    func cancelKVO() {
        ingestTask?.cancel()
        ingestTask = nil
        kvoObserver = nil
    }

    private func setLastSnapshot(_ snap: DeviceStateSnapshot) {
        _lastSnapshot = snap
    }

    /// Current WB gains applied by AVCaptureDevice — whatever continuous AWB or a
    /// prior manual lock most recently set.
    ///
    /// Reads `avDevice.deviceWhiteBalanceGains`.
    var currentDeviceWBGains: WhiteBalanceGains {
        let g = avDevice.deviceWhiteBalanceGains
        return WhiteBalanceGains(red: g.redGain, green: g.greenGain, blue: g.blueGain)
    }

    /// Apple's built-in gray-world gains for the current scene.
    ///
    /// Reads `avDevice.grayWorldDeviceWhiteBalanceGains`. Apple computes these
    /// from the center 50% of the frame assuming a neutral subject; readable
    /// regardless of WB mode. Apply via `setWhiteBalanceModeLocked(gains:)`.
    var grayWorldDeviceWBGains: WhiteBalanceGains {
        let g = avDevice.grayWorldDeviceWhiteBalanceGains
        return WhiteBalanceGains(red: g.redGain, green: g.greenGain, blue: g.blueGain)
    }

    /// Awaits `isAdjustingWhiteBalance == false` via KVO.
    ///
    /// Returns immediately if already settled. Times out after 2 s (defensive — a
    /// rarely-stalled AWB shouldn't hang calibration). Source: WWDC 2014 §508
    /// manual-controls flow.
    func awaitWBSettled() async {
        await wbSettledWait(avDevice: avDevice)
    }
}

// MARK: - KVO convergence helper (nonisolated free function)

/// Awaits `AVCaptureDevice.isAdjustingWhiteBalance == false` via KVO, with a 2s timeout.
///
/// Uses `ManagedAtomic<Bool>` CAS to guarantee exactly-once continuation resume
/// across the KVO and deadline branches (ADR-30 / CLAUDE.md §8). `withTaskGroup`
/// is explicitly NOT used: a child task suspended on an unresumed
/// `withCheckedContinuation` cannot respond to cancellation, causing the group to
/// hang indefinitely when AWB stalls.
/// Discriminator for `wbApplyAwait` — same handler-bridging shape, two AVF
/// entry points (preset vs gains). The preset case carries a string label
/// that's surfaced in the deadline-miss error log so field traces identify
/// which apply call missed.
private enum WBApplyKind {
    case preset(AVCaptureDevice.WhiteBalanceTemperatureAndTintValues, label: String)
    case gains(AVCaptureDevice.WhiteBalanceGains)
}

/// Locks WB via the requested AVF API and resumes when AVF reports the first
/// buffer carrying the new gains.
///
/// Returns the AVF-supplied buffer timestamp, or `CMTime.invalid` if the 400 ms
/// deadline fired (logged at error level so field traces surface the miss
/// frequency). CAS-races the handler against the deadline so a missed callback
/// can't hang calibration. Mirrors the `wbSettledWait` pattern (ADR-30 /
/// CLAUDE.md §8 — `withTaskGroup` over an unresumed continuation is forbidden).
private func wbApplyAwait(
    avDevice: AVCaptureDevice,
    kind: WBApplyKind
) async -> CMTime {
    nonisolated(unsafe) let dev = avDevice

    return await withCheckedContinuation { (cont: CheckedContinuation<CMTime, Never>) in
        let resumed = ManagedAtomic<Bool>(false)
        let resumeOnce: @Sendable (CMTime) -> Bool = { t in
            let (won, _) = resumed.compareExchange(
                expected: false, desired: true,
                ordering: .sequentiallyConsistent
            )
            if won { cont.resume(returning: t) }
            return won
        }

        switch kind {
        case .preset(let avPreset, _):
            dev.setWhiteBalanceModeLocked(
                whiteBalanceTemperatureAndTintValues: avPreset,
                handler: { t in _ = resumeOnce(t) })
        case .gains(let avGains):
            dev.setWhiteBalanceModeLocked(
                with: avGains,
                completionHandler: { t in _ = resumeOnce(t) })
        }

        let kindLabel: String =
            switch kind {
            case .preset(_, let label): "preset=\(label)"
            case .gains(let g): "gains=(\(g.redGain), \(g.greenGain), \(g.blueGain))"
            }
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if resumeOnce(.invalid) {
                CameraKitLog.error(
                    .engine,
                    "wb-apply handler missed 400ms deadline (\(kindLabel))")
            }
        }
    }
}

/// Awaits `AVCaptureDevice.isAdjustingExposure == false` via KVO, with a 2 s timeout.
///
/// Mirrors `wbSettledWait` exactly — same CAS+deadline structure.
private func aeSettledWait(avDevice: AVCaptureDevice) async {
    if !avDevice.isAdjustingExposure { return }

    nonisolated(unsafe) let dev = avDevice

    // `NSKeyValueObservation` is non-Sendable; share it across the @Sendable KVO
    // closure and deadline Task via `Mutex<…>`, which is unconditionally Sendable.
    // CAS still owns the resume-once invariant; Mutex only serializes token I/O.
    let tokenSlot = Mutex<NSKeyValueObservation?>(nil)

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let resumed = ManagedAtomic<Bool>(false)

        let resumeOnce: @Sendable () -> Void = {
            let (won, _) = resumed.compareExchange(
                expected: false, desired: true,
                ordering: .sequentiallyConsistent
            )
            guard won else { return }
            tokenSlot.withLock { token in
                token?.invalidate()
                token = nil
            }
            cont.resume()
        }

        tokenSlot.withLock { token in
            token = dev.observe(
                \.isAdjustingExposure, options: [.new]
            ) { _, change in
                guard change.newValue == false else { return }
                resumeOnce()
            }
        }

        if !dev.isAdjustingExposure {
            resumeOnce()
            return
        }

        Task {
            try? await Task.sleep(for: .seconds(2))
            resumeOnce()
        }
    }
}

private func wbSettledWait(avDevice: AVCaptureDevice) async {
    if !avDevice.isAdjustingWhiteBalance { return }

    // `AVCaptureDevice` is not `Sendable`; capture via `nonisolated(unsafe) let`
    // so the `@Sendable` closure can close over it without a concurrency diagnostic.
    // Mutations always gate through `lockForConfiguration()` on sessionQueue (ADR-07).
    nonisolated(unsafe) let dev = avDevice

    // `NSKeyValueObservation` is non-Sendable; share it across the @Sendable KVO
    // closure and deadline Task via `Mutex<…>`, which is unconditionally Sendable.
    // CAS still owns the resume-once invariant; Mutex only serializes token I/O.
    let tokenSlot = Mutex<NSKeyValueObservation?>(nil)

    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        let resumed = ManagedAtomic<Bool>(false)

        let resumeOnce: @Sendable () -> Void = {
            let (won, _) = resumed.compareExchange(
                expected: false, desired: true,
                ordering: .sequentiallyConsistent
            )
            guard won else { return }
            tokenSlot.withLock { token in
                token?.invalidate()
                token = nil
            }
            cont.resume()
        }

        // KVO branch: resumes as soon as AWB settles.
        tokenSlot.withLock { token in
            token = dev.observe(
                \.isAdjustingWhiteBalance, options: [.new]
            ) { _, change in
                guard change.newValue == false else { return }
                resumeOnce()
            }
        }

        // Pre-check: if already settled by the time the observer is wired up,
        // resume immediately rather than waiting for the next KVO firing.
        if !dev.isAdjustingWhiteBalance {
            resumeOnce()
            return
        }

        // Deadline branch: resumes after 2 s if AWB hasn't settled yet.
        Task {
            try? await Task.sleep(for: .seconds(2))
            resumeOnce()
        }
    }
}

// MARK: - Format-dump helpers (file-private, used by LiveCaptureDevice.dumpAllFormats)

private func fourCC(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xFF),
        UInt8((code >> 16) & 0xFF),
        UInt8((code >> 8) & 0xFF),
        UInt8(code & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}

private func bitDepthRangeTag(_ pixelFormat: FourCharCode) -> String {
    switch pixelFormat {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "8-bit 4:2:0 FullRange"
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "8-bit 4:2:0 VideoRange"
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: return "10-bit 4:2:0 FullRange"
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return "10-bit 4:2:0 VideoRange"
    case kCVPixelFormatType_422YpCbCr8: return "8-bit 4:2:2"
    case kCVPixelFormatType_422YpCbCr8_yuvs: return "8-bit 4:2:2 (yuvs)"
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: return "10-bit 4:2:2 VideoRange"
    case kCVPixelFormatType_32BGRA: return "8-bit BGRA"
    default: return "unknown"
    }
}
