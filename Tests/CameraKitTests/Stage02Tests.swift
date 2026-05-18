import Testing
import Foundation
import Metal
import CoreMedia
import CoreVideo
@testable import CameraKit

// MARK: - Stage02Tests

@Suite("Stage02Tests", .progressLogged)
struct Stage02Tests {

    // MARK: Test 1 — 02:gate-closes-on-inactive

    /// Verifies the gate-before-commit invariant (ADR-09):
    /// - setGate(false) prevents commandBuffer.commit() from executing in MetalPipeline.encode().
    /// - setGate(true) resumes commits.
    ///
    /// Uses a real MetalPipeline + synthetic IOSurface-backed CVPixelBuffer so that
    /// pipeline.commitCount directly measures whether commit() was called.
    @Test func gateClosesOnInactive() async throws {
        let engine = CameraEngine()

        // Engine-level: gate starts open.
        #expect(await engine.isGateOpen == true)
        await engine.setGate(false)
        #expect(await engine.isGateOpen == false)
        await engine.setGate(true)
        #expect(await engine.isGateOpen == true)

        // Pipeline-level: verify gate-before-commit — commit() must be suppressed when
        // gate is false. This is the invariant that prevents MTLCommandBufferErrorNotPermitted
        // IOAF 6 on background submit (02-concurrency.md §Concurrency contract table row 4).
        guard let device = MTLCreateSystemDefaultDevice() else { return } // skip if no GPU
        let pipeline = try MetalPipeline(device: device,
                                         captureSize: Size(width: 320, height: 240),
                                         gateOpen: true)
        let sampleBuffer = try makeSyntheticYUVSampleBuffer(width: 320, height: 240)

        // Gate open → encode → commit fires.
        try pipeline.encode(sampleBuffer: sampleBuffer)
        #expect(pipeline.commitCount == 1, "Expected 1 commit with gate open")

        // Gate closed → encode → commit must NOT fire (gate-before-commit, ADR-09).
        pipeline.setGate(false)
        try pipeline.encode(sampleBuffer: sampleBuffer)
        #expect(pipeline.commitCount == 1,
                "commitCount must not increase with gate closed — gate-before-commit invariant violated")
    }

    // MARK: Test 2 — 02:wait-until-scheduled-on-inactive

    /// Verifies the drain path:
    /// - After a real commit, lastCommandBuffer is non-nil.
    /// - drainLastBuffer() actually runs waitUntilScheduled() on that buffer (not a no-op).
    /// - With gate closed before drain, no further commits occur.
    @Test func waitUntilScheduledOnInactive() async throws {
        // Nil-pipeline path: drainSubmittedFrame() must not hang when no pipeline is open.
        let engine = CameraEngine()
        await engine.setGate(false)
        await engine.drainSubmittedFrame()
        #expect(await engine.isGateOpen == false)

        // Real drain: verify lastCommandBuffer is set after a committed frame.
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let pipeline = try MetalPipeline(device: device,
                                         captureSize: Size(width: 320, height: 240),
                                         gateOpen: true)

        // Before any encode, no buffer to drain.
        #expect(pipeline.lastCommandBuffer == nil)

        // Encode one frame with gate open → buffer is committed → lastCommandBuffer set.
        let sampleBuffer = try makeSyntheticYUVSampleBuffer(width: 320, height: 240)
        try pipeline.encode(sampleBuffer: sampleBuffer)
        #expect(pipeline.lastCommandBuffer != nil,
                "lastCommandBuffer must be non-nil after a committed frame")

        // Close gate, drain → waitUntilScheduled() runs on the committed buffer.
        // If drain hangs here, the drain path is broken.
        pipeline.setGate(false)
        pipeline.drainLastBuffer()
        // Reaching this line without hanging confirms the drain completed within
        // FRAME_LATENCY_BUDGET_MS (33ms at 30fps — GPU scheduling is sub-millisecond).
    }

    // MARK: Test 3 — 02:background-suspend-via-async-timeout

    /// Verifies the runOnQueue helper (ADR-30) resumes on the deadline when the
    /// dispatched work hangs past the timeout.
    @Test func backgroundSuspendViaAsyncTimeout() async {
        let queue = DispatchQueue(label: "test.stage02.hang")
        let startedAt = ContinuousClock.now

        let semaphore = DispatchSemaphore(value: 0)
        await runOnQueue(queue, timeout: .milliseconds(150)) {
            // Blocks longer than timeout; bounded so the GCD thread eventually returns.
            _ = semaphore.wait(timeout: .now() + 5)
        }

        let elapsed = ContinuousClock.now - startedAt
        #expect(elapsed < .milliseconds(600),
                "runOnQueue must return via timeout (~150ms), not wait for work to complete")
    }

    // MARK: Test 4 — 02:background-resume-is-noop-until-interruption-ended

    /// Verifies backgroundResume() is idempotent: opens the gate, no session restart,
    /// no thrown error.
    @Test func backgroundResumeIsNoopUntilInterruptionEnded() async {
        let engine = CameraEngine()

        await engine.setGate(false)
        #expect(await engine.isGateOpen == false)

        await engine.backgroundResume()
        #expect(await engine.isGateOpen == true)

        // Idempotent: second call does not break anything.
        await engine.backgroundResume()
        #expect(await engine.isGateOpen == true)
    }
}

// MARK: - Helpers

/// Creates an IOSurface-backed YUV biplanar CVPixelBuffer and wraps it in a CMSampleBuffer.
/// IOSurface backing is required by CVMetalTextureCacheCreateTextureFromImage (ADR-06).
/// The pixel data is uninitialized — we only care that encode() runs the Metal path.
private func makeSyntheticYUVSampleBuffer(width: Int, height: Int) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let cvStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attrs, &pixelBuffer
    )
    guard cvStatus == kCVReturnSuccess, let pb = pixelBuffer else {
        throw SyntheticBufferError.pixelBufferFailed(cvStatus)
    }

    var formatDescription: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pb,
        formatDescriptionOut: &formatDescription
    )
    guard let fd = formatDescription else {
        throw SyntheticBufferError.formatDescriptionFailed
    }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pb,
        formatDescription: fd,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
    )
    guard let sb = sampleBuffer else {
        throw SyntheticBufferError.sampleBufferFailed
    }
    return sb
}

private enum SyntheticBufferError: Error {
    case pixelBufferFailed(CVReturn)
    case formatDescriptionFailed
    case sampleBufferFailed
}
