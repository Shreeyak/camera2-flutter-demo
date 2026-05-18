import Foundation
import Photos

// MARK: - CameraKit ↔ Photos contract
//
// CameraKit always writes captures (stills + video) to a caller-chosen on-disk
// location first; Photos publication is a *separate*, opt-in step that runs
// after the file is durable. This file owns both halves of that contract.
//
// ## Authorisation
//
// `engine.open()` requests Photos add-only authorisation eagerly, right after
// camera permission. The user sees both prompts back-to-back at first launch;
// neither failure aborts `open()` (Photos is optional). The seam used is
// `PhotosLibraryClient.authorizationProvider`, swappable in tests.
//
// ## Output URL resolution
//
// Every capture call (`engine.captureImage(outputURL:)`,
// `engine.startRecording(options:)` via `RecordingOptions.outputURL`) routes
// the caller's URL through `PhotosLibraryClient.resolve(outputURL:defaultExt:)`:
//
// - `nil`                                → `<Documents>/<ISO-8601-timestamp>.<ext>`
// - `URL(string: "video.mp4")`           → `<Documents>/video.mp4`
// - `URL.documentsDirectory.appendingPathComponent("trial-A/v1.mp4")`
//                                        → as-is; intermediate dirs auto-created
// - any path **outside** `NSHomeDirectory()`
//                                        → throws `EngineError.invalidOutputPath(URL)`
//
// `<Documents>` is user-visible via Files.app (`UIFileSharingEnabled = YES`
// in the app target). `<Library/Caches>`, `<Library/Application Support>`,
// and `<tmp>` are valid sandbox locations but hidden from Files.app.
//
// ## Photos publication (`PhotosDestination`)
//
// | case   | behaviour on success                                          | behaviour on failure                                |
// |--------|---------------------------------------------------------------|-----------------------------------------------------|
// | `.none`| Photos untouched. File at on-disk URL.                        | n/a — no Photos call made.                          |
// | `.copy`| File at on-disk URL **and** a Photos copy.                    | File at on-disk URL only. Photos error reported.    |
// | `.move`| File **only** in Photos; on-disk source removed by Photos.    | File at on-disk URL (degrades to `.copy`'s failure).|
//
// For `.copy` / `.move`, CameraKit calls
// `PHPhotoLibrary.shared().performChanges` with a `PHAssetCreationRequest`
// and `PHAssetResourceCreationOptions(shouldMoveFile: destination == .move)`.
// Resource kind is `.video` for recordings, `.photo` for stills.
//
// ## Failure surface
//
// Photos publish failures are **non-fatal**: the on-disk file is always
// preserved when Photos can't accept it. Failures are reported on two
// channels:
//
// 1. **`engine.errorStream()`** — emits a `CameraError(.unknownError,
//    isFatal: false)` whose `message` is the `describe(_:)` output for the
//    underlying `NSError`.
// 2. **Device log** (`CameraKitLog.error`) — same message, prefixed with
//    `[recording]` or `[still]` so it's greppable.
//
// Common error codes (all `PHPhotosError.errorDomain`):
// - `.accessUserDenied` (3311) — user revoked Photos in Settings.
// - `.accessRestricted` (3300) — Screen Time / MDM / parental controls.
// - `.invalidResource` (3303) — file unreadable or unsupported format.
// - `.networkAccessRequired` / `.networkError` — iCloud Photos sync issue.
//
// `PhotosLibraryClient.describe(_:)` translates each known code to a typed
// name + suggested user action; unknown codes fall through to bare NSError
// fields. UI consumers should subscribe to `errorStream()` and surface
// `describe`'s output (which is already inside the `CameraError.message`)
// to the user when severity warrants — no re-mapping needed.
//
// ## What CameraKit does *not* do
//
// - No retry. A failed publish is reported once and not retried; the file
//   sits at `outputURL` for the caller to dispose of.
// - No deduplication. Calling `engine.captureImage(photosDestination: .copy)`
//   twice with the same `outputURL` adds two assets to Photos.
// - No `PhotosKit` fancy types — assets are added as raw resources via
//   `PHAssetCreationRequest`. Album placement, geotagging, Live Photos,
//   bursts, and edits are out of scope.
// - No background publication. `.copy` / `.move` block their caller (engine
//   wrapper) until `performChanges` returns; expect a few hundred ms of
//   added latency on `engine.stopRecording` / `engine.captureImage`.

