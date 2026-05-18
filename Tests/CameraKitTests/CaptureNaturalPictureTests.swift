import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CameraKit

/// Unit-level coverage for the `captureNaturalPicture` encode + EXIF path.
///
/// The engine-level wiring (`CameraEngine.captureNaturalPicture`) is a thin
/// orchestrator over `MetalPipeline.latestNaturalBuffer` and
/// `StillCapture.encode(...)` — exercised end-to-end via HITL on the iPad
/// (`measurements/capture-natural-picture/<date>/`). These tests pin the
/// pieces the engine relies on: JPEG round-trip through the shared encode
/// path, and the `"lane"` marker in the `CamPlugin/v1` EXIF envelope.
@Suite("CaptureNaturalPictureTests — captureNaturalPicture", .progressLogged)
struct CaptureNaturalPictureTests {

    @Test("encode-natural-jpeg-round-trip: RGBA fp16 round-trips through JPEG within ±8 LSB")
    func encodeNaturalJpegRoundTrip() async throws {
        // 16×16 buffer — small enough to stay fast, large enough that JPEG's
        // 8×8 block quantisation doesn't murder a 4×4 patch's center pixel.
        let size = Size(width: 16, height: 16)
        let buf = try makeFp16Buffer(width: size.width, height: size.height, r: 1.0, g: 0.0, b: 0.5)
        let capture = StillCapture()
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        _ = try await capture.encode(
            buffer: buf,
            captureSize: size,
            deviceSnapshot: nil,
            focalLengthMm: 0,
            apertureValue: 0,
            outputURL: outURL,
            format: .jpeg,
            laneTag: "natural"
        )
        guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            Issue.record("Failed to decode JPEG at \(outURL.path)")
            return
        }
        #expect(cgImage.width == size.width)
        #expect(cgImage.height == size.height)
        guard let dataProvider = cgImage.dataProvider,
            let data = dataProvider.data,
            let bytes = CFDataGetBytePtr(data)
        else {
            Issue.record("No pixel data in decoded JPEG")
            return
        }
        // Read the center pixel — interior of a single-colour fill is the
        // least likely to be perturbed by JPEG block boundaries.
        let bytesPerRow = cgImage.bytesPerRow
        let centerX = size.width / 2
        let centerY = size.height / 2
        let pxOffset = centerY * bytesPerRow + centerX * (cgImage.bitsPerPixel / 8)
        let r = Int(bytes[pxOffset + 0])
        let g = Int(bytes[pxOffset + 1])
        let b = Int(bytes[pxOffset + 2])
        // JPEG default quality + chroma subsampling — ±8 LSB tolerance is
        // generous but stable across iOS versions and device chips.
        #expect(abs(r - 255) <= 8, "Red channel: expected ~255, got \(r)")
        #expect(abs(g - 0) <= 8, "Green channel: expected ~0, got \(g)")
        #expect(abs(b - 127) <= 8, "Blue channel: expected ~127, got \(b)")
    }

    @Test("exif-camplugin-v1-natural-marker: laneTag='natural' lands in JSON envelope")
    func exifCamPluginV1NaturalMarker() async throws {
        let lane = try await encodeAndReadCamPluginV1(laneTag: "natural", format: .jpeg, ext: "jpg")
        #expect(lane == "natural", "Expected lane='natural', got: \(String(describing: lane))")
    }

    @Test("exif-camplugin-v1-processed-marker: laneTag='processed' lands in JSON envelope")
    func exifCamPluginV1ProcessedMarker() async throws {
        // Use TIFF here — exactly matches what the re-threaded `captureImage`
        // production path writes. Locks the back-compat behaviour.
        let lane = try await encodeAndReadCamPluginV1(laneTag: "processed", format: .tiff, ext: "tif")
        #expect(lane == "processed", "Expected lane='processed', got: \(String(describing: lane))")
    }

    @Test("exif-camplugin-v1-nil-omits-lane: laneTag=nil yields no 'lane' key")
    func exifCamPluginV1NilOmitsLane() async throws {
        let lane = try await encodeAndReadCamPluginV1(laneTag: nil, format: .jpeg, ext: "jpg")
        #expect(lane == nil, "Expected no 'lane' key, got: \(String(describing: lane))")
    }

    @Test("default-flow-writes-to-documents-jpg: resolve(nil, .jpg) → <Documents>/<ts>.jpg")
    func defaultFlowWritesToDocumentsJpg() async throws {
        // Mirrors `Stage07Tests.defaultFlowWritesToDocuments` but for the
        // natural-picture extension. We exercise the resolver directly here —
        // `StillCapture.encode` takes a fully-resolved URL, so the resolver
        // call belongs in the engine wrapper. Test it via PhotosLibraryClient.
        let url = try PhotosLibraryClient.resolve(outputURL: nil, defaultExt: "jpg")
        let docsURL = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        #expect(
            url.path.hasPrefix(docsURL.path),
            "Expected path under documents directory, got: \(url.path)"
        )
        #expect(
            url.pathExtension == "jpg",
            "Expected .jpg extension, got: \(url.pathExtension)"
        )
    }

    // MARK: - Helpers

    /// Encode a small fp16 buffer with the given `laneTag` + `format`, decode
    /// the result, and return the `lane` field from the `CamPlugin/v1` EXIF
    /// envelope (or `nil` if the key is absent).
    private func encodeAndReadCamPluginV1(
        laneTag: String?,
        format: UTType,
        ext: String
    ) async throws -> String? {
        let size = Size(width: 4, height: 4)
        let buf = try makeFp16Buffer(width: size.width, height: size.height, r: 0.5, g: 0.5, b: 0.5)
        let snap = DeviceStateSnapshot(
            iso: 100,
            exposureDurationNs: 33_333_333,
            lensPosition: 0.5,
            whiteBalanceGains: WhiteBalanceGains(red: 1.5, green: 1.0, blue: 1.8),
            isAdjustingExposure: false,
            systemPressureLevel: .nominal
        )
        let capture = StillCapture()
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        _ = try await capture.encode(
            buffer: buf,
            captureSize: size,
            deviceSnapshot: snap,
            focalLengthMm: 4.25,
            apertureValue: 1.8,
            outputURL: outURL,
            format: format,
            laneTag: laneTag
        )
        guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
            let userComment = exif[kCGImagePropertyExifUserComment as String] as? String
        else {
            Issue.record("Missing EXIF UserComment in encoded \(format.identifier)")
            return nil
        }
        guard let data = userComment.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let envelope = json["CamPlugin/v1"] as? [String: Any]
        else {
            Issue.record("UserComment did not parse as CamPlugin/v1 envelope: \(userComment)")
            return nil
        }
        return envelope["lane"] as? String
    }
}

