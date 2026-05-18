import Foundation

public enum SessionState: String, Sendable, Hashable {
    case opening
    case streaming
    case recovering
    case paused
    case error
    case closed
    /// Routine `AVCaptureSession` interruption (Control Center, Split View /
    /// Stage Manager, phone call). Distinct from `.error` — auto-resumes on
    /// `interruptionEndedNotification`. Phase-2 design §2d.5.
    case interrupted
}

public enum RecordingState: Sendable, Hashable {
    case idle(lastUri: String?)
    case recording
    case finalizing
    case paused
}

public enum StreamId: String, Sendable, Hashable, CaseIterable {
    case natural
    case processed
    case tracker
}

// MARK: - Recording types (compressed here per Stage 01 type-compression decision)

/// Options for starting a recording session.
///
/// Full implementation Stage 06.
public struct RecordingOptions: Sendable, Hashable {
    /// Target video bitrate in bits per second.
    ///
    /// Nil → `Constants.recordingTargetBitrateBpsDefault`.
    public var bitrateBps: Int?
    /// Target frame rate (30).
    ///
    /// Nil → `Constants.frameRateTargetFPS`.
    public var fps: Int?
    /// Output URL resolved per `PhotosLibraryClient.resolve`.
    ///
    /// `nil` → `<Documents>/<ISO8601-timestamp>.mp4`. Filename-only URLs land
    /// in `<Documents>`; absolute paths inside `NSHomeDirectory()` are used
    /// as-is. Paths outside the app sandbox throw
    /// `EngineError.invalidOutputPath` from `startRecording`.
    public var outputURL: URL?
    /// Whether and how to publish the finished `.mp4` to the Photos library.
    ///
    /// Defaults to `.none`; the recording lives only at `outputURL`.
    ///
    /// See `PhotosDestination` for per-case semantics.
    public var photosDestination: PhotosDestination

    public init(
        bitrateBps: Int? = nil,
        fps: Int? = nil,
        outputURL: URL? = nil,
        photosDestination: PhotosDestination = .none
    ) {
        self.bitrateBps = bitrateBps
        self.fps = fps
        self.outputURL = outputURL
        self.photosDestination = photosDestination
    }
}

/// Result of a successful recording start.
///
/// Full implementation Stage 06.
public struct RecordingStart: Sendable, Hashable {
    /// Destination URL as a string per `api-surface.md`.
    public let uri: String
    /// Displayed filename (without path).
    public let displayName: String
    public init(uri: String, displayName: String) {
        self.uri = uri
        self.displayName = displayName
    }
}
