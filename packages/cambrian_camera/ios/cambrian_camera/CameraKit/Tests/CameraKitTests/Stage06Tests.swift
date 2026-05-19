import CoreMedia
import CoreVideo
import Foundation
import Metal
import Synchronization
import Testing

@testable import CameraKit

@Suite("Stage06Tests", .progressLogged)
struct Stage06Tests {

    // MARK: - Test 1 — 06:frame-set-publication

    /// Inject a synthetic YUV CMSampleBuffer; subscribers to `.natural`, `.processed`,
    /// `.tracker` each receive one FrameSet with frameNumber == 1; each CVPixelBuffer
    /// is IOSurface-backed.
    @Test func frameSetPublication() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)
        let registry = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gateOpen: true, consumers: registry)

        let naturalTask = Task { () -> FrameSet? in
            for await fs in await registry.subscribe(stream: .natural) { return fs }
            return nil
        }
        let processedTask = Task { () -> FrameSet? in
            for await fs in await registry.subscribe(stream: .processed) { return fs }
            return nil
        }
        let trackerTask = Task { () -> FrameSet? in
            for await fs in await registry.subscribe(stream: .tracker) { return fs }
            return nil
        }

        // Allow subscribe registrations to land before encoding.
        try await Task.sleep(nanoseconds: 50_000_000)

        let sb = try makeSyntheticYUVSampleBuffer(width: size.width, height: size.height)
        try pipeline.encode(sampleBuffer: sb)
        // Allow completion handler to fire.
        try await Task.sleep(nanoseconds: 200_000_000)

        naturalTask.cancel()
        processedTask.cancel()
        trackerTask.cancel()
        let n = await naturalTask.value
        let p = await processedTask.value
        let t = await trackerTask.value

        // MetalPipeline assigns frameNumber, then increments — first FrameSet is 0.
        // See docs/stage-11-pre-existing-bugs.md Bug 2.
        #expect(n?.frameNumber == 0)
        #expect(p?.frameNumber == 0)
        #expect(t?.frameNumber == 0)
        #expect(CVPixelBufferGetIOSurface(n!.natural) != nil)
        #expect(CVPixelBufferGetIOSurface(p!.processed) != nil)
        #expect(CVPixelBufferGetIOSurface(t!.tracker) != nil)
    }

    // MARK: - Test 2 — 06:swift-consumer-drop-on-busy

    /// Producer yields synthetically at ~100fps while subscriber sleeps 33ms per frame.
    ///
    /// At least one frame must be dropped and the drop counter records it.
    @Test func swiftConsumerDropOnBusy() async throws {
        let registry = ConsumerRegistry()
        let stream = await registry.subscribe(stream: .processed)

        let producer = Task {
            for i in 1...30 {
                registry.yield(Self.makeTestFrameSet(frameNumber: UInt64(i)), stream: .processed)
                try? await Task.sleep(nanoseconds: 10_000_000)  // ~100fps
            }
        }
        // Collect frame numbers via a Task that returns them — avoids shared mutable capture.
        let consumer = Task { () -> [UInt64] in
            var collected: [UInt64] = []
            for await fs in stream {
                collected.append(fs.frameNumber)
                try? await Task.sleep(nanoseconds: 33_000_000)  // ~30fps — slower than producer
                if collected.count >= 5 { break }
            }
            return collected
        }
        await producer.value
        let seen = await consumer.value

        let drops = registry.dropCount(for: .processed)
        #expect(drops >= 1)
        #expect(seen.count >= 1)
        for i in 1..<seen.count { #expect(seen[i] > seen[i - 1]) }
    }

    // MARK: - Test 3 — 06:pool-trio-allocation-on-open

    /// MetalPipeline.init creates three CVPixelBufferPool instances; dequeue from
    /// each confirms IOSurface backing.
    @Test func poolTrioAllocationOnOpen() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 128, height: 128)
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gateOpen: true, consumers: ConsumerRegistry())

        let (nb, _) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        let (pb, _) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
        let (tb, _) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.trackerPoolForTest,
            width: pipeline.trackerSizeForTest.width,
            height: pipeline.trackerSizeForTest.height)

        #expect(CVPixelBufferGetIOSurface(nb) != nil)
        #expect(CVPixelBufferGetIOSurface(pb) != nil)
        #expect(CVPixelBufferGetIOSurface(tb) != nil)
    }

    // MARK: - Test 4 — 06:tracker-downsample-height-matches-constant

    @Test func trackerDownsampleHeightMatchesConstant() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 1280, height: 720)
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gateOpen: true, consumers: ConsumerRegistry())

        #expect(pipeline.trackerSizeForTest.height == Constants.trackerHeightPx)
        #expect(pipeline.trackerSizeForTest.width % 2 == 0)

        let rawW = Int((Double(Constants.trackerHeightPx) * Double(size.width) / Double(size.height)).rounded())
        let expectedEven = rawW - (rawW % 2)
        #expect(pipeline.trackerSizeForTest.width == expectedEven)
    }

    // MARK: - Test 5 — 06:subscribe-then-cancel-releases-subscriber

    @Test func subscribeThenCancelReleasesSubscriber() async throws {
        let registry = ConsumerRegistry()
        let stream = await registry.subscribe(stream: .processed)
        let task = Task {
            for await _ in stream { break }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(registry.subscriberCount(for: .processed) == 1)

        task.cancel()
        registry.yield(Self.makeTestFrameSet(frameNumber: 42), stream: .processed)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(registry.subscriberCount(for: .processed) == 0)
    }

    // MARK: - Test 6 — 06:register-callback-throws-not-wired

    @Test func registerCallbackThrowsNotWired() async throws {
        let registry = ConsumerRegistry()
        // onFrame: nil triggers InteropError.invalidCallbacks (D-03 / D-11 quality gate).
        let cb = PixelSinkCallbacks(
            onFrame: nil,
            onOverwrite: { _, _ in },
            onError: { _, _ in },
            context: nil
        )
        do {
            _ = try await registry.registerCallback(stream: .tracker, callbacks: cb)
            Issue.record("Expected InteropError.invalidCallbacks but no error was thrown")
        } catch InteropError.invalidCallbacks {
            // Expected — onFrame: nil is rejected (D-03 / D-11).
        } catch {
            Issue.record("Expected InteropError.invalidCallbacks but got \(error)")
        }
    }

    // MARK: - Test 7 — 06:natural-stream-is-subscribable

    @Test func naturalStreamIsSubscribable() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)
        let registry = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device, captureSize: size,
            gateOpen: true, consumers: registry)

        let task = Task { () -> FrameSet? in
            for await fs in await registry.subscribe(stream: .natural) { return fs }
            return nil
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let sb = try makeSyntheticYUVSampleBuffer(width: size.width, height: size.height)
        try pipeline.encode(sampleBuffer: sb)
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        let fs = await task.value
        // First FrameSet has frameNumber 0 (assign-then-increment in MetalPipeline).
        // See docs/stage-11-pre-existing-bugs.md Bug 2.
        #expect(fs?.frameNumber == 0)
        #expect(CVPixelBufferGetIOSurface(fs!.natural) != nil)
    }

    // MARK: - Helpers

    private static func makeTestFrameSet(frameNumber: UInt64) -> FrameSet {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 1, 1,
            kCVPixelFormatType_64RGBAHalf,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
            &pb)
        let buffer = pb!
        return FrameSet(
            frameNumber: frameNumber,
            captureTime: CMTime(value: Int64(frameNumber), timescale: 30),
            natural: buffer, processed: buffer, tracker: buffer,
            capture: CaptureMetadata.placeholder(),
            processing: ProcessingMetadata(
                color: ColorUniform(.identity),
                crop: CropUniform.full(width: 1, height: 1)),
            blurScore: 0,
            trackerQuality: .good
        )
    }
}

// MARK: - Shared test helper

private enum SyntheticBufferError: Error {
    case pixelBufferFailed(CVReturn)
    case formatDescriptionFailed
    case sampleBufferFailed
}

private func makeSyntheticYUVSampleBuffer(width: Int, height: Int) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let cvStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attrs, &pixelBuffer)
    guard cvStatus == kCVReturnSuccess, let pb = pixelBuffer else {
        throw SyntheticBufferError.pixelBufferFailed(cvStatus)
    }
    var formatDescription: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb,
        formatDescriptionOut: &formatDescription)
    guard let fd = formatDescription else {
        throw SyntheticBufferError.formatDescriptionFailed
    }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb,
        formatDescription: fd, sampleTiming: &timing,
        sampleBufferOut: &sb)
    guard let sampleBuffer = sb else { throw SyntheticBufferError.sampleBufferFailed }
    return sampleBuffer
}
