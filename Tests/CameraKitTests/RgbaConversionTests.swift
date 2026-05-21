import CoreMedia
import CoreVideo
import IOSurface
import Metal
import Testing

@testable import CameraKit

// MARK: - Constants

@Suite("RGBA8 conversion — pixel-format constants")
struct RgbaConversionConstantsTests {

    @Test("eightBitLanePixelFormat is kCVPixelFormatType_32BGRA")
    func eightBitLanePixelFormatIsBGRA() {
        #expect(Constants.eightBitLanePixelFormat == kCVPixelFormatType_32BGRA)
    }

    @Test("eightBitLaneMetalFormat is .bgra8Unorm")
    func eightBitLaneMetalFormatIsBgra8Unorm() {
        #expect(Constants.eightBitLaneMetalFormat == MTLPixelFormat.bgra8Unorm)
    }

    @Test("streamPixelFormatString is the literal \"BGRA8\"")
    func streamPixelFormatStringMatchesBgra8() {
        #expect(Constants.streamPixelFormatString == "BGRA8")
    }
}

// MARK: - TexturePoolManager — BGRA8 factory

@Suite("RGBA8 conversion — BGRA8 pool factory")
struct RgbaConversionPoolFactoryTests {

    @Test("makeBgra8LanePool vends BGRA8 IOSurface-backed buffers")
    func makeBgra8LanePoolVendsBgra8() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let tpm = try TexturePoolManager(device: device)
        let size = Size(width: 256, height: 256)
        let pool = try tpm.makeBgra8LanePool(size: size)

        var bufOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pool, &bufOut)
        #expect(status == kCVReturnSuccess)
        guard let buf = bufOut else {
            Issue.record("no buffer")
            return
        }
        #expect(CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetWidth(buf) == 256)
        #expect(CVPixelBufferGetHeight(buf) == 256)
        #expect(CVPixelBufferGetIOSurface(buf) != nil)
    }

    @Test("dequeueEightBitPoolTexture wraps as MTLPixelFormat.bgra8Unorm")
    func dequeueEightBitPoolTextureWrapsAsBgra8Unorm() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let tpm = try TexturePoolManager(device: device)
        let size = Size(width: 256, height: 256)
        let pool = try tpm.makeBgra8LanePool(size: size)

        let pair = try tpm.dequeueEightBitPoolTexture(
            pool: pool, width: 256, height: 256)
        #expect(pair.texture.pixelFormat == .bgra8Unorm)
        #expect(pair.texture.width == 256)
        #expect(pair.texture.height == 256)
        #expect(
            CVPixelBufferGetPixelFormatType(pair.buffer) == kCVPixelFormatType_32BGRA)
    }
}

// MARK: - Pass-7 kernel discoverability

@Suite("RGBA8 conversion — Pass-7 kernel discoverability")
struct RgbaConversionKernelDiscoveryTests {

    @Test("rgba16fToBgra8 is discoverable in the SwiftPM Metal library")
    func kernelIsDiscoverable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let library = try device.makeDefaultLibrary(bundle: .module)
        #expect(library.makeFunction(name: "rgba16fToBgra8") != nil)
    }
}

// MARK: - MetalPipeline — BGRA8 pools always allocated

@Suite("RGBA8 conversion — MetalPipeline always allocates BGRA8 pools")
struct RgbaConversionPipelinePoolTests {