// MARK: - Local test helpers (duplicated from Stage07Tests — `private` there)

/// Creates a CPU-accessible RGBA16F CVPixelBuffer filled with given fp16 RGBA values.
private func makeFp16Buffer(
    width: Int, height: Int, r: Float, g: Float, b: Float, a: Float = 1.0
) throws -> CVPixelBuffer {
    var buf: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_64RGBAHalf,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
    ]
    let s = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_64RGBAHalf, attrs as CFDictionary, &buf)
    guard s == kCVReturnSuccess, let buf else {
        throw NSError(domain: "Test", code: Int(s))
    }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    guard let base = CVPixelBufferGetBaseAddress(buf) else {
        throw NSError(domain: "Test", code: -1)
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
    let fp16R = float16(r)
    let fp16G = float16(g)
    let fp16B = float16(b)
    let fp16A = float16(a)
    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt16.self, capacity: width * 4)
        for x in 0..<width {
            row[x * 4 + 0] = fp16R
            row[x * 4 + 1] = fp16G
            row[x * 4 + 2] = fp16B
            row[x * 4 + 3] = fp16A
        }
    }
    return buf
}

/// Converts a Float32 to IEEE 754 half-precision (float16). Subset of
/// Stage07Tests' helper — small positive values only (RGBA fixtures).
private func float16(_ v: Float) -> UInt16 {
    var f = v
    var h: UInt16 = 0
    withUnsafeBytes(of: &f) { fp32 in
        let bits = fp32.load(as: UInt32.self)
        let sign = UInt16((bits >> 31) & 1) << 15
        let exp = Int((bits >> 23) & 0xFF) - 127 + 15
        let mant = UInt16((bits >> 13) & 0x3FF)
        if exp <= 0 {
            h = sign
        } else if exp >= 31 {
            h = sign | (0x1F << 10)
        } else {
            h = sign | UInt16(exp << 10) | mant
        }
    }
    return h
}
