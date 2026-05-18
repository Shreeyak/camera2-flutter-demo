import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import CameraKit
import CameraKitInterop

@Suite("Stage 08", .progressLogged)
struct Stage08Tests {

    // MARK: - Helpers

    private func makeSyntheticFrameSet(frameNumber: UInt64 = 1) throws -> FrameSet {
        let width = 64
        let height = 48
        func makeBuffer() throws -> CVPixelBuffer {
            var buf: CVPixelBuffer?
            let attrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let status = CVPixelBufferCreate(
                nil, width, height,
                kCVPixelFormatType_64RGBAHalf,
                attrs as CFDictionary, &buf)
            guard status == kCVReturnSuccess, let b = buf else {
                throw NSError(domain: "test", code: Int(status))
            }
            return b
        }
        return FrameSet(
            frameNumber: frameNumber,
            captureTime: CMTime(value: 1000, timescale: 1_000_000_000),
            natural: try makeBuffer(),
            processed: try makeBuffer(),
            tracker: try makeBuffer(),
            capture: .placeholder(),
            processing: ProcessingMetadata(
                color: ColorUniform(.identity),
                crop: CropUniform.full(width: width, height: height)),
            blurScore: 0,
            trackerQuality: .good
        )
    }

    // MARK: - 08:cpp-pixelsink-registration-roundtrip