    @Test("Pipeline always allocates 8-bit pools for natural and processed")
    func pipelineAlwaysAllocatesEightBitPools() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let captureSize = Size(width: 256, height: 256)
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: captureSize,
            gateOpen: true)

        // Dequeue from each pool and verify the vended format — a non-nil pool
        // that vends the wrong format would still be a bug.
        var naturalBufOut: CVPixelBuffer?
        var processedBufOut: CVPixelBuffer?
        let naturalStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pipeline.eightBitNaturalPoolForTest, &naturalBufOut)
        let processedStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pipeline.eightBitProcessedPoolForTest, &processedBufOut)

        #expect(naturalStatus == kCVReturnSuccess)
        #expect(processedStatus == kCVReturnSuccess)
        if let nat = naturalBufOut {
            #expect(CVPixelBufferGetPixelFormatType(nat) == kCVPixelFormatType_32BGRA)
            #expect(CVPixelBufferGetWidth(nat) == captureSize.width)
            #expect(CVPixelBufferGetHeight(nat) == captureSize.height)
        }
        if let proc = processedBufOut {
            #expect(CVPixelBufferGetPixelFormatType(proc) == kCVPixelFormatType_32BGRA)
            #expect(CVPixelBufferGetWidth(proc) == captureSize.width)
            #expect(CVPixelBufferGetHeight(proc) == captureSize.height)
        }
        // Tracker pool is itself BGRA8 (fused into Pass-4); no separate conversion pool.
        var trackerBufOut: CVPixelBuffer?
        let trackerStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pipeline.trackerPoolForTest, &trackerBufOut)
        #expect(trackerStatus == kCVReturnSuccess)
        if let trk = trackerBufOut {
            #expect(CVPixelBufferGetPixelFormatType(trk) == kCVPixelFormatType_32BGRA)
        }
    }
}

// MARK: - End-to-end mailbox format

@Suite("RGBA8 conversion — mailbox format end-to-end")
struct RgbaConversionMailboxFormatTests {

    @Test("latest*Buffer is BGRA8 for natural and processed (conversion is unconditional)")
    func naturalProcessedAreBgra8() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let consumers = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true,
            consumers: consumers)

        let sample = try makeSyntheticYUVSampleBufferForRgba8Tests(
            width: 256, height: 192)
        try pipeline.encode(sampleBuffer: sample)
        // Metal invokes completion handlers as part of the transition to
        // `.completed`; `waitUntilCompleted()` blocks until both finish.
        // Deterministic — no sleep.
        pipeline.lastCommandBuffer?.waitUntilCompleted()

        guard let natural = pipeline.latestNaturalBufferForTest,
            let processed = pipeline.latestProcessedBufferForTest
        else {
            Issue.record("natural/processed mailboxes not populated")
            return
        }
        #expect(CVPixelBufferGetPixelFormatType(natural) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetPixelFormatType(processed) == kCVPixelFormatType_32BGRA)
    }

    /// Load-bearing guarantee: the 16F textures survive as INTERNAL compute
    /// intermediates.
    ///
    /// Calibration sampling reads `latestNaturalTex16F`; the diagnostic
    /// center-patch reads `latestProcessedTex16F`. They are never a delivery
    /// surface — that is the BGRA8 mailboxes. Keep this isolated so a future
    /// edit can't silently erode the 16F-for-the-math contract.
    @Test("Internal calibration/sampling textures stay .rgba16Float")
    func calibrationAndSamplingTexturesStay16F() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let consumers = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true,
            consumers: consumers)
        let sample = try makeSyntheticYUVSampleBufferForRgba8Tests(
            width: 256, height: 192)
        try pipeline.encode(sampleBuffer: sample)
        pipeline.lastCommandBuffer?.waitUntilCompleted()

        #expect(pipeline.latestNaturalTex16F?.pixelFormat == .rgba16Float)
        #expect(pipeline.latestProcessedTex16F?.pixelFormat == .rgba16Float)
    }

    /// The natural/processed preview textures (`currentTexture()` /
    /// `currentProcessedTexture()` read these) are `.bgra8Unorm`, sharing the
    /// matching lane buffer's surface — one BGRA8 surface per lane delivered as
    /// both a `CVPixelBuffer` and an `MTLTexture` (the old texture/buffer
    /// format asymmetry is gone).
    @Test("Preview lane textures are .bgra8Unorm over the matching lane buffer")
    func previewTexturesAreBgra8() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let consumers = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true,
            consumers: consumers)
        let sample = try makeSyntheticYUVSampleBufferForRgba8Tests(
            width: 256, height: 192)
        try pipeline.encode(sampleBuffer: sample)
        pipeline.lastCommandBuffer?.waitUntilCompleted()

        guard let natTex = pipeline.latestNaturalBgra8Tex,
            let procTex = pipeline.latestProcessedBgra8Tex,
            let natBuf = pipeline.latestNaturalBufferForTest,
            let procBuf = pipeline.latestProcessedBufferForTest
        else {
            Issue.record("BGRA8 texture/buffer mailboxes not populated")
            return
        }
        #expect(natTex.pixelFormat == .bgra8Unorm)
        #expect(procTex.pixelFormat == .bgra8Unorm)
        // One surface per lane: the texture and the delivered buffer must wrap
        // the *same* IOSurface (not merely matching dimensions). This is the
        // load-bearing Task-3 claim — a lane is one BGRA8 surface exposed two
        // ways.
        #expect(
            sameIOSurface(natBuf, natTex),
            "natural texture + buffer must share one IOSurface")
        #expect(
            sameIOSurface(procBuf, procTex),
            "processed texture + buffer must share one IOSurface")
    }
}

