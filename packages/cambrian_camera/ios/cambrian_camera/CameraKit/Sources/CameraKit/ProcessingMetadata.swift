// MARK: - ProcessingMetadata (Stage 05 — permanent)
//
// Extracted from FrameSet.swift into its own file per brief Stage-05 §4.
// The struct existed since the FrameSet stub was introduced; Stage 05 gives
// it a dedicated file and makes the Mutex<UniformStorage> snapshot path
// its construction site.

/// Per-frame snapshot of color-transform and crop parameters applied by the GPU.
///
/// Constructed during `MetalPipeline.encode()` from the `Mutex<UniformStorage>`
/// snapshot so the consumer-visible metadata exactly matches what the GPU rendered.
///
/// Attached to `FrameSet.processing`; fully populated in Stage 06 when
/// `FrameSet` is actually constructed on the delivery queue.
public struct ProcessingMetadata: Sendable, Hashable {
    public let cropRegion: Rect
    public let brightness: Float
    public let contrast: Float
    public let saturation: Float
    public let gamma: Float
    public let whiteBalanceGains: WhiteBalanceGains

    public init(
        cropRegion: Rect,
        brightness: Float,
        contrast: Float,
        saturation: Float,
        gamma: Float,
        whiteBalanceGains: WhiteBalanceGains
    ) {
        self.cropRegion = cropRegion
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.whiteBalanceGains = whiteBalanceGains
    }

    /// Constructs a `ProcessingMetadata` from a `UniformStorage` snapshot.
    ///
    /// Called inside the `Mutex.withLock` closure in `MetalPipeline.encode()`
    /// so the metadata is always coherent with the GPU command.
    ///
    /// Takes individual field copies (not `borrowing UniformStorage`) to avoid
    /// move-only ownership complications at the `inout` call site.
    init(color: ColorUniform, crop: CropUniform) {
        cropRegion = Rect(
            x: Int(crop.originX),
            y: Int(crop.originY),
            width: Int(crop.width),
            height: Int(crop.height)
        )
        brightness = color.brightness
        contrast = color.contrast
        saturation = color.saturation
        gamma = color.gamma
        // Black balance components are not exposed on ProcessingMetadata today;
        // whiteBalanceGains carries the white-balance offset (Stage 06 populates
        // from CaptureMetadata; for now default to neutral).
        whiteBalanceGains = WhiteBalanceGains(red: 1.0, green: 1.0, blue: 1.0)
    }
}