    /// Register a C-ABI consumer, yield 3 synthetic tracker frames, confirm all 3
    /// are dispatched and the C++ consumer count tracks register/unregister.
    @Test("08:cpp-pixelsink-registration-roundtrip")
    func cppPixelSinkRegistrationRoundtrip() async throws {
        let registry = ConsumerRegistry()
        let counter = LockingCounter()

        let cbs = PixelSinkCallbacks(
            onFrame: { ctx, _, _, _, _ in
                Unmanaged<LockingCounter>.fromOpaque(ctx!).takeUnretainedValue().increment()
            },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: Unmanaged.passUnretained(counter).toOpaque()
        )
        let token = try await registry.registerCallback(stream: .tracker, callbacks: cbs)
        #expect(registry.cppConsumerCount(for: .tracker) == 1)

        for i: UInt64 in 1...3 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .tracker)
        }
        #expect(counter.value == 3)

        await registry.unregister(token: token)
        #expect(registry.cppConsumerCount(for: .tracker) == 0)
    }

    // Phase 1B (2026-05-15): the prior `cannyStubConsumerReceivesTrackerFrames`
    // test relocated to eva-swift-stitchTests/Stage08CannyTests.swift —
    // `CppCannyStub` now lives in the app target's AppCxx/ layer.

    // MARK: - 08:get-native-pipeline-handle-holds-actor

    /// `getNativePipelineHandle()` returns nil when the engine is not open.
    ///
    /// Full non-nil path requires camera permission and a real device (deferred HITL).
    @Test("08:get-native-pipeline-handle-holds-actor")
    func getNativePipelineHandleHoldsActor() async throws {
        let engine = CameraEngine()
        let handle = await engine.getNativePipelineHandle()
        #expect(handle == nil)
    }

    // MARK: - 08:c-abi-callbacks-without-on-frame-rejected

    /// `registerCallback` throws `InteropError.invalidCallbacks` when `onFrame` is nil.
    @Test("08:c-abi-callbacks-without-on-frame-rejected")
    func cABICallbacksWithoutOnFrameRejected() async throws {
        let registry = ConsumerRegistry()
        let cbs = PixelSinkCallbacks(
            onFrame: nil,
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: nil)
        do {
            _ = try await registry.registerCallback(stream: .tracker, callbacks: cbs)
            Issue.record("Expected InteropError.invalidCallbacks but no error was thrown")
        } catch InteropError.invalidCallbacks {
            // Expected.
        } catch {
            Issue.record("Expected InteropError.invalidCallbacks but got \(error)")
        }
    }

    // MARK: - 08:lock-order-pipeline-stage-consumer

    /// Register two consumers on `.natural`, dispatch 20 frames concurrently, confirm
    /// all 40 callbacks fire without deadlock (indirect lock-order proof: D-16).
    @Test("08:lock-order-pipeline-stage-consumer")
    func lockOrderPipelineStageConsumer() async throws {
        let registry = ConsumerRegistry()
        let count = LockingCounter()

        let cbs = PixelSinkCallbacks(
            onFrame: { ctx, _, _, _, _ in
                Unmanaged<LockingCounter>.fromOpaque(ctx!).takeUnretainedValue().increment()
            },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: Unmanaged.passUnretained(count).toOpaque()
        )
        let t1 = try await registry.registerCallback(stream: .natural, callbacks: cbs)
        let t2 = try await registry.registerCallback(stream: .natural, callbacks: cbs)

        await withTaskGroup(of: Void.self) { group in
            for i: UInt64 in 1...20 {
                group.addTask {
                    if let frame = try? self.makeSyntheticFrameSet(frameNumber: i) {
                        registry.yield(frame, stream: .natural)
                    }
                }
            }
        }
        // 2 consumers × 20 frames = 40 invocations; no deadlock means test completes.
        #expect(count.value == 40)

        await registry.unregister(token: t1)
        await registry.unregister(token: t2)
    }

    // MARK: - 08:still-capture-uses-cpp-atomic

    /// `CppCaptureAtomic` has the same CAS semantics as the retired `ManagedAtomic<Bool>`.
    @Test("08:still-capture-uses-cpp-atomic")
    func stillCaptureUsesCppAtomic() async throws {
        let atomic = CppCaptureAtomic()
        #expect(atomic.tryAcquire() == true)   // first acquire succeeds
        #expect(atomic.tryAcquire() == false)  // second fails (already held)
        atomic.release()
        #expect(atomic.tryAcquire() == true)   // acquires again after release
        atomic.release()
    }

    // MARK: - 08:swift-subscribe-is-facade-over-cpp-pool

    /// Swift `subscribe(stream:)` and C-ABI `registerCallback(stream:callbacks:)` both
    /// receive the same frame numbers when `yield(_:stream:)` is called (dual-dispatch,
    /// D-01 observable equivalence).
    @Test("08:swift-subscribe-is-facade-over-cpp-pool")
    func swiftSubscribeIsFacadeOverCppPool() async throws {
        let registry = ConsumerRegistry()
        let capture = FrameCapture()

        let realCbs = PixelSinkCallbacks(
            onFrame: { ctx, _, frameNumber, _, _ in
                Unmanaged<FrameCapture>.fromOpaque(ctx!).takeUnretainedValue().append(frameNumber)
            },
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: Unmanaged.passUnretained(capture).toOpaque()
        )
        let cppToken = try await registry.registerCallback(stream: .natural, callbacks: realCbs)

        let stream = await registry.subscribe(stream: .natural)
        var iterator = stream.makeAsyncIterator()

        // `subscribe()` uses `.bufferingNewest(1)` (PixelSink.swift) — a
        // single-slot buffer. Drain each frame immediately after yielding it
        // so the slot never overflows. A prior version used a detached
        // consumer `Task` + `Task.sleep`, which deadlocked under parallel
        // test load: the cooperative pool was saturated, the consumer was
        // starved, and all 5 synchronous yields collapsed into the 1-slot
        // buffer. This handshake is deterministic regardless of scheduler.
        var swiftFrames: [UInt64] = []
        for i: UInt64 in 1...5 {
            registry.yield(try makeSyntheticFrameSet(frameNumber: i), stream: .natural)
            let frameSet = try #require(
                await iterator.next(),
                "Swift subscriber stream ended before frame \(i)")
            swiftFrames.append(frameSet.frameNumber)
        }

        #expect(swiftFrames.count == 5)
        #expect(capture.frames.count == 5)
        #expect(swiftFrames == capture.frames)

        await registry.unregister(token: cppToken)
    }
}

// MARK: - Test helpers

private final class LockingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

private final class FrameCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _frames: [UInt64] = []

    func append(_ n: UInt64) { lock.withLock { _frames.append(n) } }
    var frames: [UInt64] { lock.withLock { _frames } }
}
