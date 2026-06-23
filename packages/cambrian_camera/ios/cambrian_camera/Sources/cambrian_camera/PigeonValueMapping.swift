import CameraKit
import Foundation

/// Pure conversions between Pigeon wire types (`Cam*`) and CameraKit engine
/// types. Spec §3 mapping table. iOS-side §5.3 silent-ignore rules apply.
/// D-2P-01 `focusDistance` ↔ `focusDistanceDiopters` rename happens here only.
enum PigeonValueMapping {

    // MARK: - Settings

    /// `CamSettings` → `CameraSettings`. Drops Android-only fields and
    /// `cropOutputSize` (handled separately by the HostApi impl via
    /// `engine.setCropRegion`). Unknown enum strings → nil ("don't change").
    static func toCameraSettings(_ cam: CamSettings) -> CameraSettings {
        CameraSettings(
            isoMode: cameraMode(from: cam.isoMode),
            iso: cam.iso.map { Int($0) },
            exposureMode: cameraMode(from: cam.exposureMode),
            exposureTimeNs: cam.exposureTimeNs,
            focusMode: cameraMode(from: cam.focusMode),
            // D-2P-01: wire `focusDistanceDiopters` → engine `focusDistance`
            // (iOS uses normalized lensPosition under the hood; engine field
            // name is legacy).
            focusDistance: cam.focusDistanceDiopters,
            wbMode: whiteBalanceMode(from: cam.wbMode),
            wbGainR: cam.wbGainR,
            wbGainG: cam.wbGainG,
            wbGainB: cam.wbGainB,
            zoomRatio: cam.zoomRatio,
            evCompensation: cam.evCompensation.map { Int($0) }
            // §5.3 silent-ignore on iOS: noiseReductionMode, edgeMode.
            // cropOutputSize is handled separately by the HostApi impl.
        )
    }

    /// `CameraSettings` → `CamSettings`. Inverse of `toCameraSettings`.
    /// iOS-only-drop fields are always nil on the wire.
    static func toCamSettings(_ s: CameraSettings) -> CamSettings {
        CamSettings(
            isoMode: s.isoMode?.rawValue,
            iso: s.iso.map { Int64($0) },
            exposureMode: s.exposureMode?.rawValue,
            exposureTimeNs: s.exposureTimeNs,
            focusMode: s.focusMode?.rawValue,
            // D-2P-01 inverse rename.
            focusDistanceDiopters: s.focusDistance,
            wbMode: s.wbMode?.rawValue,
            wbGainR: s.wbGainR,
            wbGainG: s.wbGainG,
            wbGainB: s.wbGainB,
            zoomRatio: s.zoomRatio,
            noiseReductionMode: nil,
            edgeMode: nil,
            evCompensation: s.evCompensation.map { Int64($0) },
            cropOutputSize: nil
        )
    }

    // MARK: - Capabilities

    /// `SessionCapabilities` → `CamCapabilities`. The preview lane texture ID is
    /// carried here (minted at `open`, stable for the session): the engine
    /// `HandleRegistry` handle and the Flutter texture-registry IDs are
    /// unrelated on iOS, so the Dart side must read `previewTextureId` from the
    /// bootstrap capabilities rather than assuming `handle == texture id`.
    static func toCamCapabilities(
        _ caps: SessionCapabilities,
        previewTextureId: Int64
    ) -> CamCapabilities {
        let sensorWidth = Int64(caps.activeCaptureResolution.width)
        let sensorHeight = Int64(caps.activeCaptureResolution.height)
        let crop = caps.activeCropRegion
        let streamWidth: Int64 = crop.width > 0 ? Int64(crop.width) : sensorWidth
        let streamHeight: Int64 = crop.height > 0 ? Int64(crop.height) : sensorHeight

        return CamCapabilities(
            supportedSizes: caps.supportedSizes.map {
                CamSize(width: Int64($0.width), height: Int64($0.height))
            },
            isoMin: Int64(caps.isoRange.lowerBound),
            isoMax: Int64(caps.isoRange.upperBound),
            exposureTimeMinNs: caps.exposureDurationRangeNs.lowerBound,
            exposureTimeMaxNs: caps.exposureDurationRangeNs.upperBound,
            focusMin: caps.focusRange.lowerBound,
            focusMax: caps.focusRange.upperBound,
            zoomMin: caps.zoomRange.lowerBound,
            zoomMax: caps.zoomRange.upperBound,
            evCompMin: Int64(caps.evCompensationRange.lowerBound.rounded(.down)),
            evCompMax: Int64(caps.evCompensationRange.upperBound.rounded(.up)),
            // iOS exposes a continuous Float EV-bias range with no hardware
            // step value, so 1 integer step = 1 EV stop is the natural
            // mapping (Android reports 0.5).
            evCompensationStep: 1.0,
            previewTextureId: previewTextureId,
            streamWidth: streamWidth,
            streamHeight: streamHeight,
            sensorStreamWidth: sensorWidth,
            sensorStreamHeight: sensorHeight,
            streamPixelFormat: caps.streamPixelFormat
        )
    }

    // MARK: - Stream configuration

    /// `StreamConfiguration` → `CamStreamConfiguration`.
    /// Texture IDs are stable across the open session and passed in by caller.
    static func toCamStreamConfiguration(
        _ cfg: StreamConfiguration,
        previewTextureId: Int64
    ) -> CamStreamConfiguration {
        let crop = cfg.activeCropRegion
        let cropWidth: Int64? = (crop.width > 0 && crop.height > 0) ? Int64(crop.width) : nil
        let cropHeight: Int64? = (crop.width > 0 && crop.height > 0) ? Int64(crop.height) : nil
        return CamStreamConfiguration(
            captureWidth: Int64(cfg.activeCaptureResolution.width),
            captureHeight: Int64(cfg.activeCaptureResolution.height),
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            previewTextureId: previewTextureId
        )
    }

