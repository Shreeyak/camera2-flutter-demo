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

/// Owns the GPU pipeline that converts YUV sample buffers through RGBA16F
/// compute passes and delivers BGRA8 lane surfaces (preview, bridge, tracker,
/// still capture).
///
/// RGBA16F is the internal math format; BGRA8 is the single delivery format.
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

    // RGBA8 lane conversion — unconditional for natural + processed.
    //
    // Pass-7 dispatches per-frame for natural + processed and writes into these
    // IOSurface-backed BGRA8 pools. The tracker lane uses a fused approach:
    // `trackerPool` is itself BGRA8, so Pass-4's downsample writes BGRA8 directly
    // with no separate conversion pass. All three buffer mailboxes deliver BGRA8
    // to `CameraEngine.currentPixelBuffer(stream:)` for the Phase-3 bridge. See
    // `docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md`.
    private let eightBitNaturalPool: CVPixelBufferPool
    private let eightBitProcessedPool: CVPixelBufferPool
    private let rgba16fToBgra8PSO: MTLComputePipelineState

    private(set) var captureSize: Size

    /// P2a true crop — the output (natural/processed/still/encoder/8-bit) texture
    /// size.
    ///
    /// Equals `captureSize` when uncropped. When a crop is active, this is the
    /// crop-region size: the AVCaptureSession keeps producing `captureSize`
    /// sensor buffers, and Pass-1 reads the `cropOrigin`-offset sub-region into
    /// these `outputSize` output textures (a sub-region resolution change, not a
    /// zoom). The SOURCE Y/CbCr textures still derive their size from the
    /// incoming sample buffer (= sensor).
    private(set) var outputSize: Size

    /// P2a true crop — top-left of the sub-region read from the sensor, in
    /// sensor pixels.
    ///
    /// `(0, 0)` when uncropped. Carried into Pass-1's `CropUniform.origin*` so
    /// the shader offsets every source read by it.
    private(set) var cropOrigin: (x: Int, y: Int)

    private let trackerSize: Size

    /// Internal RGBA16F "latest" textures — Metal-compute intermediates, NOT a
    /// delivery surface.
    ///
    /// `_latestNaturalTex16F` is the Pass-1 output sampled by WB/BB calibration
    /// (`dispatchCenterPatchOnNatural` / `dispatchBBCalibrationSample`);
    /// `_latestProcessedTex16F` is the Pass-2 graded output sampled by the
    /// diagnostic center-patch (`dispatchCenterPatch` / `sampleCenterPatch`).
    /// They stay 16F because the math wants float headroom — the camera is
    /// 8-bit-locked, so this precision only buys anything in-shader, never at
    /// the delivery boundary. The preview/bridge surfaces are the BGRA8
    /// mailboxes below.
    ///
    /// Single writer on the AVF delivery queue (`addCompletedHandler`
    /// callback); readers on MainActor / sessionQueue. See `Mailbox<T>` for the
    /// safety contract. G-13 / Stage 06 design.
    private let _latestNaturalTex16F = Mailbox<MTLTexture>()
    private let _latestProcessedTex16F = Mailbox<MTLTexture>()
    private let _latestTrackerTex = Mailbox<MTLTexture>()

    var latestNaturalTex16F: MTLTexture? { _latestNaturalTex16F.latest }
    var latestProcessedTex16F: MTLTexture? { _latestProcessedTex16F.latest }
    /// Tracker texture — `.bgra8Unorm` (Pass-4 writes directly into the BGRA8
    /// tracker pool; no separate 16F texture exists for this lane).
    var latestTrackerTex: MTLTexture? { _latestTrackerTex.latest }

    /// Preview/bridge-facing BGRA8 lane textures (natural + processed).
    ///
    /// Each is the `.bgra8Unorm` view of the Pass-7 convert output, sharing its
    /// IOSurface with the matching `_latest*Buffer` mailbox — so a lane exposes
    /// one surface as both a `CVPixelBuffer` and an `MTLTexture`. The public
    /// `CameraEngine.currentTexture()` / `currentProcessedTexture()` accessors
    /// read these; the MTKView preview and the Phase-3 bridge get identical
    /// 8-bit pixels. Single writer on the delivery queue (`Mailbox<T>`).
    private let _latestNaturalBgra8Tex = Mailbox<MTLTexture>()
    private let _latestProcessedBgra8Tex = Mailbox<MTLTexture>()

    var latestNaturalBgra8Tex: MTLTexture? { _latestNaturalBgra8Tex.latest }
    var latestProcessedBgra8Tex: MTLTexture? { _latestProcessedBgra8Tex.latest }

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

    /// Retains the pre-first-frame fallback scratch buffer for the processed lane.
    ///
    /// Keeps the returned blank texture valid through the caller's GPU dispatch
    /// (CoreVideo retain contract). Separate from `_latestProcessedBuffer`: the
    /// scratch is RGBA16F, not a BGRA8 delivery surface, and must never reach
    /// `currentPixelBuffer(stream:)`.
    private let _processedFallbackScratch = Mailbox<CVPixelBuffer>()

    /// PTS (in nanoseconds) of the most recent CMSampleBuffer encoded into `latestNaturalTex16F`.
    ///
    /// Read by `CameraEngine.awaitNaturalAfter` to confirm the natural texture
    /// has been refreshed past a target buffer timestamp (e.g. the `t_apply`
    /// from `setWhiteBalanceModeLocked(...handler:)`). Stored as Int64 ns to
    /// allow lock-free CAS reads. Single writer: completion handler on the
    /// delivery queue.
    let latestNaturalPTSNs: ManagedAtomic<Int64> = ManagedAtomic(0)

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
    ///   - captureSize: Sensor/source dimensions reported by `CameraSession.configure()`.
    ///   - outputSize: P2a true-crop output texture size. `nil` (default) means
    ///     no crop — output equals `captureSize`. When a crop is active, this is
    ///     the crop-region size.
    ///   - cropOrigin: P2a true-crop top-left in sensor pixels. `(0, 0)` (default)
    ///     when uncropped.
    ///   - gate: Shared `ManagedAtomic<Bool>` owned by `CameraEngine` (ADR-09).
    ///   - consumers: `ConsumerRegistry` owned by `CameraEngine`; used to publish
    ///     `FrameSet` values on the delivery queue.
    /// - Throws: `MetalError.pipelineStateCompilation` if the Metal library or
    ///   kernel cannot be loaded, or if PSO compilation fails.
    init(
        device: MTLDevice,
        captureSize: Size,
        outputSize: Size? = nil,
        cropOrigin: (x: Int, y: Int) = (0, 0),
        gate: ManagedAtomic<Bool>,
        consumers: ConsumerRegistry,
        engineSessionToken: ManagedAtomic<UInt64>
    ) throws {
        submissionGate = gate
        self.engineSessionToken = engineSessionToken
        self.consumers = consumers
        self.captureSize = captureSize
        let resolvedOutputSize = outputSize ?? captureSize
        self.outputSize = resolvedOutputSize
        self.cropOrigin = cropOrigin

        // Tracker dimensions: preserve OUTPUT aspect ratio, scale to trackerHeightPx.
        // P2a — the tracker downsamples the rendered natural (which is now
        // outputSize), so its aspect must follow outputSize, not the sensor.
        let trackerH = Constants.trackerHeightPx
        let aspect = Double(resolvedOutputSize.width) / Double(resolvedOutputSize.height)
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
        //     P2a — the crop uniform is now set ONCE at construction and carries
        //     the sensor-pixel origin of the sub-region Pass-1 reads. It is no
        //     longer mutated per-frame (the Stage-04 black-out masking retired).
        //     `width`/`height` mirror the output (crop-region) size; the shader
        //     ignores them and uses the output texture's own dims.
        uniforms = Mutex(
            UniformStorage(
                color: .identity,
                crop: CropUniform(
                    originX: UInt32(cropOrigin.x),
                    originY: UInt32(cropOrigin.y),
                    width: UInt32(resolvedOutputSize.width),
                    height: UInt32(resolvedOutputSize.height)
                )
            ))

        // 5. Command queue.
        commandQueue = device.makeCommandQueue()!

        // 6. Per-stream CVPixelBufferPools (Stage 06 pool-backed lineage).
        //    P2a — natural/processed pools size to `outputSize` (the crop region),
        //    NOT the sensor. Tracker derives from `trackerSize` (already scaled
        //    to the output aspect above).
        naturalPool = try texturePool.makeWorkingFormatPool(size: resolvedOutputSize)
        processedPool = try texturePool.makeWorkingFormatPool(size: resolvedOutputSize)
        // Tracker pool is BGRA8 — Pass-4's kernel writes `float4` via
        // `texture2d<float, access::write>`, so a `.bgra8Unorm` output texture
        // clamps [0,1] and stores BGRA8 with no shader edit (Task 2, 8-bit
        // BGRA end-to-end delivery design).
        trackerPool = try texturePool.makeBgra8LanePool(size: trackerSize)

        // 6b. RGBA8 lane conversion — unconditional for natural + processed.
        //     P2a — sized to outputSize (the crop region), not the sensor.
        self.eightBitNaturalPool = try texturePool.makeBgra8LanePool(size: resolvedOutputSize)
        self.eightBitProcessedPool = try texturePool.makeBgra8LanePool(size: resolvedOutputSize)
        guard let fnConvert = library.makeFunction(name: "rgba16fToBgra8") else {
            throw MetalError.pipelineStateCompilation("rgba16fToBgra8 missing")
        }
        self.rgba16fToBgra8PSO = try device.makeComputePipelineState(function: fnConvert)

        // 9. Stage 10: encoder NV12 pool + rgba16fToNV12 PSO (Pass 5).
        //    P2a — Pass-5 encodes processedTexI (outputSize); NV12 pool follows.
        encoderPool = try texturePool.makeEncoderNV12Pool(size: resolvedOutputSize)
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
                pool: naturalPool, width: outputSize.width, height: outputSize.height)
            processedPair = try texturePool.dequeuePoolTexture(
                pool: processedPool, width: outputSize.width, height: outputSize.height)
        } catch {
            return  // pool exhausted — drop frame
        }

        // Tracker buffer only when someone is subscribed to .tracker (no wasteful alloc).
        // Pool is BGRA8; dequeueEightBitPoolTexture wraps it as .bgra8Unorm — Pass-4's
        // shader writes float4 into a bgra8Unorm output which clamps and stores BGRA8.
        let trackerPair: (buffer: CVPixelBuffer, texture: MTLTexture)?
        if consumers.hasSubscriber(.tracker) {
            trackerPair = try? texturePool.dequeueEightBitPoolTexture(
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

        // Pass 7: RGBA16F → BGRA8 conversion for the natural + processed lane-buffer
        // mailboxes (unconditional). Tracker is NOT converted here — its pool is already
        // BGRA8; Pass-4 writes BGRA8 directly (fused). Not subscriber-gated in v1.
        // Pass-7 reads the RGBA16F lane texture and writes into a fresh BGRA8 pool
        // buffer's .bgra8Unorm view; the buffer mailbox below points at the new buffer.
        var naturalEightBitPair: (buffer: CVPixelBuffer, texture: MTLTexture)?
        var processedEightBitPair: (buffer: CVPixelBuffer, texture: MTLTexture)?
        if let pair = try? texturePool.dequeueEightBitPoolTexture(
            pool: eightBitNaturalPool, width: outputSize.width, height: outputSize.height
        ) {
            let pass7n = commandBuffer.makeComputeCommandEncoder()!
            pass7n.setComputePipelineState(rgba16fToBgra8PSO)
            pass7n.setTexture(naturalTexI, index: 0)
            pass7n.setTexture(pair.texture, index: 1)
            pass7n.dispatchThreadgroups(
                threadGroups, threadsPerThreadgroup: threadGroupSize)
            pass7n.endEncoding()
            naturalEightBitPair = pair
        }
        if let pair = try? texturePool.dequeueEightBitPoolTexture(
            pool: eightBitProcessedPool, width: outputSize.width, height: outputSize.height
        ) {
            let pass7p = commandBuffer.makeComputeCommandEncoder()!
            pass7p.setComputePipelineState(rgba16fToBgra8PSO)
            pass7p.setTexture(processedTexI, index: 0)
            pass7p.setTexture(pair.texture, index: 1)
            pass7p.dispatchThreadgroups(
                threadGroups, threadsPerThreadgroup: threadGroupSize)
            pass7p.endEncoding()
            processedEightBitPair = pair
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
        // Stage 10: extract NV12 buffer for delivery in completion handler.
        let encoderBufForCompletion: CVPixelBuffer? = encoderPairForCompletion?.buffer
        // Capture the BGRA8-converted buffers + textures for the mailbox store in
        // the completion handler. Each pair's buffer and texture share one
        // IOSurface. Tracker buffer is already BGRA8 (pool fused in Pass-4).
        let naturalEightBitBuf: CVPixelBuffer? = naturalEightBitPair?.buffer
        let naturalEightBitTex: MTLTexture? = naturalEightBitPair?.texture
        let processedEightBitBuf: CVPixelBuffer? = processedEightBitPair?.buffer
        let processedEightBitTex: MTLTexture? = processedEightBitPair?.texture

        // FrameSet delivers BGRA8 for all three lanes to the C++/AsyncStream
        // consumers (CannyConsumer format-branches on _32BGRA). The `?? <16F>`
        // fallbacks only fire if a Pass-7 dequeue was dropped on pool
        // exhaustion (rare); the tracker falls back to the BGRA8 natural buffer.
        let naturalForSet: CVPixelBuffer = naturalEightBitBuf ?? naturalBuf
        let processedForSet: CVPixelBuffer = processedEightBitBuf ?? processedBuf
        let trackerForSet: CVPixelBuffer = trackerBuf ?? naturalForSet

        // D-10: capture the session token at commit. Handler no-ops if the token has
        // advanced (close() / recovery ran) — prevents stale FrameSet publish and
        // stale mailbox stores after teardown/recovery (G-20).
        let tokenAtCommit = self.engineSessionToken.load(ordering: .acquiring)
        commandBuffer.addCompletedHandler { [weak self] cb in
            guard let self else { return }
            let liveToken = self.engineSessionToken.load(ordering: .acquiring)
            if liveToken != tokenAtCommit {
                // Session advanced — drop this frame's delivery entirely.
                self.didNoOpCountForTest &+= 1
                return
            }
            // Metal-level error classification (G-02 / ADR-15).
            if cb.status == .error {
                let code = (cb.error as NSError?)?.code ?? -1
                self.onMetalError?(MetalError.commandBufferFailed(code: code))
                return
            }
            // Stage 10: deliver NV12 encoder buffer if Pass 5 ran and command buffer succeeded.
            if let encBuf = encoderBufForCompletion, cb.status == .completed {
                self.onEncodedBufferReady?(encBuf, captureTime)
            }
            // Construct FrameSet from delivery-queue-local captures only.
            let fs = FrameSet(
                frameNumber: fn,
                captureTime: captureTime,
                natural: naturalForSet,
                processed: processedForSet,
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
            // Update lane mailboxes. Delivery is BGRA8 for every lane and every
            // surface type: the buffer mailboxes (natural/processed via Pass-7,
            // tracker via the fused Pass-4 pool) AND the natural/processed
            // texture mailboxes (`_latest*Bgra8Tex`, sharing the buffer's
            // IOSurface). The 16F texture mailboxes are kept only as internal
            // compute intermediates for calibration/diagnostic sampling — never
            // delivered. Still capture (`captureImage` / `captureNaturalPicture`)
            // reads the BGRA8 buffer mailboxes directly.
            self._latestNaturalBuffer.store(naturalEightBitBuf ?? naturalBuf)
            self._latestNaturalTex16F.store(naturalTexI)
            if let nTex = naturalEightBitTex { self._latestNaturalBgra8Tex.store(nTex) }
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
            self._latestProcessedTex16F.store(processedTexI)
            if let pTex = processedEightBitTex { self._latestProcessedBgra8Tex.store(pTex) }
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

    /// Returns the latest processed texture for the right-half MTKView.
    ///
    /// Reads the internal `latestProcessedTex16F` `Mailbox<T>` (G-13
    /// single-writer model) — the RGBA16F Pass-2 graded output, sampled by
    /// `dispatchCenterPatch` / `sampleCenterPatch` (NOT the BGRA8 preview
    /// surface). Falls back to dequeuing a blank pool buffer on the first call
    /// before any frame arrives.
    func currentProcessedTex() -> MTLTexture {
        if let t = latestProcessedTex16F { return t }
        if let pair = try? texturePool.dequeuePoolTexture(
            pool: processedPool, width: outputSize.width, height: outputSize.height
        ) {
            // Pre-first-frame fallback: retain the RGBA16F scratch buffer in a
            // dedicated slot (NOT `_latestProcessedBuffer`, which is the BGRA8
            // delivery surface) so the returned blank texture stays valid for
            // the caller's GPU dispatch.
            _processedFallbackScratch.store(pair.buffer)
            _latestProcessedTex16F.store(pair.texture)
            return pair.texture
        }
        fatalError("MetalPipeline.currentProcessedTex: no preview texture available")
    }

    /// Pre-seed the natural + processed preview mailboxes with blank pool
    /// buffers so both lanes are non-nil immediately after `open()`.
    ///
    /// Without this, `CameraEngine.currentTexture()` / `currentPixelBuffer(stream:)`
    /// are nil on the first `open()` until a frame is encoded, so the Flutter
    /// texture bridge registers id 0 and the natural lane stays black until a
    /// close→open cycle (measurements 2026-05-20 §1, P2b). Mirrors the mailboxes
    /// `encode()` writes: the RGBA16F texture (calibration sampling), the BGRA8
    /// texture (bridge accessors), and the BGRA8 buffer (FlutterTexture). Sizes to
    /// `outputSize` so a seeded crop matches its frames. Idempotent and
    /// best-effort — a no-op once a frame has populated the mailboxes, and a pool
    /// miss simply leaves the mailbox nil (today's behavior). Fresh pool buffers
    /// are zero-filled, so the seeded frame is black, never uninitialized garbage.
    func seedPreviewMailboxes() {
        guard latestNaturalTex16F == nil else { return }
        if let nat = try? texturePool.dequeuePoolTexture(
            pool: naturalPool, width: outputSize.width, height: outputSize.height)
        {
            _latestNaturalTex16F.store(nat.texture)
        }
        if let nat8 = try? texturePool.dequeueEightBitPoolTexture(
            pool: eightBitNaturalPool, width: outputSize.width, height: outputSize.height)
        {
            _latestNaturalBgra8Tex.store(nat8.texture)
            _latestNaturalBuffer.store(nat8.buffer)
        }
        if let proc = try? texturePool.dequeuePoolTexture(
            pool: processedPool, width: outputSize.width, height: outputSize.height)
        {
            _latestProcessedTex16F.store(proc.texture)
        }
        if let proc8 = try? texturePool.dequeueEightBitPoolTexture(
            pool: eightBitProcessedPool, width: outputSize.width, height: outputSize.height)
        {
            _latestProcessedBgra8Tex.store(proc8.texture)
            _latestProcessedBuffer.store(proc8.buffer)
        }
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
        // P2a — patch scales to the OUTPUT (crop-region) size, since the natural/
        // processed textures sampled here are now `outputSize`. The static
        // method's `captureSize:` label is kept to avoid cross-file churn.
        let patchSize = Self.scaledCenterPatchSize(captureSize: outputSize)
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
        guard let naturalTex = latestNaturalTex16F else {
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
        guard let naturalTex = latestNaturalTex16F else {
            throw MetalError.noFrameAvailable
        }

        // Allocate scratch texture (released at function exit).
        // P2a — match the natural texture being graded, i.e. `outputSize`.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: outputSize.width,
            height: outputSize.height,
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

    // MARK: - Internal test seams

    /// Convenience init that creates its own gate and an empty ConsumerRegistry.
    ///
    /// Used by Stage02Tests to build a standalone pipeline without needing to
    /// import Atomics.
    convenience init(
        device: MTLDevice,
        captureSize: Size,
        outputSize: Size? = nil,
        cropOrigin: (x: Int, y: Int) = (0, 0),
        gateOpen: Bool = true
    ) throws {
        try self.init(
            device: device,
            captureSize: captureSize,
            outputSize: outputSize,
            cropOrigin: cropOrigin,
            gate: ManagedAtomic<Bool>(gateOpen),
            consumers: ConsumerRegistry(),
            engineSessionToken: ManagedAtomic<UInt64>(0)
        )
    }

    /// Convenience init that accepts an explicit ConsumerRegistry but hides ManagedAtomic.
    ///
    /// Used by Stage06Tests so tests can inject a specific registry without
    /// importing Atomics.
    convenience init(
        device: MTLDevice,
        captureSize: Size,
        outputSize: Size? = nil,
        cropOrigin: (x: Int, y: Int) = (0, 0),
        gateOpen: Bool = true,
        consumers: ConsumerRegistry
    ) throws {
        try self.init(
            device: device,
            captureSize: captureSize,
            outputSize: outputSize,
            cropOrigin: cropOrigin,
            gate: ManagedAtomic<Bool>(gateOpen),
            consumers: consumers,
            engineSessionToken: ManagedAtomic<UInt64>(0)
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

    // RGBA8 conversion test seams.
    var eightBitNaturalPoolForTest: CVPixelBufferPool { eightBitNaturalPool }
    var eightBitProcessedPoolForTest: CVPixelBufferPool { eightBitProcessedPool }
    // Note: there is no separate eightBitTrackerPool — the tracker pool itself is
    // BGRA8 (fused into Pass-4). Use `trackerPoolForTest` to inspect tracker format.

    func setLatestNaturalForTest(buffer: CVPixelBuffer, texture: MTLTexture) {
        _latestNaturalBuffer.store(buffer)
        _latestNaturalTex16F.store(texture)
    }

    func setLatestProcessedForTest(buffer: CVPixelBuffer, texture: MTLTexture) {
        _latestProcessedBuffer.store(buffer)
        _latestProcessedTex16F.store(texture)
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
    // awaits scheduled, and returns. Use after installing natural + processed
    // textures via `setLatestNaturalForTest` / `setLatestProcessedForTest`.
    func encodePass2Only() async throws {
        guard let natTex = latestNaturalTex16F, let procTex = latestProcessedTex16F else {
            throw MetalError.noFrameAvailable
        }
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
