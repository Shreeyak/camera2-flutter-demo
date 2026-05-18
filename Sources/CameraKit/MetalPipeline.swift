import Atomics
import CoreMedia
import CoreVideo
import Metal
import Synchronization

// MARK: - Stage 04 uniform structs (host ↔ shader layout)

// Mirrors struct ColorUniform in ColorShaders.metal. Float (32-bit) layout.
// Fields map 1:1 to the Metal shader struct; no padding.
struct ColorUniform: Hashable {
    var brightness: Float
    var contrast: Float
    var saturation: Float
    var blackR: Float
    var blackG: Float
    var blackB: Float
    var gamma: Float

    init(_ p: ProcessingParameters) {
        brightness = Float(p.brightness)
        contrast = Float(p.contrast)
        saturation = Float(p.saturation)
        blackR = Float(p.blackR)
        blackG = Float(p.blackG)
        blackB = Float(p.blackB)
        gamma = Float(p.gamma)
    }

    static let identity = ColorUniform(.identity)
}

// Mirrors struct CropUniform in YUVToRGBA.metal. UInt32 layout.
// Fields map 1:1 to the Metal shader struct; no padding.
struct CropUniform: Hashable {
    var originX: UInt32
    var originY: UInt32
    var width: UInt32
    var height: UInt32

    static func full(width: Int, height: Int) -> CropUniform {
        CropUniform(originX: 0, originY: 0, width: UInt32(width), height: UInt32(height))
    }
}

// Mirrors `struct PatchUniform` in CenterPatchKernel.metal.
struct PatchUniform {
    var patchSize: UInt32
    var patchOriginX: UInt32
    var patchOriginY: UInt32
}

// UniformsHost removed in Stage 05. Replaced by Mutex<UniformStorage> (ADR-34, D-17).

/// Owns the GPU pipeline that converts YUV sample buffers into an RGBA16Float texture
/// consumed by the MTKView render pass.
///
/// ADR-02: `encode(sampleBuffer:)` runs entirely on the `delivery` DispatchQueue.
/// No actor hops, no `Task {}`, no `await`, no `DispatchQueue.main.async`.
///
/// ADR-06: CPU access to frame data is ONLY through IOSurface-backed `CVPixelBuffer`.
/// `MTLTexture.getBytes` is never called.
///
/// ADR-09: `submissionGate` is checked after CPU-side encode and immediately before
/// `commandBuffer.commit()`. If the gate is false the frame is dropped; no commit occurs.
///
/// `@unchecked Sendable`: instances are captured in `@Sendable` closures on the
/// `delivery` queue. `lastCommandBuffer` is written on `delivery` and read via
/// `drainLastBuffer()` — safe under the @unchecked Sendable assertion.
final class MetalPipeline: @unchecked Sendable {

    // MARK: - Per-frame pool properties (Stage 06)

    private let naturalPool: CVPixelBufferPool
    private let processedPool: CVPixelBufferPool
    private let trackerPool: CVPixelBufferPool

    // Pre-Phase-3 — RGBA8 lane conversion (default-on session flag).
    //
    // When `lanesEightBit` is true, Pass-7 dispatches per-frame for natural +
    // processed (NOT tracker) and writes into these IOSurface-backed BGRA8
    // pools. The buffer mailboxes (`_latestNaturalBuffer` /
    // `_latestProcessedBuffer`) point at the converted buffer, so
    // `CameraEngine.currentPixelBuffer(stream:)` returns BGRA8 for the
    // Phase-3 bridge. See
    // `docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md`.
    private let lanesEightBit: Bool
    private let eightBitNaturalPool: CVPixelBufferPool?
    private let eightBitProcessedPool: CVPixelBufferPool?
    private let rgba16fToBgra8PSO: MTLComputePipelineState?

    private(set) var captureSize: Size
    private let trackerSize: Size

    /// Preview-facing "latest" textures.
    ///
    /// Single writer on the AVF delivery queue (`addCompletedHandler`
    /// callback); readers on MainActor / sessionQueue / the C++ pixel-sink
    /// consumer thread. See `Mailbox<T>` for the safety contract. G-13 /
    /// Stage 06 design.
    ///
    /// Storage is `private` (Mailbox-write access is restricted to this
    /// type); the public-read companion below forwards `latest` so external
    /// readers continue to see `pipeline.latestNaturalTex` returning
    /// `MTLTexture?` — preserves the prior `private(set)` semantics.
    private let _latestNaturalTex = Mailbox<MTLTexture>()
    private let _latestProcessedTex = Mailbox<MTLTexture>()
    private let _latestTrackerTex = Mailbox<MTLTexture>()

    var latestNaturalTex: MTLTexture? { _latestNaturalTex.latest }
    var latestProcessedTex: MTLTexture? { _latestProcessedTex.latest }
    var latestTrackerTex: MTLTexture? { _latestTrackerTex.latest }

    // Phase-2 §2c: lane CVPixelBuffer mailboxes — paired with the texture
    // mailboxes above. Single writer on the AVF delivery queue; readers
    // wherever the raw `CVPixelBuffer` is needed
    // (`CameraEngine.currentPixelBuffer(stream:)` for the Phase-3 zero-copy
    // FlutterTexture bridge). See `Mailbox<T>`.
    private let _latestNaturalBuffer = Mailbox<CVPixelBuffer>()
    private let _latestProcessedBuffer = Mailbox<CVPixelBuffer>()
    private let _latestTrackerBuffer = Mailbox<CVPixelBuffer>()

    var latestNaturalBuffer: CVPixelBuffer? { _latestNaturalBuffer.latest }
    var latestProcessedBuffer: CVPixelBuffer? { _latestProcessedBuffer.latest }
    var latestTrackerBuffer: CVPixelBuffer? { _latestTrackerBuffer.latest }

