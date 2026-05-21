import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CameraKit

@Suite("Stage07Tests — Still Image Capture (TIFF + EXIF)", .progressLogged)
struct Stage07Tests {

    // MARK: - 07:tiff-round-trip-matches-processed-preview

    /// The byte-order guard for the BGRA8 still path. `StillCapture.encode`
    /// builds the CGImage with `byteOrder32Little | noneSkipFirst` for
    /// `kCVPixelFormatType_32BGRA`; a wrong byte order silently ships a
    /// channel-swapped "valid" file. Distinct R/G/B values catch both a B↔R
    /// swap and a skipFirst↔skipLast confusion. TIFF is lossless ⇒ exact.
    @Test("tiff-round-trip: known BGRA8 pixel round-trips exactly (no channel swap)")
    func tiffRoundTripMatchesProcessedPreview() async throws {
        let size = Size(width: 4, height: 4)
        // R=255, G=64, B=128 — all distinct.
        let buf = try makeBgra8Buffer(width: size.width, height: size.height, r: 255, g: 64, b: 128)
        let capture = StillCapture()
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")
        _ = try await capture.encode(
            buffer: buf,
            captureSize: size,
            deviceSnapshot: nil,
            focalLengthMm: 0,
            apertureValue: 0,
            outputURL: outURL,
            format: .tiff,
            laneTag: nil
        )
        guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            Issue.record("Failed to decode TIFF at \(outURL.path)")
            return
        }
        #expect(cgImage.width == size.width)
        #expect(cgImage.height == size.height)
        guard let dataProvider = cgImage.dataProvider,
            let data = dataProvider.data,
            let bytes = CFDataGetBytePtr(data)
        else {
            Issue.record("No pixel data in decoded TIFF")
            return
        }
        let r = Int(bytes[0])
        let g = Int(bytes[1])
        let b = Int(bytes[2])
        #expect(r == 255, "Red channel: expected 255, got \(r)")
        #expect(g == 64, "Green channel: expected 64, got \(g)")
        #expect(b == 128, "Blue channel: expected 128, got \(b)")
    }

    // MARK: - 07:exif-envelope-contains-camplugin-v1

    @Test("exif-envelope-contains-camplugin-v1: UserComment parses as JSON with CamPlugin/v1 key")
    func exifEnvelopeContainsCamPluginV1() async throws {
        let size = Size(width: 2, height: 2)
        let buf = try makeBgra8Buffer(width: size.width, height: size.height, r: 128, g: 128, b: 128)
        let capture = StillCapture()
        let snap = DeviceStateSnapshot(
            iso: 100,
            exposureDurationNs: 33_333_333,
            lensPosition: 0.5,
            whiteBalanceGains: WhiteBalanceGains(red: 1.5, green: 1.0, blue: 1.8),
            isAdjustingExposure: false,
            systemPressureLevel: .nominal
        )
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")
        _ = try await capture.encode(
            buffer: buf,
            captureSize: size,
            deviceSnapshot: snap,
            focalLengthMm: 4.25,
            apertureValue: 1.8,
            outputURL: outURL,
            format: .tiff,
            laneTag: nil
        )
        guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
            let userComment = exif[kCGImagePropertyExifUserComment as String] as? String
        else {
            Issue.record("Missing EXIF UserComment in TIFF")
            return
        }
        guard let data = userComment.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            Issue.record("UserComment is not valid JSON: \(userComment)")
            return
        }
        #expect(json["CamPlugin/v1"] != nil, "JSON must contain 'CamPlugin/v1' key")
    }

    // MARK: - 07:default-flow-writes-to-documents

    @Test("default-flow-writes-to-documents: resolve(nil, .tif) → <Documents>/<timestamp>.tif")
    func defaultFlowWritesToDocuments() throws {
        // `StillCapture.encode` takes a fully-resolved URL; the engine wrapper
        // (`captureImage`) resolves nil → <Documents>/<ts>.tif via this resolver.
        let url = try PhotosLibraryClient.resolve(outputURL: nil, defaultExt: "tif")
        let docsURL = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        #expect(
            url.path.hasPrefix(docsURL.path),
            "Expected path under documents directory, got: \(url.path)"
        )
        #expect(url.pathExtension == "tif", "Expected .tif extension, got: \(url.pathExtension)")
    }

    // MARK: - 07:exif-standard-dictionary-present

    @Test("exif-standard-dictionary-present: EXIF dict contains ISO and exposureTime")
    func exifStandardDictionaryPresent() async throws {
        let size = Size(width: 2, height: 2)
        let buf = try makeBgra8Buffer(width: size.width, height: size.height, r: 128, g: 128, b: 128)
        let capture = StillCapture()
        let snap = DeviceStateSnapshot(
            iso: 200,
            exposureDurationNs: 10_000_000,
            lensPosition: 0.3,
            whiteBalanceGains: WhiteBalanceGains(red: 1.2, green: 1.0, blue: 1.6),
            isAdjustingExposure: false,
            systemPressureLevel: .nominal
        )
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")
        _ = try await capture.encode(
            buffer: buf,
            captureSize: size,
            deviceSnapshot: snap,
            focalLengthMm: 4.25,
            apertureValue: 1.8,
            outputURL: outURL,
            format: .tiff,
            laneTag: nil
        )
        guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
            let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any]
        else {
            Issue.record("No EXIF dictionary in TIFF")
            return
        }
        let isoList = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any]
        #expect(isoList?.isEmpty == false, "ISOSpeedRatings must be non-empty")
        let expTime = exif[kCGImagePropertyExifExposureTime as String] as? Double
        #expect(expTime != nil && expTime! > 0, "ExposureTime must be positive")
    }
}

// MARK: - Test helpers

/// Creates a CPU-accessible BGRA8 (`kCVPixelFormatType_32BGRA`) CVPixelBuffer
/// filled with the given RGBA values. Memory byte order is `[B, G, R, A]`.
func makeBgra8Buffer(
    width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255
) throws -> CVPixelBuffer {
    var buf: CVPixelBuffer?
    let attrs: [CFString: Any] = [
        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey: width,
        kCVPixelBufferHeightKey: height,
        kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    let s = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height,
        kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buf)
    guard s == kCVReturnSuccess, let buf else {
        throw NSError(domain: "Test", code: Int(s))
    }
    CVPixelBufferLockBaseAddress(buf, [])
    defer { CVPixelBufferUnlockBaseAddress(buf, []) }
    guard let base = CVPixelBufferGetBaseAddress(buf) else {
        throw NSError(domain: "Test", code: -1)
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt8.self, capacity: bytesPerRow)
        for x in 0..<width {
            row[x * 4 + 0] = b
            row[x * 4 + 1] = g
            row[x * 4 + 2] = r
            row[x * 4 + 3] = a
        }
    }
    return buf
}
