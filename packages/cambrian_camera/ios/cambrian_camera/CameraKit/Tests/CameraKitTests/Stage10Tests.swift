import AVFoundation
import CoreMedia
import Testing

@testable import CameraKit

// MARK: - Thread-safe state recorder

/// Thread-safe recorder for RecordingState events captured in @Sendable closures.
private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RecordingState] = []
    func append(_ s: RecordingState) { lock.withLock { items.append(s) } }
    var snapshot: [RecordingState] { lock.withLock { items } }
}

// `ErrorLog` is declared in Stage09Tests.swift and reused here (same module).

/// Thread-safe single-value box (used where a factory closure captures an Int?).
private final class IntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?
    func set(_ v: Int?) { lock.withLock { value = v } }
    var get: Int? { lock.withLock { value } }
}

// MARK: - Stage10CoordinatorTests

@Suite("Stage 10 — recording coordinator", .progressLogged)
struct Stage10CoordinatorTests {
    @Test("coordinator publishes idle(nil) on init")
    func initialState() async {
        let log = StateLog()
        let hooks = Recording.Hooks(
            publishState: { log.append($0) },
            emitError: { _ in }
        )
        let rec = Recording(
            clock: SystemClock(), hooks: hooks,
            writerFactory: { _, _, _, _ in
                fatalError("unused in this test")
            })
        await rec.observeCurrentStateForTest()
        #expect(log.snapshot == [.idle(lastUri: nil)])
    }
}

// MARK: - Test doubles

actor FakeAssetWriter: AssetWriting {
    var _status: AVAssetWriter.Status = .unknown
    var _err: Error?
    var finishHangsUntil: ContinuousClock.Instant?
    var startedSessionAt: CMTime?
    var markedFinished = false
    var cancelled = false

    var status: AVAssetWriter.Status { _status }
    var writerError: Error? { _err }
    func startWriting() -> Bool { _status = .writing; return true }
    func startSession(atSourceTime t: CMTime) { startedSessionAt = t }
    func markInputFinished() { markedFinished = true }
    func finishWriting() async {
        // Preserve .failed as terminal — don't overwrite with cancelled/completed.
        guard _status != .failed else { return }
        if let deadline = finishHangsUntil {
            while ContinuousClock.now < deadline && !cancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        _status = cancelled ? .cancelled : .completed
    }
    func cancelWriting() {
        // Preserve .failed as terminal.
        guard _status != .failed else { return }
        cancelled = true
        _status = .cancelled
    }
    func setStatus(_ s: AVAssetWriter.Status, error: Error? = nil) { _status = s; _err = error }
    func setFinishHang(until: ContinuousClock.Instant) { finishHangsUntil = until }
}

actor FakeAdaptor: AssetWriterPixelBufferAdapting {
    var ready = true
    var appended: [(CVPixelBuffer, CMTime)] = []
    var isReadyForMoreMediaData: Bool { ready }
    func append(_ b: CVPixelBuffer, pts: CMTime) -> Bool {
        if !ready { return false }
        appended.append((b, pts))
        return true
    }
    func setReady(_ r: Bool) { ready = r }
}

func makeFakeFactory(writer: FakeAssetWriter, adaptor: FakeAdaptor) -> AssetWriterFactory {
    { _, _, _, _ in (writer, adaptor) }
}

func makeDummyPixelBuffer(w: Int = 64, h: Int = 64) -> CVPixelBuffer {
    var buf: CVPixelBuffer?
    CVPixelBufferCreate(
        nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
        &buf
    )
    return buf!
}

/// Fast clock: sleep returns immediately — collapses deadline waits in tests.
struct FastClock: CameraKitClock {
    func nowMs() -> UInt64 { 0 }
    func sleep(milliseconds: Int) async throws {}
}

// MARK: - Suite 1: happy path

@Suite("Stage 10 — happy path", .progressLogged)
struct Stage10HappyPathTests {
    @Test("start → 30 frames → stop returns mp4 URI")
    func recordStartStopHappyPath() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let states = StateLog()
        let hooks = Recording.Hooks(
            publishState: { states.append($0) },
            emitError: { _ in Issue.record("unexpected error") }
        )
        let rec = Recording(
            clock: SystemClock(),
            hooks: hooks,
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
        )
        let start = try await rec.start(
            options: RecordingOptions(),
            captureSize: Size(width: 1920, height: 1080)
        )
        #expect(start.uri.hasSuffix(".mp4"))
        for i in 0..<30 {
            _ = await rec.submitEncodedBuffer(
                makeDummyPixelBuffer(),
                pts: CMTimeMake(value: Int64(i), timescale: 30)
            )
        }
        let uri = await rec.stop()
        #expect(uri == start.uri)
        let snap = states.snapshot
        #expect(snap.contains(.recording))
        #expect(snap.contains(.finalizing))
        if case .some(.idle(let last)) = snap.last {
            #expect(last == uri)
        } else {
            Issue.record("final state was not idle, got \(String(describing: snap.last))")
        }
        let appendedCount = await adaptor.appended.count
        #expect(appendedCount == 30)
    }
}

