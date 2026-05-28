import Foundation
import UniformTypeIdentifiers

// MARK: - Output path + format resolution
//
// CameraKit derives the on-disk file *format* from the caller's filename
// extension, and resolves the caller's URL to a concrete sandbox path. Both
// halves live here so the "what do we write, and where" decision is a single,
// independently-testable unit. (The path-placement / sandbox logic was formerly
// `PhotosLibraryClient.resolve`; it was never about the Photos library.)
//
// ## Image rules (`captureImage` / `captureNaturalPicture`)
//
// | caller `outputURL`            | result                                    |
// |-------------------------------|-------------------------------------------|
// | `nil` (no name)               | `<Documents>/<timestamp>.png`, PNG        |
// | name with no extension        | throws `StillCaptureError.missingFileExtension` |
// | `.png` / `.PNG`               | PNG                                       |
// | `.jpg` / `.jpeg`              | JPEG (fixed high quality, not surfaced)   |
// | `.tif` / `.tiff`             | TIFF                                      |
// | any other extension           | throws `StillCaptureError.unsupportedImageFormat` |
//
// ## Video rules (`startRecording`)
//
// | caller `outputURL`            | result                                    |
// |-------------------------------|-------------------------------------------|
// | `nil` (no name)               | `<Documents>/<timestamp>.mp4`, MP4        |
// | name with no extension        | throws `RecordingError.missingFileExtension` |
// | `.mp4`                        | MP4 (HEVC, internal defaults)             |
// | any other extension           | throws `RecordingError.unsupportedVideoFormat` |
//
// Extension matching is case-insensitive. Any path outside the app sandbox
// throws `EngineError.invalidOutputPath` (kernel rejects writes there anyway).

/// On-disk still-image encoding format, derived from the caller's filename
/// extension.
///
/// Backed by ImageIO (`CGImageDestination`), which natively supports all three —
/// no third-party encoder is needed. The `lossyQuality` for JPEG is a fixed
/// high-quality default that is deliberately not surfaced to callers.
enum ImageFileFormat {
    case png
    case jpeg
    case tiff

    /// Uniform type passed to `CGImageDestinationCreateWithURL`.
    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        }
    }

    /// `kCGImageDestinationLossyCompressionQuality` value, or `nil` for the
    /// lossless formats (PNG, TIFF) where the key does not apply.
    var lossyQuality: Double? {
        switch self {
        case .jpeg: return Constants.jpegCaptureQuality
        case .png, .tiff: return nil
        }
    }

    /// Parse a filename extension (case-insensitive). `nil` for any extension
    /// outside the supported set.
    static func parse(extension ext: String) -> ImageFileFormat? {
        switch ext.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "tif", "tiff": return .tiff
        default: return nil
        }
    }

    /// Format/extension used when the caller supplies no name at all.
    static let defaultFormat: ImageFileFormat = .png
    static let defaultExtension = "png"
}

/// Resolves a caller-supplied output URL to a validated sandbox path, deriving
/// the image format from the extension.
///
/// See the file header for the rule table.
enum OutputPathResolver {

    /// The only supported video container extension.
    static let videoExtension = "mp4"

    /// Resolve a still-image output URL and its encoding format.
    ///
    /// - `nil` → `<Documents>/<timestamp>.png`, `.png`.
    /// - Throws `StillCaptureError.missingFileExtension` when a name carries no
    ///   extension, `.unsupportedImageFormat` for an unrecognized one, and
    ///   `EngineError.invalidOutputPath` for a path outside the sandbox.
    static func image(_ outputURL: URL?) throws -> (url: URL, format: ImageFileFormat) {
        guard let outputURL else {
            return (
                defaultURL(ext: ImageFileFormat.defaultExtension),
                ImageFileFormat.defaultFormat
            )
        }
        let ext = outputURL.pathExtension
        guard !ext.isEmpty else {
            throw StillCaptureError.missingFileExtension(outputURL.lastPathComponent)
        }
        guard let format = ImageFileFormat.parse(extension: ext) else {
            throw StillCaptureError.unsupportedImageFormat(ext)
        }
        return (try place(outputURL), format)
    }

    /// Resolve a video output URL, validating the `.mp4` extension.
    ///
    /// - `nil` → `<Documents>/<timestamp>.mp4`.
    /// - Throws `RecordingError.missingFileExtension` when a name carries no
    ///   extension, `.unsupportedVideoFormat` for anything other than `.mp4`,
    ///   and `EngineError.invalidOutputPath` for a path outside the sandbox.
    static func video(_ outputURL: URL?) throws -> URL {
        guard let outputURL else {
            return defaultURL(ext: videoExtension)
        }
        let ext = outputURL.pathExtension
        guard !ext.isEmpty else {
            throw RecordingError.missingFileExtension(outputURL.lastPathComponent)
        }
        guard ext.lowercased() == videoExtension else {
            throw RecordingError.unsupportedVideoFormat(ext)
        }
        return try place(outputURL)
    }

    // MARK: - Private

    /// `<Documents>/<ISO8601-timestamp>.<ext>`.
    ///
    /// Colons are stripped from the timestamp — Files.app and AirDrop reject
    /// `:` in filenames.
    private static func defaultURL(ext: String) -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return URL.documentsDirectory.appendingPathComponent("\(timestamp).\(ext)")
    }

    /// Place a caller-supplied URL inside the app sandbox, creating parent
    /// directories as needed.
    ///
    /// - A path with no slash (e.g. `URL(string: "photo.png")`) lands in
    ///   `<Documents>`; a full path is used as-is.
    /// - Accepts both `/var/...` and the canonical `/private/var/...` forms of
    ///   the sandbox root (the two are the same physical path on iOS;
    ///   `resolvingSymlinksInPath()` does not collapse them in practice, so both
    ///   prefixes are checked explicitly).
    /// - Throws `EngineError.invalidOutputPath` for any path outside the sandbox.
    private static func place(_ outputURL: URL) throws -> URL {
        let resolved: URL
        if !outputURL.path.contains("/") {
            resolved = URL.documentsDirectory
                .appendingPathComponent(outputURL.lastPathComponent)
        } else {
            resolved = outputURL
        }

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
}
