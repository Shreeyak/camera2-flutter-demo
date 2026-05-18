import CoreGraphics
import Foundation

// MARK: - Core geometry types

public struct Size: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct Rect: Sendable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Session capabilities

/// Returned by CameraEngine.open(configuration:) per domain-revised/10-api-contract.md §SessionCapabilities.
public struct SessionCapabilities: Sendable, Hashable {
    public let supportedSizes: [Size]
    public let previewTextureId: Int
    public let naturalTextureId: Int
    public let activeCaptureResolution: Size
    public let activeCropRegion: Rect
    /// Pixel format string of the *lane buffer* returned by
    /// `currentPixelBuffer(stream:)` — what the Phase-3 zero-copy texture
    /// bridge sees.
    ///
    /// Default (`OpenConfiguration.lanesEightBit == true`): `"BGRA8"`
    /// (`kCVPixelFormatType_32BGRA`, `.bgra8Unorm`) — Apple's
    /// `CVMetalTextureCache`-canonical 32-bit RGBA-family format on iOS.
    /// Opt-out (`lanesEightBit == false`): `"RGBA16F"`
    /// (`kCVPixelFormatType_64RGBAHalf`, `.rgba16Float`).
    ///
    /// The **texture accessors** — `currentTexture()`,
    /// `currentProcessedTexture()`, `currentTrackerTexture()` — always return
    /// `.rgba16Float` regardless of the flag (Phase-2 §2c + pre-Phase-3 RGBA8
    /// asymmetry). Tracker buffer also stays RGBA16F either way.
    ///
    /// Note this is **not** the camera *source* format (YUV `420f`, converted
    /// by MetalPipeline Pass-1).
    public let streamPixelFormat: String
    public let isoRange: ClosedRange<Float>
    public let exposureDurationRangeNs: ClosedRange<Int64>
    /// Lens-position range — always `0.0...1.0` on iOS.
    ///
    /// `AVCaptureDevice.lensPosition` is normalized, not real diopters. Kept
    /// for shape parity with the Pigeon contract's `focusMin`/`focusMax`.
    /// Phase-2 design §2c.
    public let focusRange: ClosedRange<Double>
    /// `AVCaptureDevice.minAvailableVideoZoomFactor` ... `maxAvailableVideoZoomFactor`.
    ///
    /// Returned for the active format. Phase-2 design §2c.
    public let zoomRange: ClosedRange<Double>
    /// `AVCaptureDevice.minExposureTargetBias` ... `maxExposureTargetBias`.
    ///
    /// Reported in EV stops (signed). Phase-2 design §2c.
    public let evCompensationRange: ClosedRange<Float>

    public init(
        supportedSizes: [Size],
        previewTextureId: Int,
        naturalTextureId: Int,
        activeCaptureResolution: Size,
        activeCropRegion: Rect,
        streamPixelFormat: String,
        isoRange: ClosedRange<Float>,
        exposureDurationRangeNs: ClosedRange<Int64>,
        focusRange: ClosedRange<Double>,
        zoomRange: ClosedRange<Double>,
        evCompensationRange: ClosedRange<Float>
    ) {
        self.supportedSizes = supportedSizes
        self.previewTextureId = previewTextureId
        self.naturalTextureId = naturalTextureId
        self.activeCaptureResolution = activeCaptureResolution
        self.activeCropRegion = activeCropRegion
        self.streamPixelFormat = streamPixelFormat
        self.isoRange = isoRange
        self.exposureDurationRangeNs = exposureDurationRangeNs
        self.focusRange = focusRange
        self.zoomRange = zoomRange
        self.evCompensationRange = evCompensationRange
    }
}

/// Startup arguments for CameraEngine.open(configuration:).
public struct OpenConfiguration: Sendable, Hashable {
    public var cameraId: String?
    public var captureResolution: Size?
    public var cropRegion: Rect?
    /// Hardware settings to apply during session setup, before the first frame
    /// is delivered.
    ///
    /// Folds the Pigeon contract's `open(cameraId, settings)` shape into
    /// CameraKit's structural `OpenConfiguration` so the requested settings are
    /// live from frame one (no defaults-then-snap flicker). Phase-2 design
    /// §2a. Applied via the same `updateSettings` merge+coupling+commit path
    /// after `setupSession` returns and before the first `startRunning`.
    public var initialSettings: CameraSettings?
    /// When true (default), `currentPixelBuffer(stream: .natural)` and
    /// `currentPixelBuffer(stream: .processed)` return BGRA8 buffers
    /// (`kCVPixelFormatType_32BGRA`, `MTLPixelFormat.bgra8Unorm`) — Apple's
    /// `CVMetalTextureCache`-canonical 32-bit RGBA-family format on iOS.
    ///
    /// When false, those accessors return the internal RGBA16F lane buffers
    /// (`kCVPixelFormatType_64RGBAHalf`). Tracker is RGBA16F either way.
    ///
    /// Default true → matches the Flutter plugin's expected wire format on
    /// the Phase-3 zero-copy bridge. Internal pipeline (Pass-1/2/4/5/6,
    /// calibration sampling, MTKView preview, still capture) stays RGBA16F
    /// regardless. Texture accessors (`currentTexture()` /
    /// `currentProcessedTexture()` / `currentTrackerTexture()`) always return
    /// `.rgba16Float`. See
    /// `docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md`.
    public var lanesEightBit: Bool