// MARK: - Suite 2: deadline cancel

@Suite("Stage 10 — deadline cancel", .progressLogged)
struct Stage10DeadlineCancelTests {
    @Test("finishWriting deadline triggers cancel; emits RECORDING_TRUNCATED")
    func recordingTruncatedOnDeadline() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        // Hang well past any real deadline so FastClock's instant sleep fires first.
        await writer.setFinishHang(
            until: .now.advanced(by: .seconds(60))
        )
        let errors = ErrorLog()
        let hooks = Recording.Hooks(
            publishState: { _ in },
            emitError: { errors.append($0) }
        )
        let rec = Recording(
            clock: FastClock(),
            hooks: hooks,
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
        )
        _ = try await rec.start(
            options: RecordingOptions(),
            captureSize: Size(width: 256, height: 256)
        )
        _ = await rec.submitEncodedBuffer(
            makeDummyPixelBuffer(),
            pts: CMTimeMake(value: 0, timescale: 30)
        )
        let uri = await rec.stop()
        #expect(errors.snapshot.contains { $0.code == .recordingTruncated && !$0.isFatal })
        #expect(await writer.cancelled == true)
        #expect(uri.hasSuffix(".mp4"))
    }
}

// MARK: - Suite 3: AE frame-rate range

@Suite("Stage 10 — AE frame-rate range", .progressLogged)
struct Stage10AEFrameRateTests {
    @Test("RecordingOptions fps field is forwarded to the factory")
    func aeFrameRateRangeInOptions() async throws {
        let capturedFps = IntBox()
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let factory: AssetWriterFactory = { _, _, _, fps in
            capturedFps.set(fps)
            return (writer, adaptor)
        }
        let rec = Recording(
            clock: FastClock(),
            hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
            writerFactory: factory
        )
        _ = try await rec.start(
            options: RecordingOptions(fps: 15),
            captureSize: Size(width: 256, height: 256)
        )
        #expect(capturedFps.get == 15)
    }
}

// MARK: - Suite 4: NV12 encoder pool

@Suite("Stage 10 — NV12 encoder pool", .progressLogged)
struct Stage10NV12PoolTests {
    @Test("encoder NV12 pool produces IOSurface-backed buffers")
    func nv12EncoderPoolIsIOSurfaceBacked() throws {
        // Validate that the encoder pool produces IOSurface-backed NV12 buffers.
        // MetalPipeline is not constructible in tests (needs a live MTLDevice for PSO),
        // so we validate at the pool level only.
        let pool = try TexturePoolManager.makeEncoderNV12PoolForTest(
            size: Size(width: 128, height: 128)
        )
        var buf: CVPixelBuffer?
        let s = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
        #expect(s == kCVReturnSuccess)
        guard let b = buf else { Issue.record("pool returned nil buffer"); return }
        #expect(CVPixelBufferGetIOSurface(b) != nil)
        let fmt = CVPixelBufferGetPixelFormatType(b)
        #expect(fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }
}

// MARK: - Suite 5: adaptor back-pressure

@Suite("Stage 10 — adaptor back-pressure", .progressLogged)
struct Stage10AdaptorBackPressureTests {
    @Test("adaptor.isReadyForMoreMediaData = false drops that frame")
    func adaptorNotReadyDropsFrame() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let rec = Recording(
            clock: FastClock(),
            hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
        )
        _ = try await rec.start(
            options: RecordingOptions(),
            captureSize: Size(width: 256, height: 256)
        )
        for i in 0..<30 {
            if (5...7).contains(i) {
                await adaptor.setReady(false)
            } else {
                await adaptor.setReady(true)
            }
            _ = await rec.submitEncodedBuffer(
                makeDummyPixelBuffer(),
                pts: CMTimeMake(value: Int64(i), timescale: 30)
            )
        }
        _ = await rec.stop()
        #expect(await adaptor.appended.count == 27)
        #expect(await rec.currentDroppedNotReady() == 3)
    }
}

