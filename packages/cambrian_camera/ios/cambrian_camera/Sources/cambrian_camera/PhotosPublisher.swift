import Foundation
import Photos

/// Publishes a captured file (still image) to the iOS Photos library,
/// returning the PHAsset's `localIdentifier` so the Dart-side bridge can
/// surface it on `CamCaptureResult.phAssetLocalId`.
///
/// The engine's `CameraEngine.captureImage`/`captureNaturalPicture` methods
/// can publish to Photos themselves but only return the on-disk file path —
/// they never expose the PHAsset's local ID. To meet the Pigeon wire
/// contract (`phAssetLocalId` populated when `saveToLibrary == true`), the
/// plugin layer takes ownership of the Photos publish path and captures the
/// identifier itself.
enum PhotosPublisher {

    /// Errors raised by `publishStill`. Distinguishes a Photos-framework
    /// failure (auth denied, invalid resource, network error, etc.) from a
    /// purely defensive guard for a missing placeholder.
    enum PublishError: Error {
        /// `PHPhotoLibrary.performChanges` threw. The associated error is
        /// the underlying `PHPhotosError` (or other `NSError`) — translate
        /// via `PhotosLibraryClient.describe(_:)` for user-facing messages.
        case phPhotoLibraryFailed(Error)
        /// `placeholderForCreatedAsset` returned `nil` inside the change
        /// block. Should never happen in practice — Apple's API contract
        /// guarantees a placeholder for `forAsset()` requests — but the
        /// optional chain forces us to handle it.
        case placeholderMissing
    }

    /// Publishes the file at `fileURL` to Photos as a still image (.photo).
    ///
    /// Returns the resulting asset's `localIdentifier`. The on-disk file at
    /// `fileURL` is NOT touched by this method — the caller decides whether
    /// to delete it after success (typically yes, when `saveToLibrary` is
    /// true the contract says the wire result's `filePath` field is null).
    ///
    /// - Parameter fileURL: Absolute file URL of the on-disk capture. Must
    ///   exist and be readable by the Photos process.
    /// - Returns: The new asset's `localIdentifier` (an opaque string the
    ///   Dart side can later resolve via `PHAsset.fetchAssets(...)`).
    /// - Throws: `PublishError.phPhotoLibraryFailed` on Photos API failure;
    ///   `PublishError.placeholderMissing` if the change block did not
    ///   produce a placeholder (should never happen — defensive).
    static func publishStill(fileURL: URL) async throws -> String {
        var assetLocalId: String?
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                // shouldMoveFile=false — the caller manages on-disk lifetime;
                // moving here would race the caller's
                // `try? FileManager.default.removeItem(at:)` cleanup and
                // could leave the file in an indeterminate state on failure.
                opts.shouldMoveFile = false
                req.addResource(with: .photo, fileURL: fileURL, options: opts)
                // Capture the placeholder identifier BEFORE the change block
                // returns. Apple's docs guarantee the placeholder is valid
                // from inside `performChanges`; the `localIdentifier` it
                // exposes matches the eventual `PHAsset.localIdentifier`.
                assetLocalId = req.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw PublishError.phPhotoLibraryFailed(error)
        }
        guard let id = assetLocalId else {
            throw PublishError.placeholderMissing
        }
        return id
    }
}