// MARK: - Tracker lane BGRA8 delivery

@Suite("RGBA8 conversion — tracker lane delivers BGRA8")
struct RgbaConversionTrackerBgra8Tests {

    /// Pass-4 writes directly into a BGRA8 pool; no separate conversion pass.
    ///
    /// Verify the pool vends 32BGRA buffers at the tracker's computed dimensions.
    @Test("trackerPool vends BGRA8 buffers at the computed tracker dimensions")
    func trackerPoolVendsBgra8() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true)
        let trackerSize = pipeline.trackerSizeForTest
        var bufOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault, pipeline.trackerPoolForTest, &bufOut)
        #expect(status == kCVReturnSuccess)
        guard let buf = bufOut else {
            Issue.record("no buffer from tracker pool")
            return
        }
        #expect(CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetWidth(buf) == trackerSize.width)
        #expect(CVPixelBufferGetHeight(buf) == trackerSize.height)
    }

    /// `currentPixelBuffer(stream: .tracker)` must deliver `kCVPixelFormatType_32BGRA`
    /// after at least one frame. `currentTrackerTexture()` must be `.bgra8Unorm`.
    @Test("currentPixelBuffer(stream: .tracker) is BGRA8 after encode")
    func trackerPixelBufferIsBgra8AfterEncode() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let consumers = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true,
            consumers: consumers)

        // Subscribe so Pass-4 allocates a tracker pair. Hold the stream alive — discarding
        // it immediately terminates the continuation and removes the subscriber before encode.
        let trackerStream = await consumers.subscribe(stream: .tracker)

        let sample = try makeSyntheticYUVSampleBufferForRgba8Tests(
            width: 256, height: 192)
        try pipeline.encode(sampleBuffer: sample)
        await pipeline.lastCommandBuffer?.completed()

        guard let buf = pipeline.latestTrackerBufferForTest else {
            Issue.record("tracker buffer mailbox not populated — ensure tracker subscriber active")
            return
        }
        let trackerSize = pipeline.trackerSizeForTest
        #expect(
            CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA,
            "tracker buffer should be 32BGRA")
        #expect(CVPixelBufferGetWidth(buf) == trackerSize.width)
        #expect(CVPixelBufferGetHeight(buf) == trackerSize.height)
        #expect(
            pipeline.latestTrackerTex?.pixelFormat == .bgra8Unorm,
            "tracker texture mailbox should be bgra8Unorm")
        if let tTex = pipeline.latestTrackerTex {
            #expect(
                sameIOSurface(buf, tTex),
                "tracker texture + buffer must share one IOSurface (fused Pass-4)")
        }
        // Keep the stream alive through assertions — early dealloc terminates the
        // continuation and removes the subscriber before encode completes.
        withExtendedLifetime(trackerStream) {}
    }

    /// Pass-4-specific channel-order + clamp verification.
    ///
    /// The tracker takes a different path than natural/processed: Pass-4 reads
    /// `texture2d<float, access::sample>` through a bilinear sampler and does
    /// `outTex.write(float4, gid)` straight into the `.bgra8Unorm` tracker
    /// texture (no convert kernel). A binding/order mistake there would not be
    /// caught by `bgra8ChannelOrderAndClamp` (which drives `rgba16fToBgra8PSO`).
    /// Drive a uniform known color through `trackerDownsamplePSO` into a BGRA8
    /// pool texture and assert `[B, G, R, A]` order + unorm clamp.
    @Test("Pass-4 tracker downsample stores [B, G, R, A] and clamps on write")
    func trackerPass4ChannelOrderAndClamp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let tpm = try TexturePoolManager(device: device)
        let library = try device.makeDefaultLibrary(bundle: .module)
        guard let fn = library.makeFunction(name: "trackerDownsample") else {
            Issue.record("trackerDownsample kernel not found")
            return
        }
        let pso = try device.makeComputePipelineState(function: fn)
        let cq = device.makeCommandQueue()!
        // Match the pipeline's tracker sampler (linear, clampToEdge).
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        let sampler = device.makeSamplerState(descriptor: samplerDesc)!

        let size = Size(width: 4, height: 4)

        // Drives one uniform-red RGBA16F source (so bilinear sampling has no
        // boundary blend) through Pass-4 into a BGRA8 pool texture; returns the
        // first pixel's BGRA bytes.
        func runTracker(redHalf: UInt16) throws -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let srcDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: size.width, height: size.height,
                mipmapped: false)
            srcDesc.usage = [.shaderRead, .shaderWrite]
            srcDesc.storageMode = .shared
            let srcTex = device.makeTexture(descriptor: srcDesc)!
            let half0: UInt16 = 0x0000  // 0.0
            let half1: UInt16 = 0x3C00  // 1.0 (alpha)
            let rowBytes = size.width * 4 * 2
            var rowData = [UInt16](repeating: 0, count: size.width * size.height * 4)
            for px in 0..<(size.width * size.height) {
                rowData[px * 4 + 0] = redHalf  // R
                rowData[px * 4 + 1] = half0  // G
                rowData[px * 4 + 2] = half0  // B
                rowData[px * 4 + 3] = half1  // A
            }
            srcTex.replace(
                region: MTLRegionMake2D(0, 0, size.width, size.height),
                mipmapLevel: 0, withBytes: rowData, bytesPerRow: rowBytes)

            let pool = try tpm.makeBgra8LanePool(size: size)
            let (dstBuf, dstTex) = try tpm.dequeueEightBitPoolTexture(
                pool: pool, width: size.width, height: size.height)

            let cb = cq.makeCommandBuffer()!
            let enc = cb.makeComputeCommandEncoder()!
            enc.setComputePipelineState(pso)
            enc.setTexture(srcTex, index: 0)
            enc.setTexture(dstTex, index: 1)
            enc.setSamplerState(sampler, index: 0)
            let tg = MTLSize(width: 8, height: 8, depth: 1)
            let groups = MTLSize(
                width: (size.width + 7) / 8, height: (size.height + 7) / 8, depth: 1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()

            CVPixelBufferLockBaseAddress(dstBuf, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(dstBuf, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(dstBuf)!
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            return (bytes[0], bytes[1], bytes[2], bytes[3])
        }

        // Normal red R=1.0 → BGRA = [0, 0, 255, 255].
        let normal = try runTracker(redHalf: 0x3C00)
        #expect(normal.b == 0, "B channel of red should be 0, got \(normal.b)")
        #expect(normal.g == 0, "G channel of red should be 0, got \(normal.g)")
        #expect(normal.r == 255, "R channel of red should be 255, got \(normal.r)")
        #expect(normal.a == 255, "A channel of red should be 255, got \(normal.a)")

        // Over-bright red R=2.0 → unorm write clamps to 255 (not wrap to 0).
        let clamped = try runTracker(redHalf: 0x4000)
        #expect(clamped.b == 0, "B channel of over-bright red should be 0, got \(clamped.b)")
        #expect(clamped.r == 255, "R=2.0 should clamp to 255 (not wrap), got \(clamped.r)")
    }

    /// Channel-order + unorm-clamp verification: dispatch `rgba16fToBgra8PSO` (the same
    /// kernel used throughout the pipeline) from a known solid-red RGBA16F source into a
    /// BGRA8 pool buffer; assert byte order `[B=0, G=0, R=255, A=255]` for R=1.0
    /// and byte clamping to 255 (not wrap) for R=2.0.
    @Test("BGRA8 write clamps and stores [B, G, R, A] channel order")
    func bgra8ChannelOrderAndClamp() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let tpm = try TexturePoolManager(device: device)
        let library = try device.makeDefaultLibrary(bundle: .module)
        guard let fn = library.makeFunction(name: "rgba16fToBgra8") else {
            Issue.record("rgba16fToBgra8 kernel not found")
            return
        }
        let pso = try device.makeComputePipelineState(function: fn)
        let cq = device.makeCommandQueue()!

        let size = Size(width: 4, height: 4)

        // Build a shared RGBA16F source texture with a known red pixel (R=1.0, G=0, B=0, A=1.0).
        let srcDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: size.width, height: size.height, mipmapped: false)
        srcDesc.usage = [.shaderRead, .shaderWrite]
        srcDesc.storageMode = .shared
        guard let srcTex = device.makeTexture(descriptor: srcDesc) else {
            Issue.record("could not create source texture")
            return
        }
        // Float16 bit patterns: 1.0 = 0x3C00, 0.0 = 0x0000, 2.0 = 0x4000
        let half1: UInt16 = 0x3C00  // 1.0
        let half2: UInt16 = 0x4000  // 2.0 (out-of-[0,1] — should clamp)
        let half0: UInt16 = 0x0000  // 0.0
        // RGBA order in source texture memory.
        // Row 0–1: solid red R=1.0 — for channel-order check [B=0, G=0, R=255, A=255].
        let normalRow: [UInt16] = [half1, half0, half0, half1]
        // Row 2–3: over-bright red R=2.0 — unorm write must clamp to 255, not wrap to 0.
        let clampRow: [UInt16] = [half2, half0, half0, half1]
        let rowBytes = size.width * 4 * 2  // 4 channels × 2 bytes/channel
        var rowData = [UInt16](repeating: 0, count: size.width * 4)
        // Rows 0-1: fill with normalRow.
        for col in 0..<size.width {
            rowData[col * 4 + 0] = normalRow[0]
            rowData[col * 4 + 1] = normalRow[1]
            rowData[col * 4 + 2] = normalRow[2]
            rowData[col * 4 + 3] = normalRow[3]
        }
        srcTex.replace(
            region: MTLRegionMake2D(0, 0, size.width, 2),
            mipmapLevel: 0,
            withBytes: rowData,
            bytesPerRow: rowBytes)
        // Rows 2-3: fill with clampRow.
        for col in 0..<size.width {
            rowData[col * 4 + 0] = clampRow[0]
            rowData[col * 4 + 1] = clampRow[1]
            rowData[col * 4 + 2] = clampRow[2]
            rowData[col * 4 + 3] = clampRow[3]
        }
        srcTex.replace(
            region: MTLRegionMake2D(0, 2, size.width, 2),
            mipmapLevel: 0,
            withBytes: rowData,
            bytesPerRow: rowBytes)

        // Dequeue a BGRA8 destination from the pool.
        let pool = try tpm.makeBgra8LanePool(size: size)
        let (dstBuf, dstTex) = try tpm.dequeueEightBitPoolTexture(
            pool: pool, width: size.width, height: size.height)

        let cb = cq.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        enc.setTexture(srcTex, index: 0)
        enc.setTexture(dstTex, index: 1)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(
            width: (size.width + 7) / 8, height: (size.height + 7) / 8, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        // Read back the BGRA8 pixel from the CVPixelBuffer (ADR-06: through IOSurface).
        CVPixelBufferLockBaseAddress(dstBuf, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dstBuf, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(dstBuf) else {
            Issue.record("could not lock BGRA8 buffer")
            return
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(dstBuf)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        // Row 0, column 0: normal red → BGRA = [0, 0, 255, 255]
        let b0 = bytes[0]
        let g0 = bytes[1]
        let r0 = bytes[2]
        let a0 = bytes[3]
        #expect(b0 == 0, "B channel of red pixel should be 0, got \(b0)")
        #expect(g0 == 0, "G channel of red pixel should be 0, got \(g0)")
        #expect(r0 == 255, "R channel of red pixel should be 255, got \(r0)")
        #expect(a0 == 255, "A channel of red pixel should be 255, got \(a0)")

        // Row 2, column 0: over-bright red (R=2.0) → unorm clamp → R=255, not wrap to 0
        let row2 = bytesPerRow * 2
        let b2 = bytes[row2 + 0]
        let r2 = bytes[row2 + 2]
        #expect(b2 == 0, "B channel of over-bright red should be 0, got \(b2)")
        #expect(r2 == 255, "R=2.0 should clamp to 255 (not wrap to 0), got \(r2)")
    }
}

// MARK: - captureNaturalPicture sources the BGRA8 natural-lane buffer

@Suite("RGBA8 conversion — captureNaturalPicture sources BGRA8")
struct RgbaConversionNaturalCaptureSourceTests {

    /// `captureNaturalPicture` now reads `latestNaturalBuffer` (BGRA8) — the
    /// parallel RGBA16F still mailbox is gone (8-bit is the single delivery
    /// format; the camera is 8-bit-locked, so there was no precision to keep).
    @Test("latestNaturalBuffer is BGRA8 (still-capture source)")
    func naturalCaptureBufferIsBgra8() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let consumers = ConsumerRegistry()
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: Size(width: 256, height: 192),
            gateOpen: true,
            consumers: consumers)
        let sample = try makeSyntheticYUVSampleBufferForRgba8Tests(
            width: 256, height: 192)
        try pipeline.encode(sampleBuffer: sample)
        pipeline.lastCommandBuffer?.waitUntilCompleted()

        guard let buffer = pipeline.latestNaturalBuffer else {
            Issue.record("natural-lane buffer mailbox not populated")
            return
        }
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA)
    }
}

