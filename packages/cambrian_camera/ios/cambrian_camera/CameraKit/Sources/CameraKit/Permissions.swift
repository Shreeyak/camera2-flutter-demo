import AVFoundation
import Photos

/// Permission status for camera + Photos library.
///
/// Cross-platform-neutral enum mapping iOS `AVAuthorizationStatus` /
/// `PHAuthorizationStatus` to a single shape the Pigeon contract can carry.
/// Phase-2 design §2d.6.
public enum CameraPermissionStatus: String, Sendable, Hashable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

extension CameraEngine {

    /// Camera authorization status (`.video`).
    ///
    /// `nonisolated static` so the Flutter side can query before instantiating
    /// an engine handle (handle creation requires authorization). Phase-2 §2d.6.
    public nonisolated static func cameraPermissionStatus() -> CameraPermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized: return .authorized
        @unknown default: return .denied
        }
    }

    /// Triggers the system camera-permission prompt.
    ///
    /// Returns immediately if already prompted. Returns the status after the
    /// prompt resolves.
    public nonisolated static func requestCameraPermission() async -> CameraPermissionStatus {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return cameraPermissionStatus()
    }

    /// Photos library add-only authorization status.
    public nonisolated static func photosAddPermissionStatus() -> CameraPermissionStatus {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        case .authorized, .limited: return .authorized
        @unknown default: return .denied
        }
    }

    /// Triggers the system Photos add-only prompt.
    public nonisolated static func requestPhotosAddPermission() async -> CameraPermissionStatus {
        _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return photosAddPermissionStatus()
    }
}
