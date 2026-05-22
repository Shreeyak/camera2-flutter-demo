import AVFoundation

/// One-shot still photo via AVCapturePhotoOutput.
///
/// `capture(using:on:)` dispatches the `capturePhoto` call onto the supplied
/// queue (sessionQueue per ADR-07); the delegate callback (nonisolated) bridges
/// the resulting CVPixelBuffer back through a checked continuation. Photo
/// settings honor the device's live exposure/ISO/WB/focus — there is no
/// separate photo-settings surface; the user controls those via the existing
/// `CameraSettings` mechanism and this capture inherits them.
///
/// `@unchecked Sendable`: the AVF delegate callback is nonisolated; the
/// `continuation` write happens inside the `withCheckedThrowingContinuation`
/// closure, which runs synchronously before `queue.async` executes —
/// `capturePhoto`'s enqueue creates a happens-before edge making that write
/// visible to the delegate callback. Single-in-flight capture is assumed:
/// the sessionQueue caller serializes (ADR-07), so at most one continuation
/// is live at a time.
final class StillPhotoCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {

    /// Builds the fixed photo settings.
    ///
    /// Requests 420f to match the video format so `MetalPipeline.gradeOneShot`
    /// consumes the buffer directly. Flash off and `.balanced` quality (nice
    /// native-camera look while honoring device exposure). Does NOT set
    /// `maxPhotoDimensions` — photo dims default to the active format dims so
    /// `gradeOneShot`'s 1:1 crop mapping holds.
    static func makeSettings() -> AVCapturePhotoSettings {
        let fmt = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let s = AVCapturePhotoSettings(
            format: [kCVPixelBufferPixelFormatTypeKey as String: fmt])
        s.flashMode = .off
        s.photoQualityPrioritization = .balanced
        return s
    }

    // Written before `capturePhoto` returns (happens-before the delegate callback);
    // read only in the nonisolated delegate callback. Single-in-flight invariant
    // enforced by the sessionQueue caller (ADR-07).
    private var continuation: CheckedContinuation<CVPixelBuffer, Error>?

    /// Must be handed the sessionQueue (ADR-07): the capturePhoto request is
    /// dispatched onto `queue`; the delegate result returns via the continuation.
    func capture(using output: AVCapturePhotoOutput, on queue: DispatchQueue) async throws -> CVPixelBuffer {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            queue.async { [self] in
                output.capturePhoto(with: Self.makeSettings(), delegate: self)
            }
        }
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        defer { continuation = nil }
        if let error {
            continuation?.resume(throwing: error)
            return
        }
        guard let pb = photo.pixelBuffer else {
            continuation?.resume(throwing: StillCaptureError.bufferUnavailable)
            return
        }
        continuation?.resume(returning: pb)
    }
}