// MARK: - SessionCapabilities.streamPixelFormat is unconditionally BGRA8

@Suite("RGBA8 conversion — streamPixelFormat is unconditionally BGRA8")
struct RgbaConversionStreamPixelFormatTests {

    @Test("SessionCapabilities.streamPixelFormat equals the BGRA8 constant")
    func streamPixelFormatIsBgra8() {
        let cap = SessionCapabilities(
            supportedSizes: [Size(width: 1920, height: 1080)],
            previewTextureId: 0,
            naturalTextureId: 0,
            activeCaptureResolution: Size(width: 1920, height: 1080),
            activeCropRegion: Rect(x: 0, y: 0, width: 1920, height: 1080),
            streamPixelFormat: Constants.streamPixelFormatString,
            isoRange: 25...3200,
            exposureDurationRangeNs: 1_000_000...100_000_000,
            focusRange: 0.0...1.0,
            zoomRange: 1.0...1.0,
            evCompensationRange: -3.0...3.0)
        #expect(cap.streamPixelFormat == "BGRA8")
    }
}

// MARK: - Helpers

/// Creates an IOSurface-backed YUV biplanar CVPixelBuffer wrapped in a
/// CMSampleBuffer for `encode(sampleBuffer:)`.
///
/// Mirrors the helper in Stage02Tests / Stage06Tests; named distinctly to avoid
/// linker overlap.
private func makeSyntheticYUVSampleBufferForRgba8Tests(
    width: Int, height: Int
) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let cvStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        attrs, &pixelBuffer
    )
    guard cvStatus == kCVReturnSuccess, let pb = pixelBuffer else {
        throw MetalError.unsupportedFormat
    }
    var fdOut: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pb,
        formatDescriptionOut: &fdOut
    )
    guard let fd = fdOut else { throw MetalError.unsupportedFormat }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid
    )
    var sbOut: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pb,
        formatDescription: fd,
        sampleTiming: &timing,
        sampleBufferOut: &sbOut
    )
    guard let sb = sbOut else { throw MetalError.unsupportedFormat }
    return sb
}