    // MARK: - State + errors

    /// `SessionState` → `CamStateUpdate`. Raw values are already the spec
    /// strings ("opening", "streaming", …).
    static func toCamStateUpdate(_ state: SessionState) -> CamStateUpdate {
        CamStateUpdate(state: state.rawValue)
    }

    /// `CameraError` → `CamError`. Maps `ErrorCode` to the wire-friendly
    /// `CamErrorCode` enum; never produces Android-only codes.
    static func toCamError(_ err: CameraError) -> CamError {
        CamError(code: camErrorCode(from: err.code), message: err.message, isFatal: err.isFatal)
    }

    // MARK: - Frame results + samples

    /// `FrameResult` → `CamFrameResult`. Applies D-2P-01 rename for focus.
    static func toCamFrameResult(_ r: FrameResult) -> CamFrameResult {
        CamFrameResult(
            iso: r.iso.map { Int64($0) },
            exposureTimeNs: r.exposureTimeNs,
            focusDistanceDiopters: r.focusDistance,
            wbGainR: r.wbGainR,
            wbGainG: r.wbGainG,
            wbGainB: r.wbGainB
        )
    }

    /// `RgbSample` → `CamRgbSample`. Direct field copy.
    static func toCamRgbSample(_ s: RgbSample) -> CamRgbSample {
        CamRgbSample(r: s.r, g: s.g, b: s.b)
    }

    // MARK: - Processing parameters

    /// `ProcessingParameters` → `CamProcessingParams`. Direct field copy
    /// (matches by name; init field order differs from the engine type).
    static func toCamProcessingParams(_ p: ProcessingParameters) -> CamProcessingParams {
        CamProcessingParams(
            blackR: p.blackR,
            blackG: p.blackG,
            blackB: p.blackB,
            gamma: p.gamma,
            brightness: p.brightness,
            contrast: p.contrast,
            saturation: p.saturation
        )
    }

    /// `CamProcessingParams` → `ProcessingParameters`. Inverse field copy.
    static func toProcessingParameters(_ p: CamProcessingParams) -> ProcessingParameters {
        ProcessingParameters(
            brightness: p.brightness,
            contrast: p.contrast,
            saturation: p.saturation,
            blackR: p.blackR,
            blackG: p.blackG,
            blackB: p.blackB,
            gamma: p.gamma
        )
    }

    // MARK: - Photos destination

    /// `CamPhotosDestination?` → `PhotosDestination`. `nil` or
    /// `saveToLibrary == false` → `.none`; `true` → `.copy` (keeps the file
    /// on disk too, per plan §5.4). `albumName` is intentionally ignored —
    /// CameraKit's `PhotosLibraryClient` doesn't target a specific album.
    static func toPhotosDestination(_ dest: CamPhotosDestination?) -> PhotosDestination {
        guard let dest, dest.saveToLibrary else { return .none }
        return .copy
    }

    // MARK: - Permissions

    /// `CameraPermissionStatus` → wire string. Matches the spec rawValues
    /// exactly: "notDetermined" / "denied" / "restricted" / "authorized".
    static func toCamPermissionStatus(_ s: CameraPermissionStatus) -> String {
        s.rawValue
    }

    // MARK: - Capture result

    /// Trivial constructor mirror, for call-site consistency with the other
    /// converters.
    static func toCamCaptureResult(filePath: String?, phAssetLocalId: String?) -> CamCaptureResult {
        CamCaptureResult(filePath: filePath, phAssetLocalId: phAssetLocalId)
    }

    // MARK: - Private enum mappers

    /// Wire enum string → `CameraMode`. Unknown → nil ("don't change").
    private static func cameraMode(from raw: String?) -> CameraMode? {
        switch raw {
        case "auto": return .auto
        case "manual": return .manual
        default: return nil
        }
    }

    /// Wire enum string → `WhiteBalanceMode`. Unknown → nil ("don't change").
    private static func whiteBalanceMode(from raw: String?) -> WhiteBalanceMode? {
        switch raw {
        case "auto": return .auto
        case "manual": return .manual
        case "locked": return .locked
        default: return nil
        }
    }

    /// `ErrorCode` → `CamErrorCode`. Android-only codes (`cameraService`,
    /// `cameraDisabled`, `maxCamerasInUse`, `previewSurfaceLost`,
    /// `pipelineError`) are never produced from this mapping.
    private static func camErrorCode(from code: ErrorCode) -> CamErrorCode {
        switch code {
        case .cameraNotFound: return .cameraDevice
        case .cameraInUse: return .cameraInUse
        case .permissionDenied: return .permissionDenied
        case .cameraAccessError: return .cameraAccessError
        case .cameraDisconnected: return .cameraDisconnected
        case .configurationFailed: return .configurationFailed
        case .captureFailure: return .captureFailure
        // No dedicated wire code for recording start/run failures; reuse
        // captureFailure (closest semantic match).
        case .recordingStartFailed: return .captureFailure
        case .recordingFailed: return .captureFailure
        case .recordingTruncated: return .recordingTruncated
        case .frameStall: return .frameStall
        case .maxRetriesExceeded: return .maxRetriesExceeded
        case .unknownError: return .unknown
        case .settingsConflict: return .settingsConflict
        // No wire equivalent for invalidFormat / invalidState; collapse to
        // nearest available code.
        case .invalidFormat: return .configurationFailed
        case .fpsDegraded: return .fpsDegraded
        case .aeConvergenceTimeout: return .aeConvergenceTimeout
        case .invalidState: return .unknown
        case .hardwareError: return .cameraDevice
        }
    }
}
