import CoreMedia
import CoreVideo
import Metal

/// Wraps `CVMetalTextureCache` to vend `MTLTexture` views over `CVPixelBuffer` planes
/// delivered by AVFoundation sample buffers.
///
/// ADR-06: CPU access to frame data is ONLY through IOSurface-backed `CVPixelBuffer`.
/// `MTLTexture.getBytes` is never called; all textures are zero-copy wrappers.
///
/// `@unchecked Sendable`: instances are captured in `@Sendable` closures on the
/// `delivery` queue. The texture cache is accessed only from that queue.
final class TexturePoolManager: @unchecked Sendable {

    private let device: MTLDevice
    private var textureCache: CVMetalTextureCache?

    /// Creates the `CVMetalTextureCache` backed by `device`.
    /// - Throws: `MetalError.textureCacheCreateFailed` if the cache cannot be created.
    init(device: MTLDevice) throws {
        self.device = device
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess, let cache else {
            throw MetalError.textureCacheCreateFailed(code: status)
        }
        self.textureCache = cache
    }

    /// Wraps the luma (Y) plane of a YUV `CVPixelBuffer` as an `MTLTexture`.
    ///
    /// Used by `MetalPipeline` for the YUV→RGBA compute pass (plane index 0, `.r8Unorm`).
    /// - Parameter pixelBuffer: An IOSurface-backed buffer from an AVFoundation sample buffer.
    /// - Returns: An `MTLTexture` view over the Y plane; zero-copy, no CPU readback.
    /// - Throws: `MetalError.textureWrapFailed` if `CVMetalTextureCacheCreateTextureFromImage` fails.
    func makeYTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        try makeTexture(from: pixelBuffer, planeIndex: 0, pixelFormat: .r8Unorm)
    }

    /// Wraps the interleaved chroma (CbCr) plane of a YUV `CVPixelBuffer` as an `MTLTexture`.
    ///
    /// Used by `MetalPipeline` for the YUV→RGBA compute pass (plane index 1, `.rg8Unorm`).
    /// - Parameter pixelBuffer: An IOSurface-backed buffer from an AVFoundation sample buffer.
    /// - Returns: An `MTLTexture` view over the CbCr plane; zero-copy, no CPU readback.
    /// - Throws: `MetalError.textureWrapFailed` if `CVMetalTextureCacheCreateTextureFromImage` fails.
    func makeCbCrTexture(from pixelBuffer: CVPixelBuffer) throws -> MTLTexture {
        try makeTexture(from: pixelBuffer, planeIndex: 1, pixelFormat: .rg8Unorm)
    }

    /// Flushes stale entries from the texture cache.
    ///
    /// Call once per frame after the Metal command buffer completes so the cache
    /// does not hold retired `CVPixelBuffer` references longer than necessary.
    func flush() {
        CVMetalTextureCacheFlush(textureCache!, 0)
    }

    // MARK: - Stage 04 — IOSurface-backed working textures

    /// Allocates a single IOSurface-backed `CVPixelBuffer` of pixel format
    /// `kCVPixelFormatType_64RGBAHalf` and returns a paired `MTLTexture` view
    /// of the same memory (zero-copy, format `.rgba16Float`).
    ///
    /// Storage mode: `.shared` (D-02, ADR-20 start-simple default). The buffer
    /// is retained by the caller (`MetalPipeline`) for the session lifetime —
    /// the GPU writes through the `MTLTexture` view and tests read through
    /// `CVPixelBufferLockBaseAddress` (ADR-06: never `MTLTexture.getBytes`).
    ///
    /// - Parameter size: Texture dimensions in pixels.
    /// - Returns: The retained `CVPixelBuffer` (caller must keep) and the
    ///   `MTLTexture` view backed by its IOSurface.
    /// - Throws: `MetalError.unsupportedFormat` if buffer creation fails;
    ///   `MetalError.textureWrapFailed` if the texture cache rejects the buffer.
    func makeIOSurfaceBackedRGBA16F(size: Size) throws -> (buffer: CVPixelBuffer, texture: MTLTexture) {
        // 1. Allocate the CVPixelBuffer with IOSurface + Metal compatibility.
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pixelBufferOut: CVPixelBuffer?
        let createStatus = CVPixelBufferCreate(
            kCFAllocatorDefault,
            size.width,
            size.height,
            kCVPixelFormatType_64RGBAHalf,
            attrs as CFDictionary,
            &pixelBufferOut
        )
        guard createStatus == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw MetalError.unsupportedFormat
        }

        // 2. Wrap as an MTLTexture (zero-copy view onto the IOSurface).
        var cvTexOut: CVMetalTexture?
        let wrapStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            .rgba16Float,
            size.width,
            size.height,
            0,
            &cvTexOut
        )
        guard wrapStatus == kCVReturnSuccess, let cvTex = cvTexOut,
            let mtlTex = CVMetalTextureGetTexture(cvTex)
        else {
            throw MetalError.textureWrapFailed(code: wrapStatus)
        }

        // 3. Caller retains both `pixelBuffer` (via the returned tuple) and
        //    the `MTLTexture` (via storage in MetalPipeline). The intermediate
        //    `cvTex` reference is implicitly held by the cache — flush() will
        //    release it eventually. (Apple docs: "maintain a strong reference
        //    to textureOut until the GPU finishes…" — caller stores `mtlTex`
        //    and `pixelBuffer` for the session, satisfying that contract.)
        return (buffer: pixelBuffer, texture: mtlTex)
    }

    // MARK: - Stage 06 — Per-stream CVPixelBufferPool

    /// Creates a `CVPixelBufferPool` that vends IOSurface-backed, Metal-compatible
    /// RGBA16F `CVPixelBuffer`s at `size` per ADR-19 / D-02.
    ///
    /// `POOL_MIN_BUFFER_COUNT` = 3 (mailbox ref + GPU write slot + slack).
    /// `POOL_MAX_BUFFER_AGE_SECONDS` = 1.0 (CF-managed age-out).
    /// `kCVPixelBufferIOSurfacePropertiesKey: [:]`.
    /// `kCVPixelBufferMetalCompatibilityKey: true`.
    /// `kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_64RGBAHalf`.
    ///
    /// Growth past `MinimumBufferCount` is CF-managed; the effective cap is
    /// `POOL_CAP_RULE = N_active_lanes + 1` which the caller enforces by only
    /// dequeuing a tracker buffer when a tracker subscriber is active.
    func makeWorkingFormatPool(size: Size) throws -> CVPixelBufferPool {
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: Constants.poolMinBufferCount,
            kCVPixelBufferPoolMaximumBufferAgeKey: Constants.poolMaxBufferAgeSeconds,
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_64RGBAHalf,
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw MetalError.unsupportedFormat
        }
        return pool
    }

    /// Creates a `CVPixelBufferPool` that vends IOSurface-backed, Metal-compatible
    /// **BGRA8** `CVPixelBuffer`s for the RGBA8 lane-conversion path (Pass-7).
    ///
    /// Parallel to `makeWorkingFormatPool` but emits
    /// `kCVPixelFormatType_32BGRA` instead of `_64RGBAHalf`. Same pool
    /// attributes (`POOL_MIN_BUFFER_COUNT`, `POOL_MAX_BUFFER_AGE_SECONDS`,
    /// IOSurface + Metal compatibility).
    func makeBgra8LanePool(size: Size) throws -> CVPixelBufferPool {
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: Constants.poolMinBufferCount,
            kCVPixelBufferPoolMaximumBufferAgeKey: Constants.poolMaxBufferAgeSeconds,
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Constants.eightBitLanePixelFormat,
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else {
            throw MetalError.unsupportedFormat
        }
        return pool
    }

    /// Dequeues a BGRA8 buffer and wraps it as a writeable
    /// `MTLPixelFormat.bgra8Unorm` texture through the shared
    /// `CVMetalTextureCache`.
    ///
    /// Parallel to `dequeuePoolTexture` but pairs the 8-bit pool with a
    /// `.bgra8Unorm` texture view. Pass-7 kernel writes through this view.
    /// Zero-copy; the caller retains `buffer` until the GPU completion
    /// handler fires (Apple CoreVideo contract).
    func dequeueEightBitPoolTexture(
        pool: CVPixelBufferPool,
        width: Int,
        height: Int
    ) throws -> (buffer: CVPixelBuffer, texture: MTLTexture) {
        var buf: CVPixelBuffer?
        let s = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
        guard s == kCVReturnSuccess, let buffer = buf else {
            throw MetalError.unsupportedFormat
        }
        var cvTexOut: CVMetalTexture?
        let wrap = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            buffer,
            nil,
            Constants.eightBitLaneMetalFormat,
            width,
            height,
            0,
            &cvTexOut
        )
        guard wrap == kCVReturnSuccess, let cvTex = cvTexOut,
            let mtlTex = CVMetalTextureGetTexture(cvTex)
        else {
            throw MetalError.textureWrapFailed(code: wrap)
        }
        return (buffer, mtlTex)
    }

    /// Dequeues a buffer from `pool` and wraps it as an `MTLTexture` view through
    /// the shared `CVMetalTextureCache`.
    ///
    /// Zero-copy; the caller retains `buffer` until the GPU completion handler fires
    /// (Apple CoreVideo contract).
    ///
    /// - Throws: `MetalError.unsupportedFormat` on dequeue failure,
    ///   `MetalError.textureWrapFailed` on cache-wrap failure.
    func dequeuePoolTexture(
        pool: CVPixelBufferPool,
        width: Int,
        height: Int
    ) throws -> (buffer: CVPixelBuffer, texture: MTLTexture) {
        var buf: CVPixelBuffer?
        let s = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
        guard s == kCVReturnSuccess, let buffer = buf else {
            throw MetalError.unsupportedFormat
        }
        var cvTexOut: CVMetalTexture?
        let wrap = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            buffer,
            nil,
            .rgba16Float,
            width,
            height,
            0,
            &cvTexOut
        )
        guard wrap == kCVReturnSuccess, let cvTex = cvTexOut,
            let mtlTex = CVMetalTextureGetTexture(cvTex)
        else {
            throw MetalError.textureWrapFailed(code: wrap)
        }
        return (buffer, mtlTex)
    }

    // MARK: - Stage 10 — Encoder NV12 pool + plane-texture dequeue

    /// Encoder pool — NV12 video-range, IOSurface-backed, Metal-compatible.
    ///
    /// Feeds Pass 5 GPU writes and AVAssetWriterInputPixelBufferAdaptor.append() reads.
    func makeEncoderNV12Pool(size: Size) throws -> CVPixelBufferPool {
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: Constants.poolMinBufferCount
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(Constants.encoderPixelFormat),
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let p = pool else {
            throw MetalError.textureCacheCreateFailed(code: status)
        }
        return p
    }

    /// Dequeue an encoder buffer and wrap both planes as write-capable MTLTextures.
    func dequeueEncoderBuffer(
        pool: CVPixelBufferPool
    ) throws -> (buffer: CVPixelBuffer, yTex: MTLTexture, cbcrTex: MTLTexture) {
        var buf: CVPixelBuffer?
        let s = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf)
        guard s == kCVReturnSuccess, let b = buf else {
            throw MetalError.textureCacheCreateFailed(code: s)
        }
        let y = try makePlaneWriteTexture(from: b, planeIndex: 0, format: .r8Unorm)
        let cbcr = try makePlaneWriteTexture(from: b, planeIndex: 1, format: .rg8Unorm)
        return (b, y, cbcr)
    }

    private func makePlaneWriteTexture(
        from pixelBuffer: CVPixelBuffer,
        planeIndex: Int,
        format: MTLPixelFormat
    ) throws -> MTLTexture {
        guard let cache = textureCache else { throw MetalError.textureCacheCreateFailed(code: -1) }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            format,
            width,
            height,
            planeIndex,
            &cvTexture
        )
        guard
            status == kCVReturnSuccess,
            let cvTex = cvTexture,
            let mtlTex = CVMetalTextureGetTexture(cvTex)
        else {
            throw MetalError.textureWrapFailed(code: status)
        }
        return mtlTex
    }

    // MARK: - Private

    private func makeTexture(
        from pixelBuffer: CVPixelBuffer,
        planeIndex: Int,
        pixelFormat: MTLPixelFormat
    ) throws -> MTLTexture {
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache!,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTexture else {
            throw MetalError.textureWrapFailed(code: status)
        }

        // Safe: create succeeded, so the texture object is guaranteed non-nil.
        return CVMetalTextureGetTexture(cvTexture)!
    }
}

// MARK: - Test seams (internal — accessed via @testable import)
#if DEBUG
extension TexturePoolManager {
    /// Test seam: creates an encoder NV12 pool without needing a live MTLDevice or texture cache.
    ///
    /// Builds the pool directly using CVPixelBufferPoolCreate — no instance state is touched.
    static func makeEncoderNV12PoolForTest(size: Size) throws -> CVPixelBufferPool {
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: Constants.poolMinBufferCount
        ]
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(Constants.encoderPixelFormat),
            kCVPixelBufferWidthKey: size.width,
            kCVPixelBufferHeightKey: size.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            bufferAttrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let p = pool else {
            throw MetalError.textureCacheCreateFailed(code: status)
        }
        return p
    }
}
#endif