    // Pre-Phase-3 — parallel RGBA16F mailbox for the natural-lane buffer,
    // populated unconditionally (independent of `lanesEightBit`). Read by
    // `CameraEngine.captureNaturalPicture` so HDR-grade still capture
    // continues to source the precise RGBA16F lane buffer even when the
    // bridge-facing `currentPixelBuffer(stream: .natural)` is BGRA8.
    // Single writer on the AVF delivery queue; same `Mailbox<T>` contract
    // as the other lane mailboxes.
    private let _latestNaturalBufferRGBA16F = Mailbox<CVPixelBuffer>()
    var latestNaturalBufferRGBA16F: CVPixelBuffer? { _latestNaturalBufferRGBA16F.latest }

    /// PTS (in nanoseconds) of the most recent CMSampleBuffer encoded into `latestNaturalTex`.
    ///
    /// Read by `CameraEngine.awaitNaturalAfter` to confirm the natural texture
    /// has been refreshed past a target buffer timestamp (e.g. the `t_apply`
    /// from `setWhiteBalanceModeLocked(...handler:)`). Stored as Int64 ns to
    /// allow lock-free CAS reads. Single writer: completion handler on the
    /// delivery queue.
    let latestNaturalPTSNs: ManagedAtomic<Int64> = ManagedAtomic(0)

    // Still capture (Stage 07) — one slot, CPU-readable pool.
    private var stillCapturePool: CVPixelBufferPool?
    // Armed by StillCapture.armCapture(); cleared by completion handler after delivery.
    // Single-writer guarantee: CAS guard in StillCapture prevents concurrent arming.
    nonisolated(unsafe) var pendingCaptureContinuation: CheckedContinuation<CVPixelBuffer, Error>?
    private(set) var stillCaptureDequeueCount: Int = 0  // test seam

    // MARK: - Pass 4 — tracker downsample (Stage 06)

    /// Pass-4 tracker downsample PSO + sampler.
    ///
    /// Compiled in init().
    private let trackerDownsamplePSO: MTLComputePipelineState
    private let trackerSampler: MTLSamplerState

    /// Frame counter incremented per encode.
    ///
    /// Delivery-queue only.
    private var frameNumber: UInt64 = 0

    /// Consumer registry handed in from CameraEngine.
    let consumers: ConsumerRegistry

    // MARK: - Shared properties

    private let commandQueue: MTLCommandQueue
    private let yuvToRgbaPSO: MTLComputePipelineState
    private let colorTransformPSO: MTLComputePipelineState
    private let centerPatchPSO: MTLComputePipelineState
    private let patchBufferR: MTLBuffer
    private let patchBufferG: MTLBuffer
    private let patchBufferB: MTLBuffer

    /// Stage 05: `Mutex<UniformStorage>` protecting host-written shader params (ADR-34, D-17, Inv 6).
    ///
    /// Both color-transform and crop uniforms live inside `UniformStorage` so a single
    /// lock protects all host→GPU parameter paths. Writes route through
    /// `uniforms.withLock { $0 = new }` (CameraEngine); per-frame snapshots route
    /// through `uniforms.withLock { $0 }` at the top of `encode()` — the critical
    /// section contains only the struct-copy snapshot, never a Metal commit.
    let uniforms: Mutex<UniformStorage>
    private let texturePool: TexturePoolManager

    // ADR-09: GPU submission gate shared with CameraEngine. Loaded on delivery queue
    /// (.acquiring) before every commit; stored by engine actor (.sequentiallyConsistent).
    private let submissionGate: ManagedAtomic<Bool>

    // Session token reference from the owning engine. Used by completion handler (D-10).
    private let engineSessionToken: ManagedAtomic<UInt64>

    // Test-only: count of completion-handler invocations that no-op due to token mismatch.
    nonisolated(unsafe) var didNoOpCountForTest: UInt64 = 0

    // Hook for Metal-level errors; set by engine after init.
    var onMetalError: (@Sendable (MetalError) -> Void)?

    // MARK: - Stage 10: Pass 5 encoder (NV12 encode)

    /// NV12 pixel buffer pool for the encoder path.
    ///
    /// Allocated once in init().
    private let encoderPool: CVPixelBufferPool
    // Compute PSO for the rgba16fToNV12 kernel (Stage 10 / Task 7 shader).
    private let nv12EncodePSO: MTLComputePipelineState
    /// Engine sets this to true at startRecording(), false at stopRecording()/pause().
    ///
    /// Loaded on the delivery queue with .acquiring before each Pass 5 dispatch.
    let isRecording: ManagedAtomic<Bool> = ManagedAtomic(false)
    /// Installed by the engine after open().
    ///
    /// Pass 5 delivers the NV12 CVPixelBuffer + PTS.
    var onEncodedBufferReady: (@Sendable (CVPixelBuffer, CMTime) -> Void)?

    // Most recently committed command buffer. Written on delivery queue after each
    // commit; read via drainLastBuffer() which is called from the engine actor.
    // Safe under the @unchecked Sendable assertion — writes cease once the gate is
    /// closed (sequentiallyConsistent store) before any drain read occurs.
    // `internal private(set)` — tests verify non-nil after a committed frame (02:wait-until-scheduled-on-inactive).
    internal private(set) var lastCommandBuffer: (any MTLCommandBuffer)?

    // Count of commandBuffer.commit() calls that passed the gate check.
    // Internal; used by 02:gate-closes-on-inactive to verify gate-before-commit (ADR-09).
    internal private(set) var commitCount: Int = 0

