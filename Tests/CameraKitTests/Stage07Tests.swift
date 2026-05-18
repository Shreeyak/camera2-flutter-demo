import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import CameraKit

@Suite("Stage07Tests — Still Image Capture (TIFF + EXIF)", .progressLogged)
struct Stage07Tests {

    // MARK: - 07:still-capture-in-flight-guard

    @Test("still-capture-in-flight-guard: second concurrent call throws alreadyInFlight")
    func stillCaptureInFlightGuard() async throws {
        let metal = try MetalPipeline(
            device: MTLCreateSystemDefaultDevice()!,
            captureSize: Size(width: 64, height: 48),
            gateOpen: false
        )
        let capture = StillCapture()

        let buf = try makeFp16Buffer(width: 64, height: 48, r: 0.5, g: 0.5, b: 0.5)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tif")

        // T1: starts capture, arms pipeline continuation.
        let t1 = Task<Void, Error> {
            _ = try await capture.captureImage(
                pipeline: metal,
                captureSize: Size(width: 64, height: 48),
                deviceSnapshot: nil,
                focalLengthMm: 0,
                apertureValue: 0,
                outputURL: tmpURL
            )
        }

        // Give T1 time to CAS and arm the pipeline.
        try await Task.sleep(for: .milliseconds(80))

        // T2: must throw alreadyInFlight.
        do {
            _ = try await capture.captureImage(
                pipeline: metal,
                captureSize: Size(width: 64, height: 48),
                deviceSnapshot: nil,
                focalLengthMm: 0,
                apertureValue: 0,
                outputURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".tif")
            )
            Issue.record("Expected alreadyInFlight but no error was thrown")
        } catch StillCaptureError.alreadyInFlight {
            // Expected — pass
        } catch {
            Issue.record("Expected alreadyInFlight, got: \(error)")
        }

        // Deliver a synthetic buffer to T1 so it completes.
        metal.pendingCaptureContinuation?.resume(returning: buf)
        _ = try? await t1.value
    }

    // MARK: - 07:tiff-round-trip-matches-processed-preview

    @Test("tiff-round-trip-matches-processed-preview: known fp16 pixel round-trips within ±1 LSB")
    func tiffRoundTripMatchesProcessedPreview() async throws {
        let size = Size(width: 4, height: 4)
        // Red=1.0, Green=0.0, Blue=0.5
        let buf = try makeFp16Buffer(width: size.width, height: size.height, r: 1.0, g: 0.0, b: 0.5)
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
        #expect(abs(r - 255) <= 1, "Red channel: expected ~255, got \(r)")
        #expect(abs(g - 0) <= 1, "Green channel: expected ~0, got \(g)")
        #expect(abs(b - 127) <= 1, "Blue channel: expected ~127, got \(b)")
    }

    // MARK: - 07:exif-envelope-contains-camplugin-v1

    @Test("exif-envelope-contains-camplugin-v1: UserComment parses as JSON with CamPlugin/v1 key")
    func exifEnvelopeContainsCamPluginV1() async throws {
        let size = Size(width: 2, height: 2)
        let buf = try makeFp16Buffer(width: size.width, height: size.height, r: 0.5, g: 0.5, b: 0.5)
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

    @Test("default-flow-writes-to-documents: outputURL=nil resolves to <Documents>/<timestamp>.tif")
    func defaultFlowWritesToDocuments() async throws {
        let size = Size(width: 2, height: 2)
        let buf = try makeFp16Buffer(width: size.width, height: size.height, r: 0.3, g: 0.4, b: 0.5)
        let metal = try MetalPipeline(
            device: MTLCreateSystemDefaultDevice()!,
            captureSize: size,
            gateOpen: false
        )
        let capture = StillCapture()

        let t = Task<StillCaptureOutput, Error> {
            try await capture.captureImage(
                pipeline: metal,
                captureSize: size,
                deviceSnapshot: nil,
                focalLengthMm: 0,
                apertureValue: 0,
                outputURL: nil
            )
        }
        // Let the task arm the pipeline.
        try await Task.sleep(for: .milliseconds(80))
        // Deliver readback buffer.
        metal.pendingCaptureContinuation?.resume(returning: buf)
        let output = try await t.value

        let docsURL = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        #expect(
            output.filePath.hasPrefix(docsURL.path),
            "Expected path under documents directory, got: \(output.filePath)"
        )
    }

    // MARK: - 07:exif-standard-dictionary-present

    @Test("exif-standard-dictionary-present: EXIF dict contains ISO and exposureTime")
    func exifStandardDictionaryPresent() async throws {
        let size = Size(width: 2, height: 2)
        let buf = try makeFp16Buffer(width: size.width, height: size.height, r: 0.5, g: 0.5, b: 0.5)
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

/// Converts a Float32 to IEEE 754 half-precision (float16).
private func float16(_ v: Float) -> UInt16 {
    var f = v
    var h: UInt16 = 0
    withUnsafeBytes(of: &f) { fp32 in
        let bits = fp32.load(as: UInt32.self)
        let sign = UInt16((bits >> 31) & 1) << 15
        let exp = Int((bits >> 23) & 0xFF) - 127 + 15
        let man = (bits >> 13) & 0x3FF
        if exp <= 0 {
            h = sign
        } else if exp >= 31 {
            h = sign | 0x7C00
        } else {
            h = sign | UInt16(exp << 10) | UInt16(man)
        }
    }
    return h
}