/// True iff `buffer` and `texture` are backed by the same IOSurface.
private func sameIOSurface(_ buffer: CVPixelBuffer, _ texture: MTLTexture) -> Bool {
    guard let bufSurface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue(),
        let texSurface = texture.iosurface
    else { return false }
    return IOSurfaceGetID(bufSurface) == IOSurfaceGetID(texSurface)
}

/// IOSurface-backed YUV biplanar (420f full-range) sample buffer whose planes
/// are filled with a uniform `(y, cb, cr)` byte triple — so the whole image is
/// one known color after Pass-1's YCbCr→RGB conversion.
private func makeSolidYUVSampleBufferForRgba8Tests(
    width: Int, height: Int, y: UInt8, cb: UInt8, cr: UInt8
) throws -> CMSampleBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let cvStatus = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &pixelBuffer)
    guard cvStatus == kCVReturnSuccess, let pb = pixelBuffer else {
        throw MetalError.unsupportedFormat
    }
    CVPixelBufferLockBaseAddress(pb, [])
    // Plane 0 — luma (8-bit, full resolution).
    if let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for col in 0..<width { yPtr[row * yRow + col] = y }
        }
    }
    // Plane 1 — interleaved CbCr (8-bit each, half resolution in both dims).
    if let cBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let cPtr = cBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<(height / 2) {
            for col in 0..<(width / 2) {
                cPtr[row * cRow + col * 2 + 0] = cb
                cPtr[row * cRow + col * 2 + 1] = cr
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(pb, [])

    var fdOut: CMFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &fdOut)
    guard let fd = fdOut else { throw MetalError.unsupportedFormat }
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 30),
        presentationTimeStamp: .zero,
        decodeTimeStamp: .invalid)
    var sbOut: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: fd,
        sampleTiming: &timing, sampleBufferOut: &sbOut)
    guard let sb = sbOut else { throw MetalError.unsupportedFormat }
    return sb
}

