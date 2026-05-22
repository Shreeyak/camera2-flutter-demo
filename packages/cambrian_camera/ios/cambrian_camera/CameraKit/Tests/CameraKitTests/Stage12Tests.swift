import AVFoundation
import CameraKitInterop
import CoreMedia
import Foundation
import Testing

@testable import CameraKit

// Test doubles shared with Stage 10 (same module, non-private): FakeAssetWriter,
// FakeAdaptor, makeFakeFactory, makeDummyPixelBuffer, FastClock. ErrorLog is
// declared in Stage09Tests.swift.

// MARK: - Fake background-task provider

/// Test `BackgroundTaskProviding`: hands out incrementing identifiers, records
/// begin/end call counts, and exposes `expireLatest()` to fire an expiration
/// handler synchronously — the seam the Stage 12 brief calls a "fake UIApplication".
final class FakeBackgroundTaskProvider: BackgroundTaskProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var nextId = 1
    private var handlers: [Int: @Sendable () -> Void] = [:]
    private var _beginCount = 0
    private var _endCount = 0

    var beginCount: Int { lock.withLock { _beginCount } }
    var endCount: Int { lock.withLock { _endCount } }

    func beginBackgroundTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> Int {
        lock.withLock {
            let id = nextId
            nextId += 1
            handlers[id] = expirationHandler
            _beginCount += 1
            return id
        }
    }

    func endBackgroundTask(_ id: Int) async {
        lock.withLock {
            handlers[id] = nil
            _endCount += 1
        }
    }

    /// Fires the expiration handler of the most recently begun task.
    func expireLatest() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard let id = handlers.keys.max() else { return nil }
            return handlers[id]
        }
        handler?()
    }
}

// MARK: - Suite 1: background-task drain

@Suite("Stage 12 — background-task drain", .progressLogged)
struct Stage12BackgroundTaskTests {