/// Decides whether and how to publish a captured file to the Photos library.
///
/// - `.none`: Photos library is not touched. File lives only at the on-disk URL.
/// - `.copy`: File persists at the on-disk URL AND a copy is added to Photos
///   (uses `PHAssetResourceCreationOptions.shouldMoveFile = false`). Use this
///   when the caller wants the file accessible via Files.app *and* via Photos.
/// - `.move`: Best-effort move into Photos (`shouldMoveFile = true`). On
///   success the on-disk file is removed from the sandbox and the URI returned
///   by `captureImage` / `stopRecording` points to a no-longer-existent path.
///   On failure (denied auth, Photos error, etc.) the file remains at the
///   on-disk URL — equivalent to `.copy`'s failure path. Use this when zero
///   sandbox footprint after capture is the goal.
///
/// Photos failures are non-fatal: the on-disk file is always preserved when
/// Photos can't accept it. Use the engine's `errorStream()` to surface the
/// failure to the UI if desired.
public enum PhotosDestination: String, Sendable, Hashable, Codable {
    case none
    case copy
    case move
}

/// Shared helper for routing CameraKit captures into the user-visible filesystem
/// and the Photos library.
///
/// Hosts the URL-resolution rule (`resolve`) used by both stills and video, and
/// the single Photos publish entry point (`publish`) that dispatches on
/// `PhotosDestination`. The seam `authorizationProvider` is overridable in tests
/// to avoid live `PHPhotoLibrary` calls.
enum PhotosLibraryClient {

    /// Test seam — defaults to `PHPhotoLibrary.requestAuthorization(for: .addOnly)`.
    ///
    /// `nonisolated(unsafe)` per the Bug-5 precedent in `CameraEngine.swift`:
    /// single-writer-per-test in unit tests, never mutated in production.
    nonisolated(unsafe) static var authorizationProvider: @Sendable () async -> PHAuthorizationStatus = {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }

