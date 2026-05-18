import Foundation

/// Active stream configuration emitted on `CameraEngine.streamConfigurationStream()`.
///
/// Fires after `setResolution(...)` resolves to a new camera stream size or
/// after `setCropRegion(...)` mutates the active crop. Phase-2 payload is
/// resolution + crop only; Phase 3's Pigeon `CamStreamConfiguration` adds the
/// texture-ID field (minted by the texture bridge). Phase-2 design §2c / §2d.2.
public struct StreamConfiguration: Sendable, Hashable {
    public let activeCaptureResolution: Size
    public let activeCropRegion: Rect

    public init(activeCaptureResolution: Size, activeCropRegion: Rect) {
        self.activeCaptureResolution = activeCaptureResolution
        self.activeCropRegion = activeCropRegion
    }
}