    public init(
        cameraId: String? = nil,
        captureResolution: Size? = nil,
        cropRegion: Rect? = nil,
        initialSettings: CameraSettings? = nil,
        lanesEightBit: Bool = true
    ) {
        self.cameraId = cameraId
        self.captureResolution = captureResolution
        self.cropRegion = cropRegion
        self.initialSettings = initialSettings
        self.lanesEightBit = lanesEightBit
    }
}

// MARK: - Settings types (compressed here per Stage 01 type-compression decision)

public enum CameraMode: String, Sendable, Hashable, Codable {
    case auto
    case manual
}

public enum WhiteBalanceMode: String, Sendable, Hashable, Codable {
    case auto
    case locked
    case manual
}

/// Apple's named WB temperature/tint presets.
///
/// Each case maps 1:1 to `AVCaptureDevice.WhiteBalanceTemperatureAndTintValues`
/// static properties (iOS 26.0+). Underlying Kelvin/tint values are
/// sensor-calibrated and not published by Apple.
public enum WhiteBalancePreset: String, Sendable, Hashable {
    case daylight
    case cloudy
    case shadow
    case tungsten
    case fluorescent
}

/// Partial-update settings object.
///
/// Per domain-revised/10-api-contract.md §CameraSettings.
/// Every field is optional; null = "do not change." Full merge logic arrives Stage 03.
public struct CameraSettings: Sendable, Hashable, Codable {
    public var isoMode: CameraMode?
    public var iso: Int?
    public var exposureMode: CameraMode?
    public var exposureTimeNs: Int64?
    public var focusMode: CameraMode?
    public var focusDistance: Double?
    public var wbMode: WhiteBalanceMode?
    public var wbGainR: Double?
    public var wbGainG: Double?
    public var wbGainB: Double?
    public var zoomRatio: Double?
    public var evCompensation: Int?

    public init(
        isoMode: CameraMode? = nil,
        iso: Int? = nil,
        exposureMode: CameraMode? = nil,
        exposureTimeNs: Int64? = nil,
        focusMode: CameraMode? = nil,
        focusDistance: Double? = nil,
        wbMode: WhiteBalanceMode? = nil,
        wbGainR: Double? = nil,
        wbGainG: Double? = nil,
        wbGainB: Double? = nil,
        zoomRatio: Double? = nil,
        evCompensation: Int? = nil
    ) {
        self.isoMode = isoMode
        self.iso = iso
        self.exposureMode = exposureMode
        self.exposureTimeNs = exposureTimeNs
        self.focusMode = focusMode
        self.focusDistance = focusDistance
        self.wbMode = wbMode
        self.wbGainR = wbGainR
        self.wbGainG = wbGainG
        self.wbGainB = wbGainB
        self.zoomRatio = zoomRatio
        self.evCompensation = evCompensation
    }
}

/// GPU color-processing shader parameters.
///
/// All fields required. Full implementation Stage 04.
public struct ProcessingParameters: Sendable, Hashable, Codable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    /// Per-channel black-balance pedestal.
    ///
    /// The GPU pipeline subtracts these values from the graded image as the
    /// **final** color step, after brightness, contrast, saturation, and
    /// gamma. Range typically `[0, 0.5]`. See `Shaders/ColorShaders.metal`
    /// for the exact order.
    public var blackR: Double
    public var blackG: Double
    public var blackB: Double
    public var gamma: Double

    public init(
        brightness: Double = 0.0,
        contrast: Double = 1.0,
        saturation: Double = 0.0,
        blackR: Double = 0.0,
        blackG: Double = 0.0,
        blackB: Double = 0.0,
        gamma: Double = 1.0
    ) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.blackR = blackR
        self.blackG = blackG
        self.blackB = blackB
        self.gamma = gamma
    }

    public static let identity = ProcessingParameters()
}