    /// Resolve a caller-supplied output URL to an absolute on-disk path inside
    /// the app sandbox, creating parent directories as needed.
    ///
    /// Resolution rules:
    /// - `nil` → `<Documents>/<ISO8601-timestamp>.<defaultExt>`
    /// - URL whose `path` contains no slash (e.g. `URL(string: "video.mp4")`) →
    ///   `<Documents>/<filename>` (the `defaultExt` is ignored — caller's
    ///   filename extension wins)
    /// - URL with a path → used as-is
    ///
    /// Valid output locations (any path inside `NSHomeDirectory()`):
    /// - `<App Sandbox>/Documents/...` — recommended. User-visible via
    ///   Files.app when `UIFileSharingEnabled = YES` is set on the app target.
    /// - `<App Sandbox>/Library/Caches/...` — hidden from Files.app; iOS may
    ///   purge under storage pressure.
    /// - `<App Sandbox>/Library/Application Support/...` — hidden; backed up
    ///   to iCloud by default.
    /// - `<App Sandbox>/tmp/...` — hidden; iOS may purge anytime.
    ///
    /// Invalid (throws `EngineError.invalidOutputPath`):
    /// - Any path outside `NSHomeDirectory()` (system paths, other apps'
    ///   sandboxes, `/var`, `/System`, etc.). iOS apps are kernel-sandboxed;
    ///   even with the right permissions the kernel rejects writes outside the
    ///   app container.
    ///
    /// Parent directories of the resolved path are auto-created via
    /// `FileManager.default.createDirectory(at:withIntermediateDirectories: true)`.
    static func resolve(outputURL: URL?, defaultExt: String) throws -> URL {
        let resolved: URL
        if let outputURL {
            if !outputURL.path.contains("/") {
                resolved = URL.documentsDirectory
                    .appendingPathComponent(outputURL.lastPathComponent)
            } else {
                resolved = outputURL
            }
        } else {
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            resolved = URL.documentsDirectory
                .appendingPathComponent("\(timestamp).\(defaultExt)")
        }

        // Accept both forms of the sandbox root: NSHomeDirectory() returns
        // `/var/mobile/Containers/Data/Application/<UUID>` while
        // `FileManager.default.temporaryDirectory` (and any URL that has
        // round-tripped through Foundation canonicalization) returns
        // `/private/var/mobile/...`. The two are the same physical path —
        // iOS exposes `/private/var` as the canonical location with `/var`
        // as a stable alias. `URL.resolvingSymlinksInPath()` does NOT
        // collapse `/var` → `/private/var` on iOS in practice, so we check
        // both prefixes explicitly rather than relying on canonicalization.
        let home = NSHomeDirectory()
        let homeFromPrivate = "/private" + home
        guard
            resolved.path.hasPrefix(home)
                || resolved.path.hasPrefix(homeFromPrivate)
        else {
            throw EngineError.invalidOutputPath(resolved)
        }

        try FileManager.default.createDirectory(
            at: resolved.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        return resolved
    }

    /// Publish a captured file to the Photos library according to the requested
    /// destination policy.
    ///
    /// - `.none`: returns immediately; no Photos interaction.
    /// - `.copy`: Photos adds a copy; source file unchanged on disk.
    /// - `.move`: Photos takes filesystem ownership; source file removed from
    ///   the sandbox on success. On failure the source file is preserved.
    ///
    /// Throws on Photos API failure. Callers should catch and log; the source
    /// file remains intact whether the call throws or returns.
    static func publish(
        url: URL,
        kind: PHAssetResourceType,
        destination: PhotosDestination
    ) async throws {
        switch destination {
        case .none:
            return
        case .copy, .move:
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.shouldMoveFile = (destination == .move)
                req.addResource(with: kind, fileURL: url, options: opts)
            }
        }
    }

    /// Translate a Photos publish error into a self-contained, human-actionable string.
    ///
    /// Output shape: typed `PHPhotosError.Code` name + likely cause +
    /// suggested user action when known. Falls back to the underlying
    /// NSError fields for unrecognised codes.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == PHPhotosError.errorDomain else {
            return "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
        }
        let codeName: String
        let hint: String
        switch PHPhotosError.Code(rawValue: ns.code) {
        case .accessUserDenied:
            codeName = "accessUserDenied"
            hint =
                "User denied Photos access. Re-enable in Settings → eva-swift-stitch → "
                + "Photos (Add Photos Only or All Photos)."
        case .accessRestricted:
            codeName = "accessRestricted"
            hint = "Photos access blocked by Screen Time, MDM, or parental controls. Cannot be granted from in-app."
        case .invalidResource:
            codeName = "invalidResource"
            hint = "Photos rejected the source file (corrupt, unsupported format, or unreachable)."
        case .userCancelled:
            codeName = "userCancelled"
            hint = "User cancelled the Photos operation."
        case .libraryVolumeOffline:
            codeName = "libraryVolumeOffline"
            hint = "The Photos library is on an offline volume."
        case .networkAccessRequired:
            codeName = "networkAccessRequired"
            hint = "iCloud Photos requires network access to complete this operation."
        case .networkError:
            codeName = "networkError"
            hint = "iCloud Photos network error; retry once connectivity returns."
        case .changeNotSupported:
            codeName = "changeNotSupported"
            hint = "Requested change is not supported by Photos for this asset type."
        case .operationInterrupted:
            codeName = "operationInterrupted"
            hint = "Photos operation interrupted; safe to retry."
        case .identifierNotFound:
            codeName = "identifierNotFound"
            hint = "Asset identifier not present in the Photos library."
        default:
            codeName = "code=\(ns.code)"
            hint = ns.localizedDescription
        }
        return "PHPhotosError.\(codeName) — \(hint)"
    }
}
