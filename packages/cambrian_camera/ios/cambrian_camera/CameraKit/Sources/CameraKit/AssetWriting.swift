import AVFoundation
import CoreMedia

/// Abstraction over AVAssetWriter for test injection (10:record-start-stop-happy-path et al).
public protocol AssetWriting: Sendable {
    var status: AVAssetWriter.Status { get async }
    func startWriting() async -> Bool
    func startSession(atSourceTime: CMTime) async
    func markInputFinished() async
    /// Returns only when writer has completed (or been cancelled).
    func finishWriting() async
    func cancelWriting() async
    /// Error after a failed status, if any.
    var writerError: Error? { get async }
}

/// Abstraction over AVAssetWriterInputPixelBufferAdaptor.
public protocol AssetWriterPixelBufferAdapting: Sendable {
    var isReadyForMoreMediaData: Bool { get async }
    func append(_ buffer: CVPixelBuffer, pts: CMTime) async -> Bool
}

/// Factory closure — production path injected by default; tests swap for fakes.
public typealias AssetWriterFactory =
    @Sendable (
        _ outputURL: URL,
        _ size: Size,
        _ bitrateBps: Int,
        _ fps: Int
    ) async throws -> (AssetWriting, AssetWriterPixelBufferAdapting)

/// Production factory: real `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor`.
public enum DefaultAssetWriterFactory {
    public static let make: AssetWriterFactory = { outputURL, size, bitrateBps, fps in
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrateBps,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true
        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(Constants.encoderPixelFormat),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: adaptorAttrs
        )
        guard writer.canAdd(input) else {
            throw RecordingError.writerStartFailed(status: Int(writer.status.rawValue))
        }
        writer.add(input)
        return (
            AVAssetWritingBox(writer: writer, input: input),
            AVAdaptorBox(adaptor: adaptor)
        )
    }
}

/// Production boxes.
///
/// Both @unchecked Sendable: AVAssetWriter is not Sendable but is thread-safe
/// for the call patterns we use (start/append from our single actor, internal encode queue owned by framework).
final class AVAssetWritingBox: AssetWriting, @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    init(writer: AVAssetWriter, input: AVAssetWriterInput) {
        self.writer = writer
        self.input = input
    }
    var status: AVAssetWriter.Status { get async { writer.status } }
    var writerError: Error? { get async { writer.error } }
    func startWriting() async -> Bool { writer.startWriting() }
    func startSession(atSourceTime t: CMTime) async { writer.startSession(atSourceTime: t) }
    func markInputFinished() async { input.markAsFinished() }
    func finishWriting() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            writer.finishWriting { c.resume() }
        }
    }
    func cancelWriting() async { writer.cancelWriting() }
}

final class AVAdaptorBox: AssetWriterPixelBufferAdapting, @unchecked Sendable {
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    init(adaptor: AVAssetWriterInputPixelBufferAdaptor) { self.adaptor = adaptor }
    var isReadyForMoreMediaData: Bool { get async { adaptor.assetWriterInput.isReadyForMoreMediaData } }
    func append(_ buffer: CVPixelBuffer, pts: CMTime) async -> Bool {
        adaptor.append(buffer, withPresentationTime: pts)
    }
}