// MARK: - End-to-end known-color delivery

@Suite("RGBA8 conversion — end-to-end known-color delivery")
struct RgbaConversionEndToEndColorTests {

    /// Drive a known YUV color through the FULL pipeline and assert the
    /// delivered BGRA8 bytes match the expected RGB.
    ///
    /// Pass-1 YCbCr→RGB + identity Pass-2 + Pass-7 convert. Unlike the
    /// convert/Pass-4 channel-order tests (which drive a kernel in isolation),
    /// this validates the actual pixels a consumer receives end to end — a R/B
    /// swap anywhere in the lane shows up as B≈210 vs expected 101 (off by ~109).
    @Test("known YUV color delivers expected BGRA8 on natural + processed")
    func knownColorDeliversExpectedBgra8() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("no metal device")
            return
        }
        let pipeline = try MetalPipeline(
            device: device, captureSize: Size(width: 64, height: 64), gateOpen: true)

        // Y=150, Cb=100, Cr=170 through YUVToRGBA.metal's full-range BT.601:
        //   Y=0.5882, Cb=-0.1078, Cr=0.1667
        //   R=0.8219·255≈210, G=0.5063·255≈129, B=0.3971·255≈101
        // Identity Pass-2 (ProcessingParameters() defaults) ⇒ processed == natural.
        let sample = try makeSolidYUVSampleBufferForRgba8Tests(
            width: 64, height: 64, y: 150, cb: 100, cr: 170)
        try pipeline.encode(sampleBuffer: sample)
        pipeline.lastCommandBuffer?.waitUntilCompleted()

        let expected = (r: 210, g: 129, b: 101)
        let tol = 3  // 8-bit → fp16 → 8-bit rounding
        let lanes: [(String, CVPixelBuffer?)] = [
            ("natural", pipeline.latestNaturalBufferForTest),
            ("processed", pipeline.latestProcessedBufferForTest),
        ]
        for (label, maybeBuf) in lanes {
            guard let buf = maybeBuf else {
                Issue.record("\(label) buffer mailbox not populated")
                continue
            }
            #expect(CVPixelBufferGetPixelFormatType(buf) == kCVPixelFormatType_32BGRA)
            CVPixelBufferLockBaseAddress(buf, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buf) else {
                Issue.record("\(label) buffer lock failed")
                continue
            }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let b = Int(bytes[0])
            let g = Int(bytes[1])
            let r = Int(bytes[2])
            let a = Int(bytes[3])
            #expect(abs(b - expected.b) <= tol, "\(label) B: expected ~\(expected.b), got \(b)")
            #expect(abs(g - expected.g) <= tol, "\(label) G: expected ~\(expected.g), got \(g)")
            #expect(abs(r - expected.r) <= tol, "\(label) R: expected ~\(expected.r), got \(r)")
            #expect(a == 255, "\(label) A: expected 255, got \(a)")
        }
    }
}