    /// 12:background-task-drain-produces-finalized-mp4 — the drain runs inside a
    /// background-task assertion; `finishWriting` completes within the fake's
    /// budget → finalized `.mp4`; `endBackgroundTask` is called exactly once.
    @Test("12:background-task-drain-produces-finalized-mp4")
    func backgroundTaskDrainProducesFinalizedMp4() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        // finishWriting completes quickly; the deadline is the real 5 s.
        await writer.setFinishHang(until: .now.advanced(by: .milliseconds(30)))
        let provider = FakeBackgroundTaskProvider()
        let rec = Recording(
            clock: SystemClock(),
            hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor),
            backgroundTaskProvider: provider
        )
        _ = try await rec.start(
            options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
        _ = await rec.submitEncodedBuffer(
            makeDummyPixelBuffer(), pts: CMTimeMake(value: 0, timescale: 30))
        let uri = await rec.stop()

        #expect(uri.hasSuffix(".mp4"))
        #expect(await writer._status == .completed)
        #expect(await writer.cancelled == false, "happy path must not cancel the writer")
        #expect(provider.beginCount == 1)
        #expect(provider.endCount == 1, "endBackgroundTask must be called exactly once")
    }

    /// 12:expiration-handler-cancels-not-finishes — the OS reclaims the
    /// assertion mid-drain; the expiration handler calls `cancelWriting()`, so
    /// the writer ends `.cancelled` (empty file per ADR-16), never `.completed`.
    @Test("12:expiration-handler-cancels-not-finishes")
    func expirationHandlerCancelsNotFinishes() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        // finishWriting hangs far past any deadline; only the expiration handler
        // (or the real 5 s deadline) can end the drain. SystemClock keeps the
        // deadline branch asleep so expiration is the cancel trigger.
        await writer.setFinishHang(until: .now.advanced(by: .seconds(60)))
        let provider = FakeBackgroundTaskProvider()
        let rec = Recording(
            clock: SystemClock(),
            hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor),
            backgroundTaskProvider: provider
        )
        _ = try await rec.start(
            options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
        _ = await rec.submitEncodedBuffer(
            makeDummyPixelBuffer(), pts: CMTimeMake(value: 0, timescale: 30))

        async let stopResult: String = rec.stop()
        // Let stop() reach the in-flight drain, then fire the expiration handler.
        try await Task.sleep(for: .milliseconds(100))
        provider.expireLatest()
        let uri = await stopResult

        #expect(await writer.cancelled == true, "expiration handler must cancelWriting()")
        // .cancelled, not .completed: finishWriting never finalized the file
        // after expiration — an empty file, never a corrupt MP4 (ADR-16, G-08).
        #expect(await writer._status == .cancelled)
        #expect(uri.hasSuffix(".mp4"))
        #expect(provider.endCount == 1)
    }

    /// 12:end-background-task-called-on-all-paths — `endBackgroundTask` is
    /// called exactly once on (a) normal finalize, (b) expiration cancel, and
    /// (c) the writer-error path.
    @Test("12:end-background-task-called-on-all-paths")
    func endBackgroundTaskCalledOnAllPaths() async throws {
        // (a) normal finalize.
        do {
            let writer = FakeAssetWriter()
            let provider = FakeBackgroundTaskProvider()
            let rec = Recording(
                clock: SystemClock(),
                hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
                writerFactory: makeFakeFactory(writer: writer, adaptor: FakeAdaptor()),
                backgroundTaskProvider: provider
            )
            _ = try await rec.start(
                options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
            _ = await rec.stop()
            #expect(provider.beginCount == 1)
            #expect(provider.endCount == 1, "(a) normal finalize must endBackgroundTask")
        }
        // (b) expiration cancel.
        do {
            let writer = FakeAssetWriter()
            await writer.setFinishHang(until: .now.advanced(by: .seconds(60)))
            let provider = FakeBackgroundTaskProvider()
            let rec = Recording(
                clock: SystemClock(),
                hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
                writerFactory: makeFakeFactory(writer: writer, adaptor: FakeAdaptor()),
                backgroundTaskProvider: provider
            )
            _ = try await rec.start(
                options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
            async let stopResult: String = rec.stop()
            try await Task.sleep(for: .milliseconds(100))
            provider.expireLatest()
            _ = await stopResult
            #expect(provider.endCount == 1, "(b) expiration cancel must endBackgroundTask")
        }
        // (c) writer-error path.
        do {
            let writer = FakeAssetWriter()
            let provider = FakeBackgroundTaskProvider()
            let rec = Recording(
                clock: FastClock(),
                hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
                writerFactory: makeFakeFactory(writer: writer, adaptor: FakeAdaptor()),
                backgroundTaskProvider: provider
            )
            _ = try await rec.start(
                options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
            await writer.setStatus(.failed, error: NSError(domain: "test", code: 7))
            _ = await rec.stop()
            #expect(provider.endCount == 1, "(c) writer-error path must endBackgroundTask")
        }
    }
}

// MARK: - Suite 2: D-11 observability

@Suite("Stage 12 — D-11 observability", .progressLogged)
struct Stage12ObservabilityTests {

    /// 12:pixel-sink-registration-without-on-overwrite-rejected — a `nil`
    /// `onOverwrite` is rejected with `InteropError.missingOnOverwrite`
    /// (G-26-avoidance quality gate); a non-nil one registers successfully.
    @Test("12:pixel-sink-registration-without-on-overwrite-rejected")
    func pixelSinkRegistrationWithoutOnOverwriteRejected() async throws {
        let registry = ConsumerRegistry()

        let missingOverwrite = PixelSinkCallbacks(
            onFrame: { _, _, _, _, _ in },
            onOverwrite: nil,
            onError: nil,
            context: nil)
        do {
            _ = try await registry.registerCallback(
                stream: .tracker, callbacks: missingOverwrite)
            Issue.record("Expected InteropError.missingOnOverwrite but no error was thrown")
        } catch InteropError.missingOnOverwrite {
            // Expected.
        } catch {
            Issue.record("Expected InteropError.missingOnOverwrite but got \(error)")
        }

        let valid = PixelSinkCallbacks(
            onFrame: { _, _, _, _, _ in },
            onOverwrite: { _, _ in },
            onError: nil,
            context: nil)
        let token = try await registry.registerCallback(stream: .tracker, callbacks: valid)
        #expect(token.stream == .tracker)
        #expect(registry.cppConsumerCount(for: .tracker) == 1)
        await registry.unregister(token: token)
    }

    /// 12:frame-delivery-stats-merges-swift-and-cpp-counters — synthetic drops
    /// injected on both the Swift facade and the C++ pool surface together in a
    /// single `FrameDeliveryStats` from `metricsStream()`.
    @Test("12:frame-delivery-stats-merges-swift-and-cpp-counters")
    func frameDeliveryStatsMergesSwiftAndCppCounters() async throws {
        let registry = ConsumerRegistry()
        let stream = await registry.metricsStream()
        var iterator = stream.makeAsyncIterator()

        // Swift-side per-lane drop counters.
        registry._incrementSwiftDropForTest(stream: .natural, by: 3)
        registry._incrementSwiftDropForTest(stream: .processed, by: 1)
        // C++-side per-lane mailbox-overwrite counters.
        registry.cppPool.noteOverwrite(stream: StreamId.natural.rawPoolId)
        registry.cppPool.noteOverwrite(stream: StreamId.natural.rawPoolId)
        registry.cppPool.noteOverwrite(stream: StreamId.tracker.rawPoolId)

        // Force a window emission (the pool otherwise emits once per FPS window).
        registry.cppPool.emitMetrics()

        let stats = try #require(await iterator.next())
        #expect(stats.droppedByLane[.natural] == 3)
        #expect(stats.droppedByLane[.processed] == 1)
        #expect(stats.cppOverwriteByLane[.natural] == 2)
        #expect(stats.cppOverwriteByLane[.tracker] == 1)
        #expect(stats.cppOverwriteByLane[.processed] ?? 0 == 0)
    }
}

// MARK: - Suite 3: carried-forward recording (still passes under bg-task wrapping)

@Suite("Stage 12 — carried-forward recording", .progressLogged)
struct Stage12CarriedForwardTests {

    /// 10:record-start-stop-happy-path — carried forward; still produces the
    /// `.mp4` URI with the background-task assertion now wrapping the drain.
    @Test("10:record-start-stop-happy-path (under background-task wrapping)")
    func recordStartStopHappyPath() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let provider = FakeBackgroundTaskProvider()
        let rec = Recording(
            clock: SystemClock(),
            hooks: Recording.Hooks(
                publishState: { _ in }, emitError: { _ in Issue.record("unexpected error") }),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor),
            backgroundTaskProvider: provider
        )
        let start = try await rec.start(
            options: RecordingOptions(), captureSize: Size(width: 1920, height: 1080))
        for i in 0..<30 {
            _ = await rec.submitEncodedBuffer(
                makeDummyPixelBuffer(), pts: CMTimeMake(value: Int64(i), timescale: 30))
        }
        let uri = await rec.stop()
        #expect(uri == start.uri)
        #expect(await adaptor.appended.count == 30)
        #expect(provider.beginCount == 1)
        #expect(provider.endCount == 1)
    }

    /// 10:recording-truncated-on-deadline — carried forward; the finalize-timeout
    /// cancel path still fires (now reachable via the deadline branch alongside
    /// the new expiration trigger) and still emits non-fatal RECORDING_TRUNCATED.
    @Test("10:recording-truncated-on-deadline (under background-task wrapping)")
    func recordingTruncatedOnDeadline() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        await writer.setFinishHang(until: .now.advanced(by: .seconds(60)))
        let errors = ErrorLog()
        let provider = FakeBackgroundTaskProvider()
        let rec = Recording(
            clock: FastClock(),
            hooks: Recording.Hooks(publishState: { _ in }, emitError: { errors.append($0) }),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor),
            backgroundTaskProvider: provider
        )
        _ = try await rec.start(
            options: RecordingOptions(), captureSize: Size(width: 256, height: 256))
        _ = await rec.submitEncodedBuffer(
            makeDummyPixelBuffer(), pts: CMTimeMake(value: 0, timescale: 30))
        let uri = await rec.stop()

        #expect(errors.snapshot.contains { $0.code == .recordingTruncated && !$0.isFatal })
        #expect(await writer.cancelled == true)
        #expect(uri.hasSuffix(".mp4"))
        #expect(provider.endCount == 1)
    }
}