    /// - Parameters:
    ///   - device: From `MTLCreateSystemDefaultDevice()`.
    ///   - captureSize: Dimensions reported by `CameraSession.configure()`.
    ///   - gate: Shared `ManagedAtomic<Bool>` owned by `CameraEngine` (ADR-09).
    ///   - consumers: `ConsumerRegistry` owned by `CameraEngine`; used to publish
    ///     `FrameSet` values on the delivery queue.
    /// - Throws: `MetalError.pipelineStateCompilation` if the Metal library or
    ///   kernel cannot be loaded, or if PSO compilation fails.
    init(
        device: MTLDevice,
        captureSize: Size,
        gate: ManagedAtomic<Bool>,
        consumers: ConsumerRegistry,
        engineSessionToken: ManagedAtomic<UInt64>,
        lanesEightBit: Bool
    ) throws {
        submissionGate = gate
        self.engineSessionToken = engineSessionToken
        self.consumers = consumers
        self.captureSize = captureSize

        // Tracker dimensions: preserve capture aspect ratio, scale to trackerHeightPx.
        let trackerH = Constants.trackerHeightPx
        let aspect = Double(captureSize.width) / Double(captureSize.height)
        let rawW = Int((Double(trackerH) * aspect).rounded())
        let trackerW = rawW - (rawW % 2)
        self.trackerSize = Size(width: trackerW, height: trackerH)

        // 1. Texture pool (CVMetalTextureCache wrapper).
        texturePool = try TexturePoolManager(device: device)

        // 2. Load Metal library from the SwiftPM resource bundle.
        //    `device.makeDefaultLibrary()` without bundle: fails in a SwiftPM package.
        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .module)
        } catch {
            throw MetalError.pipelineStateCompilation(
                "Failed to load default Metal library: \(error.localizedDescription)")
        }

        // 3. Look up the YUV→RGBA compute kernel.
        guard let yuvFunction = library.makeFunction(name: "yuvToRgba") else {
            throw MetalError.pipelineStateCompilation("yuvToRgba not found")
        }

        // 4. Compile the compute pipeline state.
        do {
            yuvToRgbaPSO = try device.makeComputePipelineState(function: yuvFunction)
        } catch {
            throw MetalError.pipelineStateCompilation(error.localizedDescription)
        }

        // 4b. Look up + compile the Stage-04 color-transform compute kernel.
        guard let colorFunction = library.makeFunction(name: "colorTransform") else {
            throw MetalError.pipelineStateCompilation("colorTransform not found")
        }
        do {
            colorTransformPSO = try device.makeComputePipelineState(function: colorFunction)
        } catch {
            throw MetalError.pipelineStateCompilation(error.localizedDescription)
        }

        // 4c. Center-patch sampler.
        guard let patchFunction = library.makeFunction(name: "centerPatchHistogram") else {
            throw MetalError.pipelineStateCompilation("centerPatchHistogram not found")
        }
        do {
            centerPatchPSO = try device.makeComputePipelineState(function: patchFunction)
        } catch {
            throw MetalError.pipelineStateCompilation(error.localizedDescription)
        }
        let patchPixelCount = Constants.centerPatchSizePx * Constants.centerPatchSizePx
        let patchByteSize = patchPixelCount * MemoryLayout<Float>.stride
        guard
            let bufR = device.makeBuffer(length: patchByteSize, options: .storageModeShared),
            let bufG = device.makeBuffer(length: patchByteSize, options: .storageModeShared),
            let bufB = device.makeBuffer(length: patchByteSize, options: .storageModeShared)
        else {
            throw MetalError.unsupportedFormat
        }
        patchBufferR = bufR
        patchBufferG = bufG
        patchBufferB = bufB

        // 4d. Host-side uniforms — Stage 05 mutex-protected storage (ADR-34, D-17).
        uniforms = Mutex(
            UniformStorage(
                color: .identity,
                crop: .full(width: captureSize.width, height: captureSize.height)
            ))

        // 5. Command queue.
        commandQueue = device.makeCommandQueue()!

        // 6. Per-stream CVPixelBufferPools (Stage 06 pool-backed lineage).
        naturalPool = try texturePool.makeWorkingFormatPool(size: captureSize)
        processedPool = try texturePool.makeWorkingFormatPool(size: captureSize)
        trackerPool = try texturePool.makeWorkingFormatPool(size: trackerSize)

        // 6b. Pre-Phase-3 — RGBA8 conversion flag stored; pools + PSO lazy when on.
        //     Tracker lane is intentionally not converted (Plan OQ #4) — no Phase-3
        //     Pigeon counterpart for the tracker lane; saves one Metal pass/frame.
        self.lanesEightBit = lanesEightBit
        if lanesEightBit {
            self.eightBitNaturalPool = try texturePool.makeBgra8LanePool(size: captureSize)
            self.eightBitProcessedPool = try texturePool.makeBgra8LanePool(size: captureSize)
            guard let fnConvert = library.makeFunction(name: "rgba16fToBgra8") else {
                throw MetalError.pipelineStateCompilation("rgba16fToBgra8 missing")
            }
            self.rgba16fToBgra8PSO = try device.makeComputePipelineState(function: fnConvert)
        } else {
            self.eightBitNaturalPool = nil
            self.eightBitProcessedPool = nil
            self.rgba16fToBgra8PSO = nil
        }

        // 8. Still-capture pool — 1-slot, CPU-readable, RGBA16F (Stage 07).
        let sPool = try texturePool.makeStillCapturePool(size: captureSize)
        self.stillCapturePool = sPool

        // 9. Stage 10: encoder NV12 pool + rgba16fToNV12 PSO (Pass 5).
        encoderPool = try texturePool.makeEncoderNV12Pool(size: captureSize)
        guard let fnEncode = library.makeFunction(name: "rgba16fToNV12") else {
            throw MetalError.pipelineStateCompilation("rgba16fToNV12 missing")
        }
        nv12EncodePSO = try device.makeComputePipelineState(function: fnEncode)

        // 7. Pass-4 tracker downsample PSO + sampler.
        guard let trackerFunction = library.makeFunction(name: "trackerDownsample") else {
            throw MetalError.pipelineStateCompilation("trackerDownsample not found")
        }
        do {
            trackerDownsamplePSO = try device.makeComputePipelineState(function: trackerFunction)
        } catch {
            throw MetalError.pipelineStateCompilation(error.localizedDescription)
        }
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw MetalError.pipelineStateCompilation("tracker sampler state")
        }
        trackerSampler = sampler

    }

    /// Encodes a YUV→RGBA + color-transform + tracker-downsample compute pass for one camera frame.
    ///
    /// Must be called on the `delivery` DispatchQueue (ADR-02).
    /// Frames that cannot be processed are silently dropped.
    func encode(sampleBuffer: CMSampleBuffer) throws {
        // 1. Unwrap the pixel buffer; drop frame if unavailable.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // 2. Wrap YUV planes as zero-copy MTLTextures (ADR-06).
        let yTexture: MTLTexture
        let cbcrTexture: MTLTexture
        do {
            yTexture = try texturePool.makeYTexture(from: pixelBuffer)
            cbcrTexture = try texturePool.makeCbCrTexture(from: pixelBuffer)
        } catch {
            return  // drop frame on texture-wrap failure
        }

        // 3. Dequeue per-frame pool buffers.
        let naturalPair: (buffer: CVPixelBuffer, texture: MTLTexture)
        let processedPair: (buffer: CVPixelBuffer, texture: MTLTexture)
        do {
            naturalPair = try texturePool.dequeuePoolTexture(
                pool: naturalPool, width: captureSize.width, height: captureSize.height)
            processedPair = try texturePool.dequeuePoolTexture(
                pool: processedPool, width: captureSize.width, height: captureSize.height)
        } catch {
            return  // pool exhausted — drop frame
        }

        // Tracker buffer only when someone is subscribed to .tracker (no wasteful alloc).
        let trackerPair: (buffer: CVPixelBuffer, texture: MTLTexture)?
        if consumers.hasSubscriber(.tracker) {
            trackerPair = try? texturePool.dequeuePoolTexture(
                pool: trackerPool, width: trackerSize.width, height: trackerSize.height)
        } else {
            trackerPair = nil
        }

        // 4. Snapshot uniforms — Stage 05 Mutex<UniformStorage> (ADR-34, D-17, Inv 6).
        //    `withLock` critical section contains only the struct-copy snapshot;
        //    no Metal encode or commit call appears inside the closure (05:mutex-scope-is-tight).
        let (colorSnapshot, cropSnapshot, metadataSnapshot): (ColorUniform, CropUniform, ProcessingMetadata) =
            uniforms.withLock { storage in
                let c = storage.color
                let r = storage.crop
                return (c, r, ProcessingMetadata(color: c, crop: r))
            }

        // 5. Command buffer.
        let commandBuffer = commandQueue.makeCommandBuffer()!

        let naturalTexI = naturalPair.texture
        let processedTexI = processedPair.texture

        // 6. Pass 1: YUV → RGBA into naturalTexI, with crop uniform.
        let pass1 = commandBuffer.makeComputeCommandEncoder()!
        pass1.setComputePipelineState(yuvToRgbaPSO)
        pass1.setTexture(yTexture, index: 0)
        pass1.setTexture(cbcrTexture, index: 1)
        pass1.setTexture(naturalTexI, index: 2)
        var cropLocal = cropSnapshot  // setBytes needs a mutable address
        pass1.setBytes(&cropLocal, length: MemoryLayout<CropUniform>.stride, index: 0)
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (naturalTexI.width + 15) / 16,
            height: (naturalTexI.height + 15) / 16,
            depth: 1
        )
        pass1.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        pass1.endEncoding()

        // 7. Pass 2: color transform naturalTexI → processedTexI with ColorUniform.
        let pass2 = commandBuffer.makeComputeCommandEncoder()!
        pass2.setComputePipelineState(colorTransformPSO)
        pass2.setTexture(naturalTexI, index: 0)
        pass2.setTexture(processedTexI, index: 1)
        var colorLocal = colorSnapshot
        pass2.setBytes(&colorLocal, length: MemoryLayout<ColorUniform>.stride, index: 0)
        pass2.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        pass2.endEncoding()

        // 8. Pass 4: tracker downsample naturalTexI → trackerTexI (when subscribed).
        if let trackerPair {
            let trackerTexI = trackerPair.texture
            let pass4 = commandBuffer.makeComputeCommandEncoder()!
            pass4.setComputePipelineState(trackerDownsamplePSO)
            pass4.setTexture(naturalTexI, index: 0)
            pass4.setTexture(trackerTexI, index: 1)
            pass4.setSamplerState(trackerSampler, index: 0)
            let tgTracker = MTLSize(width: 16, height: 16, depth: 1)
            let groupsTracker = MTLSize(
                width: (trackerTexI.width + 15) / 16,
                height: (trackerTexI.height + 15) / 16,
                depth: 1
            )
            pass4.dispatchThreadgroups(groupsTracker, threadsPerThreadgroup: tgTracker)
            pass4.endEncoding()
        }

        // Pass 6: blit processedTexI → still readback buffer (gated on pending capture).
        // Origins must be (0,0,0) — non-zero origins on IOSurface textures break rendering
        // (CLAUDE.md §8 invariant). Dequeue from dedicated still pool, not processed pool.
        var stillPairForCompletion: (buffer: CVPixelBuffer, texture: MTLTexture)?
        if pendingCaptureContinuation != nil, let sPool = stillCapturePool {
            if let pair = try? texturePool.dequeuePoolTexture(
                pool: sPool, width: captureSize.width, height: captureSize.height
            ) {
                let pass6 = commandBuffer.makeBlitCommandEncoder()!
                pass6.copy(
                    from: processedTexI,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(
                        width: processedTexI.width, height: processedTexI.height, depth: 1
                    ),
                    to: pair.texture,
                    destinationSlice: 0,
                    destinationLevel: 0,
                    destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
                )
                pass6.endEncoding()
                stillPairForCompletion = pair
                stillCaptureDequeueCount += 1
            }
        }

        // Pass 5: RGBA16F → NV12 encode (Stage 10). Runs only while recording.
        // Pool exhaustion drops this frame from the recorder; preview is unaffected
        // (domain 06 Recording-Sink Back-Pressure).
        var encoderPairForCompletion: (buffer: CVPixelBuffer, yTex: MTLTexture, cbcrTex: MTLTexture)?
        if isRecording.load(ordering: .acquiring) {
            if let enc = try? texturePool.dequeueEncoderBuffer(pool: encoderPool) {
                let pass5 = commandBuffer.makeComputeCommandEncoder()!
                pass5.setComputePipelineState(nv12EncodePSO)
                pass5.setTexture(processedTexI, index: 0)
                pass5.setTexture(enc.yTex, index: 1)
                pass5.setTexture(enc.cbcrTex, index: 2)
                let cbcrW = enc.cbcrTex.width
                let cbcrH = enc.cbcrTex.height
                let tg5 = MTLSize(width: 16, height: 16, depth: 1)
                let groups5 = MTLSize(
                    width: (cbcrW + 15) / 16,
                    height: (cbcrH + 15) / 16,
                    depth: 1
                )
                pass5.dispatchThreadgroups(groups5, threadsPerThreadgroup: tg5)
                pass5.endEncoding()
                encoderPairForCompletion = enc
            }
        }

        // Pass 7 (pre-Phase-3): RGBA16F → BGRA8 conversion for the lane-buffer
        // mailboxes when `lanesEightBit` is on. Tracker is not converted
        // (Plan §OQ #4). Runs unconditionally when on — not subscriber-gated
        // in v1, so HITL measures the real cost (Plan §OQ #2). Pass-7 reads
        // the RGBA16F lane texture and writes into a fresh BGRA8 pool buffer's
        // .bgra8Unorm view; the buffer mailbox below points at the new buffer.
        var naturalEightBitPair: (buffer: CVPixelBuffer, texture: MTLTexture)?
        var processedEightBitPair: (buffer: CVPixelBuffer, texture: MTLTexture)?
        if lanesEightBit,
            let convertPSO = rgba16fToBgra8PSO,
            let natPool = eightBitNaturalPool,
            let procPool = eightBitProcessedPool
        {
            if let pair = try? texturePool.dequeueEightBitPoolTexture(
                pool: natPool, width: captureSize.width, height: captureSize.height
            ) {
                let pass7n = commandBuffer.makeComputeCommandEncoder()!
                pass7n.setComputePipelineState(convertPSO)
                pass7n.setTexture(naturalTexI, index: 0)
                pass7n.setTexture(pair.texture, index: 1)
                pass7n.dispatchThreadgroups(
                    threadGroups, threadsPerThreadgroup: threadGroupSize)
                pass7n.endEncoding()
                naturalEightBitPair = pair
            }
            if let pair = try? texturePool.dequeueEightBitPoolTexture(
                pool: procPool, width: captureSize.width, height: captureSize.height
            ) {
                let pass7p = commandBuffer.makeComputeCommandEncoder()!
                pass7p.setComputePipelineState(convertPSO)
                pass7p.setTexture(processedTexI, index: 0)
                pass7p.setTexture(pair.texture, index: 1)
                pass7p.dispatchThreadgroups(
                    threadGroups, threadsPerThreadgroup: threadGroupSize)
                pass7p.endEncoding()
                processedEightBitPair = pair
            }
        }

        // 9. Gate check (ADR-09, D-06). Strict policy: every .inactive gates.
        guard submissionGate.load(ordering: .acquiring) else { return }

        // Capture all frame-local values before the completion handler. CMSampleBuffer
        // is not Sendable; capture derived values (CMTime, metadata snapshot) instead.
        let captureTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureMeta = CaptureMetadata.placeholder()
        let meta = metadataSnapshot
        let fn = frameNumber
        let naturalBuf = naturalPair.buffer
        let processedBuf = processedPair.buffer
        let trackerBuf = trackerPair?.buffer
        let trackerTex = trackerPair?.texture
        let consumers = self.consumers
        let trackerForSet: CVPixelBuffer = trackerBuf ?? naturalBuf
        let stillBufForCompletion: CVPixelBuffer? = stillPairForCompletion?.buffer
        // Stage 10: extract NV12 buffer for delivery in completion handler.
        let encoderBufForCompletion: CVPixelBuffer? = encoderPairForCompletion?.buffer
        // Pre-Phase-3 — capture converted buffers for mailbox store in handler.
        let naturalEightBitBuf: CVPixelBuffer? = naturalEightBitPair?.buffer
        let processedEightBitBuf: CVPixelBuffer? = processedEightBitPair?.buffer

        // D-10: capture the session token at commit. Handler no-ops if the token has
        // advanced (close() / recovery ran) — prevents use-after-free on readback
        // buffers and pending continuations (G-20).
        let tokenAtCommit = self.engineSessionToken.load(ordering: .acquiring)
        commandBuffer.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            let liveToken = self.engineSessionToken.load(ordering: .acquiring)
            if liveToken != tokenAtCommit {
                // Session advanced — release the pending capture slot if any and bail.
                self.pendingCaptureContinuation?.resume(
                    throwing: StillCaptureError.metalReadbackFailed
                )
                self.pendingCaptureContinuation = nil
                self.didNoOpCountForTest &+= 1
                return
            }
            // Metal-level error classification (G-02 / ADR-15).
            if cb.status == .error {
                let code = (cb.error as NSError?)?.code ?? -1
                if let cont = self.pendingCaptureContinuation {
                    cont.resume(throwing: MetalError.commandBufferFailed(code: code))
                    self.pendingCaptureContinuation = nil
                }
                self.onMetalError?(MetalError.commandBufferFailed(code: code))
                return
            }
            // Deliver still readback buffer to StillCapture if Pass 6 ran.
            if let buf = stillBufForCompletion {
                let cont = self.pendingCaptureContinuation
                self.pendingCaptureContinuation = nil
                cont?.resume(returning: buf)
            }
            // Stage 10: deliver NV12 encoder buffer if Pass 5 ran and command buffer succeeded.
            if let encBuf = encoderBufForCompletion, cb.status == .completed {
                self.onEncodedBufferReady?(encBuf, captureTime)
            }
            // Construct FrameSet from delivery-queue-local captures only.
            let fs = FrameSet(
                frameNumber: fn,
                captureTime: captureTime,
                natural: naturalBuf,
                processed: processedBuf,
                tracker: trackerForSet,
                capture: captureMeta,
                processing: meta,
                blurScore: 0.0,
                trackerQuality: .good
            )
            // Publish to subscribed lanes (nonisolated — no actor hop).
            consumers.yield(fs, stream: .natural)
            consumers.yield(fs, stream: .processed)
            if trackerBuf != nil {
                consumers.yield(fs, stream: .tracker)
            }
            // Update preview mailboxes for MTKView draw pass.
            // Pre-Phase-3 — buffer mailbox stores converted BGRA8 buffer when
            // flag is on; texture mailbox always stores RGBA16F. The parallel
            // `_latestNaturalBufferRGBA16F` mailbox always stores the
            // RGBA16F pool buffer so `captureNaturalPicture` keeps HDR-grade
            // precision regardless of the flag.
            self._latestNaturalBuffer.store(naturalEightBitBuf ?? naturalBuf)
            self._latestNaturalBufferRGBA16F.store(naturalBuf)
            self._latestNaturalTex.store(naturalTexI)
            // Publish the buffer PTS as nanoseconds so `awaitNaturalAfter` can
            // confirm naturalTex has been refreshed past a given timestamp. CAS
            // loop ensures we only advance the published PTS — out-of-order
            // command-buffer completion (rare but possible across Metal queues)
            // must not regress the timeline.
            let captureNs = Int64(CMTimeGetSeconds(captureTime) * 1_000_000_000)
            var cur = self.latestNaturalPTSNs.load(ordering: .relaxed)
            while captureNs > cur {
                let (ok, actual) = self.latestNaturalPTSNs.compareExchange(
                    expected: cur, desired: captureNs, ordering: .releasing)
                if ok { break }
                cur = actual
            }
            self._latestProcessedBuffer.store(processedEightBitBuf ?? processedBuf)
            self._latestProcessedTex.store(processedTexI)
            if let tBuf = trackerBuf, let tTex = trackerTex {
                self._latestTrackerBuffer.store(tBuf)
                self._latestTrackerTex.store(tTex)
            }
            self.texturePool.flush()
        }

        // 10. Track for drain (ADR-09 waitUntilScheduled path) and increment.
        lastCommandBuffer = commandBuffer
        commitCount += 1
        frameNumber &+= 1
        commandBuffer.commit()
    }

    /// Blocks until the most recently committed command buffer has been scheduled.
    ///
    /// Called from CameraEngine.drainSubmittedFrame() on .inactive.
    /// Safe to call from any thread (Metal contract for waitUntilScheduled).
    func drainLastBuffer() {
        lastCommandBuffer?.waitUntilScheduled()
    }

    /// Returns the latest natural texture for the MTKView draw pass.
    ///
    /// Reads `latestNaturalTex` `Mailbox<T>` (G-13 single-writer model).
    /// Falls back to dequeuing a blank pool buffer on the first call before any frame arrives.
    func currentTexture() -> MTLTexture {
        if let t = latestNaturalTex { return t }
        if let pair = try? texturePool.dequeuePoolTexture(
            pool: naturalPool, width: captureSize.width, height: captureSize.height
        ) {
            _latestNaturalBuffer.store(pair.buffer)
            _latestNaturalTex.store(pair.texture)
            return pair.texture
        }
        fatalError("MetalPipeline.currentTexture: no preview texture available")
    }

    /// Returns the latest processed texture for the right-half MTKView.
    ///
    /// Reads `latestProcessedTex` `Mailbox<T>` (G-13 single-writer model).
    /// Falls back to dequeuing a blank pool buffer on the first call before any frame arrives.
    func currentProcessedTex() -> MTLTexture {
        if let t = latestProcessedTex { return t }
        if let pair = try? texturePool.dequeuePoolTexture(
            pool: processedPool, width: captureSize.width, height: captureSize.height
        ) {
            _latestProcessedBuffer.store(pair.buffer)
            _latestProcessedTex.store(pair.texture)
            return pair.texture
        }
        fatalError("MetalPipeline.currentProcessedTex: no preview texture available")
    }

    /// Returns the center-patch sample size in pixels, scaled with capture
    /// resolution and clamped to a 16-pixel minimum.
    ///
    /// `Constants.centerPatchSizePx` (96) is the baseline at the default
    /// 4160×3120 capture; below that, the patch shrinks proportionally with
    /// the shorter texture dimension so we don't over-sample on a downsized
    /// lane. Floor of 16 keeps a 16×16 threadgroup viable.
    static func scaledCenterPatchSize(captureSize: Size) -> Int {
        let baseShorter = min(
            Constants.captureDefaultWidthPx,
            Constants.captureDefaultHeightPx
        )
        let curShorter = min(captureSize.width, captureSize.height)
        let scaled = Int(
            (Double(Constants.centerPatchSizePx)
                * Double(curShorter) / Double(baseShorter)).rounded())
        return max(16, scaled)
    }

    /// Encodes the center-patch sampler over a caller-supplied texture and returns one RgbSample.
    private func dispatchCenterPatch(on tex: MTLTexture) async throws -> RgbSample {
        let patchSize = Self.scaledCenterPatchSize(captureSize: captureSize)
        let texW = tex.width
        let texH = tex.height
        guard texW >= patchSize, texH >= patchSize else {
            throw MetalError.unsupportedFormat
        }

        var uniform = PatchUniform(
            patchSize: UInt32(patchSize),
            patchOriginX: UInt32((texW - patchSize) / 2),
            patchOriginY: UInt32((texH - patchSize) / 2)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalError.commandBufferFailed(code: -1)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferFailed(code: -2)
        }

        encoder.setComputePipelineState(centerPatchPSO)
        encoder.setTexture(tex, index: 0)
        encoder.setBuffer(patchBufferR, offset: 0, index: 0)
        encoder.setBuffer(patchBufferG, offset: 0, index: 1)
        encoder.setBuffer(patchBufferB, offset: 0, index: 2)
        encoder.setBytes(&uniform, length: MemoryLayout<PatchUniform>.stride, index: 3)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (patchSize + 15) / 16,
            height: (patchSize + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        let bufR = patchBufferR
        let bufG = patchBufferG
        let bufB = patchBufferB
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { cb in
                if cb.status == .error {
                    cont.resume(throwing: MetalError.commandBufferFailed(code: -3))
                } else {
                    cont.resume()
                }
            }
            commandBuffer.commit()
        }

        let count = patchSize * patchSize
        let trimCount = Int(Double(count) * Constants.centerPatchTrimRatio)
        let r = trimmedMean(buffer: bufR, count: count, trim: trimCount)
        let g = trimmedMean(buffer: bufG, count: count, trim: trimCount)
        let b = trimmedMean(buffer: bufB, count: count, trim: trimCount)
        return RgbSample(r: Double(r), g: Double(g), b: Double(b))
    }

    /// Public entry point — samples the latest **processed** texture (post Pass-2 grade).
    ///
    /// Used for diagnostic / metric paths. Calibration paths should prefer
    /// `dispatchCenterPatchOnNatural()` so the sample isn't biased by the
    /// previously-applied calibration state.
    func dispatchCenterPatch() async throws -> RgbSample {
        try await dispatchCenterPatch(on: currentProcessedTex())
    }

    /// WB calibration entry point — samples the latest **natural** texture (Pass-1 output).
    ///
    /// `naturalTex` carries the deterministic BT.601 full-range YCbCr→RGB
    /// matrix conversion of the AVF sample buffer — and **nothing else**. No
    /// shader-applied processing: no BCSG, no gamma curve, no saturation, no
    /// black-balance, no calibration-derived gains beyond what AVF already
    /// applied at the sensor. This is the most pre-grade signal accessible on
    /// the GPU; the only step further upstream is CPU readback of the NV12
    /// pixel buffer with manual YUV→RGB on CPU, which produces identical
    /// values. WB calibration must sample here so the gains computed don't
    /// feed back the previously-applied calibration state.
    func dispatchCenterPatchOnNatural() async throws -> RgbSample {
        // Read the live mailbox directly: do NOT route through `currentTexture()`,
        // which falls back to a blank pool buffer for the preview path. A
        // calibration sample of a blank texture is silently (0,0,0) — worse than
        // a thrown error. Single-writer invariant (delivery queue) + Metal's
        // command-buffer retention through encode make this read race-free.
        guard let naturalTex = latestNaturalTex else {
            throw MetalError.noFrameAvailable
        }
        return try await dispatchCenterPatch(on: naturalTex)
    }

    /// BB calibration entry point — samples a one-shot scratch render of
    /// **current BCSG with BB zeroed**.
    ///
    /// Why this lane: BB is applied at the end of the GPU color pipeline (post
    /// brightness/contrast/saturation/gamma) per `Shaders/ColorShaders.metal`.
    /// For BB to correctly subtract a dark patch in the *graded* image, the
    /// sample must be read from the same color space — i.e. with BCSG
    /// applied — but without the previously-written BB pedestal feeding back
    /// into the math.
    ///
    /// Implementation: snapshot the current `ColorUniform`, zero its BB
    /// triple, dispatch a one-shot Pass-2 encode from `naturalTex` into a
    /// scratch texture, then run the center-patch sampler on the scratch.
    /// Visually invisible to the user — the live `processedTex` mailbox is
    /// not touched.
    func dispatchBBCalibrationSample() async throws -> RgbSample {
        // Single-writer invariant (delivery queue) + Metal command-buffer
        // retention through encode make this nonisolated(unsafe) read race-free.
        guard let naturalTex = latestNaturalTex else {
            throw MetalError.noFrameAvailable
        }

        // Allocate scratch texture (released at function exit).
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: captureSize.width,
            height: captureSize.height,
            mipmapped: false
        )
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .private
        guard let scratchTex = commandQueue.device.makeTexture(descriptor: desc) else {
            throw MetalError.textureAllocationFailed
        }

        // Snapshot current BCSG uniforms; zero BB.
        //
        // Correctness: `uniforms.withLock { $0.color }` returns a *value copy*
        // of the ColorUniform struct. Mutating `params.blackR/G/B` writes to
        // the local copy only — the live Mutex is unmodified, so the regular
        // encode loop continues to use the user's actual BB. The shader below
        // reads from `&params` via setBytes (not from the Mutex), so it sees
        // the zeroed BB. Integration test in Stage11Tests proves this.
        var params = uniforms.withLock { $0.color }
        params.blackR = 0
        params.blackG = 0
        params.blackB = 0

        guard let cb = commandQueue.makeCommandBuffer(),
            let encoder = cb.makeComputeCommandEncoder()
        else {
            throw MetalError.commandBufferFailed(code: -11)
        }
        encoder.setComputePipelineState(colorTransformPSO)
        encoder.setTexture(naturalTex, index: 0)
        encoder.setTexture(scratchTex, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<ColorUniform>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (scratchTex.width + 15) / 16,
            height: (scratchTex.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            cb.addCompletedHandler { c in
                if c.status == .error {
                    cont.resume(throwing: MetalError.commandBufferFailed(code: -12))
                } else {
                    cont.resume()
                }
            }
            cb.commit()
        }

        return try await dispatchCenterPatch(on: scratchTex)
    }

    private func trimmedMean(buffer: MTLBuffer, count: Int, trim: Int) -> Float {
        let ptr = buffer.contents().bindMemory(to: Float.self, capacity: count)
        var values = Array(UnsafeBufferPointer(start: ptr, count: count))
        values.sort()
        guard count > 2 * trim else { return 0 }
        let lo = trim
        let hi = count - trim
        var sum: Float = 0
        for i in lo..<hi { sum += values[i] }
        return sum / Float(hi - lo)
    }

    // MARK: - Still capture (Stage 07)

    /// Arms the next-frame Pass 6 blit.
    ///
    /// Called by StillCapture after winning the CAS. Must be called before the next
    /// `encode()` invocation. The continuation will be resumed exactly once — either
    /// with the readback buffer on success, or with an error on GPU failure.
    func armCapture(continuation: CheckedContinuation<CVPixelBuffer, Error>) {
        pendingCaptureContinuation = continuation
    }

    // MARK: - Internal test seams

    /// Convenience init that creates its own gate and an empty ConsumerRegistry.
    ///
    /// Used by Stage02Tests to build a standalone pipeline without needing to
    /// import Atomics. `lanesEightBit` defaults to `false` so existing
    /// pool-count assertions stay valid.
    convenience init(
        device: MTLDevice,
        captureSize: Size,
        gateOpen: Bool = true,
        lanesEightBit: Bool = false
    ) throws {
        try self.init(
            device: device,
            captureSize: captureSize,
            gate: ManagedAtomic<Bool>(gateOpen),
            consumers: ConsumerRegistry(),
            engineSessionToken: ManagedAtomic<UInt64>(0),
            lanesEightBit: lanesEightBit
        )
    }

    /// Convenience init that accepts an explicit ConsumerRegistry but hides ManagedAtomic.
    ///
    /// Used by Stage06Tests so tests can inject a specific registry without
    /// importing Atomics. `lanesEightBit` defaults to `false` so existing
    /// pool-count assertions stay valid.
    convenience init(
        device: MTLDevice,
        captureSize: Size,
        gateOpen: Bool = true,
        consumers: ConsumerRegistry,
        lanesEightBit: Bool = false
    ) throws {
        try self.init(
            device: device,
            captureSize: captureSize,
            gate: ManagedAtomic<Bool>(gateOpen),
            consumers: consumers,
            engineSessionToken: ManagedAtomic<UInt64>(0),
            lanesEightBit: lanesEightBit
        )
    }

    /// Opens or closes the pipeline's submission gate.
    ///
    /// Used by Stage02Tests.
    func setGate(_ open: Bool) {
        submissionGate.store(open, ordering: .sequentiallyConsistent)
    }

    // MARK: - Test seams (internal — accessed via @testable import)

    // Stage 06: pool-backed buffer accessors replace the removed single-buffer properties.
    var latestNaturalBufferForTest: CVPixelBuffer? { latestNaturalBuffer }
    var latestProcessedBufferForTest: CVPixelBuffer? { latestProcessedBuffer }
    var latestTrackerBufferForTest: CVPixelBuffer? { latestTrackerBuffer }

    var texturePoolForTest: TexturePoolManager { texturePool }
    var naturalPoolForTest: CVPixelBufferPool { naturalPool }
    var processedPoolForTest: CVPixelBufferPool { processedPool }
    var trackerPoolForTest: CVPixelBufferPool { trackerPool }
    var trackerSizeForTest: Size { trackerSize }
    var stillCapturePoolForTest: CVPixelBufferPool? { stillCapturePool }
    var stillCaptureDequeueCountForTest: Int { stillCaptureDequeueCount }

    // Pre-Phase-3 — RGBA8 conversion test seams.
    var eightBitNaturalPoolForTest: CVPixelBufferPool? { eightBitNaturalPool }
    var eightBitProcessedPoolForTest: CVPixelBufferPool? { eightBitProcessedPool }
    /// Always nil; tracker lane is not converted (Plan OQ #4).
    var eightBitTrackerPoolForTest: CVPixelBufferPool? { nil }
    var lanesEightBitForTest: Bool { lanesEightBit }

    func setLatestNaturalForTest(buffer: CVPixelBuffer, texture: MTLTexture) {
        _latestNaturalBuffer.store(buffer)
        _latestNaturalTex.store(texture)
    }

    func setLatestProcessedForTest(buffer: CVPixelBuffer, texture: MTLTexture) {
        _latestProcessedBuffer.store(buffer)
        _latestProcessedTex.store(texture)
    }

    /// Writes color uniforms directly into the pipeline's uniforms Mutex.
    ///
    /// Mirrors the `uniforms.color` slice of the production path
    /// `CameraEngine.setProcessingParams` (which also routes through the
    /// session queue and KVO ingest). Used by Stage11Tests to inject known
    /// BCSG+BB state without needing a full engine. Crop uniforms are untouched.
    func setColorUniformsForTest(_ params: ProcessingParameters) {
        uniforms.withLock { storage in
            storage.color = ColorUniform(params)
        }
    }

    // Test-only: dispatches Pass 2 (color transform) over the latest natural texture,
    // awaits scheduled, and returns. Use after writing test-pattern bytes via lock/unlock.
    func encodePass2Only() async throws {
        let natTex = currentTexture()
        let procTex = currentProcessedTex()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalError.commandBufferFailed(code: -1)
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalError.commandBufferFailed(code: -2)
        }
        var color: ColorUniform = uniforms.withLock { $0.color }
        encoder.setComputePipelineState(colorTransformPSO)
        encoder.setTexture(natTex, index: 0)
        encoder.setTexture(procTex, index: 1)
        encoder.setBytes(&color, length: MemoryLayout<ColorUniform>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (procTex.width + 15) / 16,
            height: (procTex.height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        encoder.endEncoding()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { cb in
                if cb.status == .error {
                    cont.resume(throwing: MetalError.commandBufferFailed(code: -3))
                } else {
                    cont.resume()
                }
            }
            commandBuffer.commit()
        }
    }
}
