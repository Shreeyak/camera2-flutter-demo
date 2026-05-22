import CoreVideo
import Foundation
import Metal
import Synchronization
import Testing

@testable import CameraKit

@Suite("Stage04Tests", .progressLogged)
struct Stage04Tests {

    // MARK: - Test 1 — 04:color-pipeline-golden-frame

    /// Inject a known half-float RGBA pattern into naturalTex (via IOSurface).
    ///
    /// Run Pass 2 with identity ProcessingParameters, and assert processedTex
    /// matches naturalTex byte-for-byte modulo rgba16Float ULP. Then apply
    /// brightness=+0.2 and assert the closed-form luminance shift.
    @Test func colorPipelineGoldenFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 64, height: 64)
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        // Identity uniforms → byte-for-byte equality (within rgba16Float ULP).
        pipeline.uniforms.withLock { $0.color = ColorUniform(.identity) }

        // Dequeue a natural buffer from the pool, fill it, then install it as latest.
        let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        try fillBufferUniform(nBuf, r: 0.5, g: 0.5, b: 0.5, a: 1.0)
        pipeline.setLatestNaturalForTest(buffer: nBuf, texture: nTex)

        // Dequeue a processed buffer to receive the output.
        let (pBuf, pTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
        pipeline.setLatestProcessedForTest(buffer: pBuf, texture: pTex)

        try await pipeline.encodePass2Only()

        // Read processedTex.
        let processedBuf = try #require(pipeline.latestProcessedBufferForTest)
        let (pr, pg, pb, _) = try sampleCenterPixel(processedBuf)
        // rgba16Float ULP at 0.5 ≈ 2^-11 ≈ 4.88e-4. Use 1e-3 tolerance.
        #expect(abs(pr - 0.5) < 1e-3)
        #expect(abs(pg - 0.5) < 1e-3)
        #expect(abs(pb - 0.5) < 1e-3)

        // Brightness +0.2 → exponent = 1 / 1.2 ≈ 0.833. pow(0.5, 0.833) ≈ 0.561.
        var bright = ProcessingParameters.identity
        bright.brightness = 0.2
        pipeline.uniforms.withLock { $0.color = ColorUniform(bright) }
        try await pipeline.encodePass2Only()
        let processedBuf2 = try #require(pipeline.latestProcessedBufferForTest)
        let (br, _, _, _) = try sampleCenterPixel(processedBuf2)
        let expected = Float(pow(0.5, 1.0 / 1.2))
        #expect(abs(br - expected) < 5e-3)
    }

    // MARK: - Test 1b — contrast convention (04:contrast-zero-is-identity)

    /// Locks the `[-1, 1]` / `0.0`-identity contrast convention.
    ///
    /// `contrast = 0` must be identity — NOT grey. (The cam2fd grey-frame bug was a
    /// `0.0` default reaching the old `[0, 2]` / `1.0`-identity shader as
    /// zero-contrast, collapsing every pixel to 0.5.) `-1` is fully flat grey
    /// (0.5); `+1` is 2× around the 0.5 midpoint. Input is 0.75 (off the 0.5
    /// pivot) so contrast actually moves the value.
    @Test func contrastConventionIdentityAtZero() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 64, height: 64)
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        let (nBuf, nTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.naturalPoolForTest, width: size.width, height: size.height)
        try fillBufferUniform(nBuf, r: 0.75, g: 0.75, b: 0.75, a: 1.0)
        pipeline.setLatestNaturalForTest(buffer: nBuf, texture: nTex)

        let (pBuf, pTex) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
        pipeline.setLatestProcessedForTest(buffer: pBuf, texture: pTex)

        func centerR(contrast: Double) async throws -> Float {
            var params = ProcessingParameters.identity
            params.contrast = contrast
            pipeline.uniforms.withLock { $0.color = ColorUniform(params) }
            try await pipeline.encodePass2Only()
            let buf = try #require(pipeline.latestProcessedBufferForTest)
            return try sampleCenterPixel(buf).0
        }

        // contrast = 0 → identity → input unchanged (0.75), NOT grey (0.5).
        let identity = try await centerR(contrast: 0.0)
        #expect(abs(identity - 0.75) < 1e-3, "contrast=0 must be identity, got \(identity)")

        // contrast = -1 → fully flat grey → 0.5.
        let flat = try await centerR(contrast: -1.0)
        #expect(abs(flat - 0.5) < 1e-3, "contrast=-1 must be flat grey, got \(flat)")

        // contrast = +1 → 2× around 0.5 → (0.75-0.5)*2+0.5 = 1.0.
        let boosted = try await centerR(contrast: 1.0)
        #expect(abs(boosted - 1.0) < 1e-3, "contrast=+1 must be 2x, got \(boosted)")
    }

    // MARK: - Test 2 — 04:processing-params-persistence-roundtrip

    /// save → load returns identical struct; empty store returns nil.
    @Test func processingParamsPersistenceRoundtrip() {
        let suiteName = "CameraKit.Test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(SettingsPersistence.loadProcessing(defaults: defaults) == nil)

        var p = ProcessingParameters.identity
        p.brightness = 0.25
        p.contrast = 0.4
        p.saturation = -0.3
        p.gamma = 1.8
        p.blackR = 0.05
        SettingsPersistence.saveProcessing(p, defaults: defaults)
        let loaded = SettingsPersistence.loadProcessing(defaults: defaults)
        #expect(loaded == p)
    }

    // MARK: - Test 3 — 04:center-patch-trimmed-mean

    /// Inject a uniform fill into processedTex (R=0.4, G=0.6, B=0.2).
    ///
    /// dispatchCenterPatch returns (0.4, 0.6, 0.2) within ULP.
    /// Then inject a gradient + 10% outliers; trimmed mean discards them.
    @Test func centerPatchTrimmedMean() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = Size(width: 256, height: 256)  // > centerPatchSizePx so center fits
        let pipeline = try MetalPipeline(device: device, captureSize: size, gateOpen: true)

        // Dequeue a processed buffer from the pool, fill it, then install it as latest.
        let (pBuf1, pTex1) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)

        // Uniform fill — trimmed mean exactly equals the fill value.
        try fillBufferUniform(pBuf1, r: 0.4, g: 0.6, b: 0.2, a: 1.0)
        pipeline.setLatestProcessedForTest(buffer: pBuf1, texture: pTex1)
        let s1 = try await pipeline.dispatchCenterPatch()
        #expect(abs(s1.r - 0.4) < 1e-3)
        #expect(abs(s1.g - 0.6) < 1e-3)
        #expect(abs(s1.b - 0.2) < 1e-3)

        // Outliers test: 95% of pixels at 0.5, 5% at 1.0. The patch on a
        // 256×256 capture is 16×16 = 256 samples (see scaledCenterPatchSize),
        // trim = Int(256 * centerPatchTrimRatio) = Int(256 * 0.075) = 19
        // discarded from each end. 5% of 256 ≈ 13 outliers — the high-end
        // trim eats all of them and an extra slice of 0.5s, while the
        // low-end trim drops 19 more 0.5s. Mean of the remaining 218
        // samples is exactly 0.5. outlierFraction must stay strictly below
        // centerPatchTrimRatio (with a stride-placement safety margin) or
        // residual outliers leak through and the mean drifts.
        let (pBuf2, pTex2) = try pipeline.texturePoolForTest.dequeuePoolTexture(
            pool: pipeline.processedPoolForTest, width: size.width, height: size.height)
        try fillBufferWithOutliers(pBuf2, base: 0.5, outlier: 1.0, outlierFraction: 0.05)
        pipeline.setLatestProcessedForTest(buffer: pBuf2, texture: pTex2)
        let s2 = try await pipeline.dispatchCenterPatch()
        #expect(abs(s2.r - 0.5) < 1e-3)
        #expect(abs(s2.g - 0.5) < 1e-3)
        #expect(abs(s2.b - 0.5) < 1e-3)
    }

    // MARK: - Test 4 — 04:set-crop-region-true-crop

    /// P2a true crop: a pipeline built with a crop region carries the crop
    /// origin in its CropUniform and sizes its output textures to the crop, NOT
    /// the sensor.
    ///
    /// Semantics changed from the Stage-04 black-out masking — the output
    /// resolution IS the crop-region size. Engine-level rects that are
    /// out-of-bounds or odd-coordinate throw `EngineError`.
    @Test func setCropRegionTrueCrop() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sensor = Size(width: 1280, height: 960)

        // Build a cropped pipeline the way CameraEngine.setCropRegion now does.
        let rect = Rect(x: 100, y: 50, width: 800, height: 600)
        let pipeline = try MetalPipeline(
            device: device,
            captureSize: sensor,
            outputSize: Size(width: rect.width, height: rect.height),
            cropOrigin: (rect.x, rect.y),
            gateOpen: true
        )

        // Sensor size is preserved; output size = crop size; origin carried.
        #expect(pipeline.captureSize == sensor)
        #expect(pipeline.outputSize == Size(width: 800, height: 600))
        #expect(pipeline.cropOrigin.x == 100)
        #expect(pipeline.cropOrigin.y == 50)

        // The crop uniform carries the origin (set once at construction).
        let (ox, oy) = pipeline.uniforms.withLock { s in (s.crop.originX, s.crop.originY) }
        #expect(ox == 100)
        #expect(oy == 50)

        // Engine-level out-of-bounds throw — exercise via CameraEngine when
        // session is nil → notOpen path. (Open path requires camera hardware.)
        let engine = CameraEngine(initialPhase: .active)
        let oob = Rect(x: 0, y: 0, width: 99999, height: 99999)
        await #expect(throws: EngineError.self) {
            try await engine.setCropRegion(oob)
        }
    }

    // MARK: - Test 4b — 04:set-crop-region-rejects-odd-coords

    /// P2a: odd crop coordinates are rejected (4:2:0 chroma alignment).
    ///
    /// An odd luma offset/extent would skew the half-resolution chroma plane
    /// sampling. On an unopened engine the call short-circuits on the
    /// `notOpen` guard, so this asserts `EngineError` like the OOB case (an
    /// opened engine maps the same rect to `.settingsConflict`).
    @Test func setCropRegionRejectsOddCoords() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let odd = Rect(x: 1, y: 0, width: 800, height: 600)
        await #expect(throws: EngineError.self) {
            try await engine.setCropRegion(odd)
        }
    }

    // MARK: - Test 4c — 04:default-crop-is-full-frame

    /// A pipeline built without a crop has output = capture (no crop applied).
    @Test func defaultCropIsFullFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sensor = Size(width: 1280, height: 960)
        let pipeline = try MetalPipeline(device: device, captureSize: sensor, gateOpen: true)
        #expect(pipeline.outputSize == sensor)
        #expect(pipeline.cropOrigin.x == 0)
        #expect(pipeline.cropOrigin.y == 0)
    }

    // MARK: - Test 4d — 04:resolution-rebuild-drops-prior-crop

    /// A resolution change drops any active crop (measurements 2026-05-20 §1, P2a).
    ///
    /// `setResolution` rebuilds the pipeline with no `outputSize`/`cropOrigin`,
    /// so the new pipeline defaults to full-frame and `activeCropRect(for:)` —
    /// the single source of truth for the published `StreamConfiguration` — reads
    /// full-frame from it. This pins that structural guarantee at the pipeline
    /// level (the engine-level "StreamConfiguration emits full-frame" path needs
    /// an open session and is covered by HITL, not unit tests).
    @Test func resolutionRebuildDropsPriorCrop() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let sensor = Size(width: 1280, height: 960)

        // 1. A cropped pipeline, built the way setCropRegion builds it.
        let cropped = try MetalPipeline(
            device: device,
            captureSize: sensor,
            outputSize: Size(width: 800, height: 600),
            cropOrigin: (100, 50),
            gateOpen: true)
        #expect(cropped.outputSize == Size(width: 800, height: 600))

        // 2. Rebuilt the way setResolution builds it — no crop args → full frame.
        let rebuilt = try MetalPipeline(device: device, captureSize: sensor, gateOpen: true)
        #expect(rebuilt.outputSize == sensor)
        #expect(rebuilt.cropOrigin.x == 0)
        #expect(rebuilt.cropOrigin.y == 0)
    }

    // MARK: - Helpers

    /// Writes a uniform `base` fill, then overwrites a fraction of pixels
    /// with `outlier` value (used to verify trimmed-mean discard).
    private func fillBufferWithOutliers(
        _ buffer: CVPixelBuffer,
        base: Float, outlier: Float,
        outlierFraction: Double
    ) throws {
        try fillBufferUniform(buffer, r: base, g: base, b: base, a: 1.0)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base0 = CVPixelBufferGetBaseAddress(buffer) else { return }
        let outlierPx = packHalfRGBA(r: outlier, g: outlier, b: outlier, a: 1.0)
        let total = width * height
        let outlierCount = Int(Double(total) * outlierFraction)
        // Sprinkle outliers uniformly across the image — every Nth pixel.
        let stride = max(1, total / max(outlierCount, 1))
        var writes = 0
        for i in Swift.stride(from: 0, to: total, by: stride) where writes < outlierCount {
            let y = i / width
            let x = i % width
            let row = base0.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            row[x * 4 + 0] = outlierPx.r
            row[x * 4 + 1] = outlierPx.g
            row[x * 4 + 2] = outlierPx.b
            row[x * 4 + 3] = outlierPx.a
            writes += 1
        }
    }

    /// Reads the (R, G, B, A) at the center pixel of an RGBA16F IOSurface buffer.
    private func sampleCenterPixel(_ buffer: CVPixelBuffer) throws -> (Float, Float, Float, Float) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw MetalError.unsupportedFormat
        }
        let cx = width / 2
        let cy = height / 2
        let row = base.advanced(by: cy * bytesPerRow)
            .assumingMemoryBound(to: UInt16.self)
        return (
            unpackHalf(row[cx * 4 + 0]),
            unpackHalf(row[cx * 4 + 1]),
            unpackHalf(row[cx * 4 + 2]),
            unpackHalf(row[cx * 4 + 3])
        )
    }

    // MARK: - Float16 packing helpers

    private func unpackHalf(_ bits: UInt16) -> Float {
        Float(Float16(bitPattern: bits))
    }
}