// MARK: - Suite 8: fatal finalize

@Suite("Stage 10 — fatal finalize", .progressLogged)
struct Stage10FatalFinalizeTests {
    @Test("writer.status == .failed on finish emits fatal RECORDING_FAILED")
    func fatalFinalizeEmitsRecordingFailed() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        let errors = ErrorLog()
        let rec = Recording(
            clock: FastClock(),
            hooks: Recording.Hooks(
                publishState: { _ in },
                emitError: { errors.append($0) }
            ),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
        )
        _ = try await rec.start(
            options: RecordingOptions(),
            captureSize: Size(width: 256, height: 256)
        )
        await writer.setStatus(.failed, error: NSError(domain: "test", code: 7))
        _ = await rec.stop()
        #expect(errors.snapshot.contains { $0.code == .recordingFailed && $0.isFatal })
    }
}

// MARK: - Suite 9: stop returns promptly on happy path (Bug 14 regression)

/// Bug 14 — `Recording.stop()` previously used `withTaskGroup` with a deadline
/// child that lacked an early-out, so `group.waitForAll()` always blocked for
/// `Constants.recordingFinishTimeoutSeconds` (5 s) regardless of how fast
/// `finishWriting` actually completed. That kept `recordingState` in `.finalizing`
/// for the full 5 s window and silently swallowed REC taps in `RecordingViewModel`.
/// The fix mirrors `AsyncWithTimeout.runOnQueue`: a `ManagedAtomic<Bool>` CAS race
/// between the work and deadline branches with `withCheckedContinuation`.
@Suite("Stage 10 — stop returns promptly on happy path (Bug 14)", .progressLogged)
struct Stage10StopPromptnessTests {
    @Test("stop() returns shortly after finishWriting completes (must not block on deadline)")
    func stopReturnsPromptlyAfterFinishWriting() async throws {
        let writer = FakeAssetWriter()
        let adaptor = FakeAdaptor()
        // finishWriting takes a measurable but small time; deadline is the real 5 s.
        await writer.setFinishHang(until: .now.advanced(by: .milliseconds(50)))
        let rec = Recording(
            clock: SystemClock(),
            hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
            writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
        )
        _ = try await rec.start(
            options: RecordingOptions(),
            captureSize: Size(width: 256, height: 256)
        )
        let t0 = ContinuousClock.now
        let uri = await rec.stop()
        let elapsed = ContinuousClock.now - t0
        #expect(
            elapsed < .milliseconds(1000),
            "stop() took \(elapsed); pre-fix this blocked for the full 5 s deadline"
        )
        let wasCancelled = await writer.cancelled
        #expect(wasCancelled == false, "happy path must not cancel writer")
        #expect(uri.hasSuffix(".mp4"))
    }

    @Test("two consecutive Recording cycles each produce a completed writer")
    func twoConsecutiveCyclesEachComplete() async throws {
        for cycle in 0..<2 {
            let writer = FakeAssetWriter()
            let adaptor = FakeAdaptor()
            await writer.setFinishHang(until: .now.advanced(by: .milliseconds(20)))
            let rec = Recording(
                clock: SystemClock(),
                hooks: Recording.Hooks(publishState: { _ in }, emitError: { _ in }),
                writerFactory: makeFakeFactory(writer: writer, adaptor: adaptor)
            )
            _ = try await rec.start(
                options: RecordingOptions(),
                captureSize: Size(width: 256, height: 256)
            )
            _ = await rec.submitEncodedBuffer(
                makeDummyPixelBuffer(),
                pts: CMTimeMake(value: 0, timescale: 30)
            )
            _ = await rec.stop()
            let status = await writer._status
            #expect(status == .completed, "cycle \(cycle): writer status \(status), expected .completed")
            let appended = await adaptor.appended.count
            #expect(appended == 1, "cycle \(cycle): appended \(appended) frames, expected 1")
        }
    }
}
