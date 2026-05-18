import Accelerate
import CameraKitInterop
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Orchestrates one-shot still image capture per architecture §D-05 and §D-09.
///
/// At-most-one in-flight capture enforced by a `CppCaptureAtomic` guard (ADR-13 / Invariant 7).
final class StillCapture: @unchecked Sendable {
    // C++ std::atomic<bool> per ADR-13 / Invariant 7 (CaptureAtomic.hpp, Stage 08).
    private let captureInFlight: CppCaptureAtomic = CppCaptureAtomic()

    init() {}

    /// Captures the next GPU-processed frame as an 8-bit TIFF.
    ///
    /// Caller (CameraEngine) is responsible for dispatching the resulting file
    /// through `PhotosLibraryClient.publish` per the requested
    /// `PhotosDestination`; this method only writes the file to disk.
    ///
    /// - Parameters:
    ///   - pipeline: The live MetalPipeline to arm for Pass 6.
    ///   - captureSize: Width × height of the processed frame (to allocate vImage buffers).
    ///   - deviceSnapshot: Current DeviceStateSnapshot for EXIF metadata (ISO, exposure, WB, focus).
    ///   - focalLengthMm: Focal length in mm from the active AVCaptureDevice format.
    ///   - apertureValue: APEX aperture value from the active format.
    ///   - outputURL: Resolved per `PhotosLibraryClient.resolve` (default ext `tif`).
    func captureImage(
        pipeline: MetalPipeline,
        captureSize: Size,
        deviceSnapshot: DeviceStateSnapshot?,
        focalLengthMm: Double,
        apertureValue: Double,
        outputURL: URL?
    ) async throws -> StillCaptureOutput {
        CameraKitLog.notice(.engine, "[still] capture start size=\(captureSize.width)x\(captureSize.height)")
        // 1. CAS guard — wins exclusivity before arming pipeline (prevents race on continuation).
        guard captureInFlight.tryAcquire() else {
            CameraKitLog.warning(.engine, "[still] already in-flight, rejecting")
            throw StillCaptureError.alreadyInFlight
        }
        defer { captureInFlight.release() }

        // 2. Resolve the on-disk write URL up-front; throws on sandbox escape.
        let writeURL = try PhotosLibraryClient.resolve(outputURL: outputURL, defaultExt: "tif")

        // 3. Arm pipeline continuation — the next encode() will perform Pass 6.
        let readbackBuffer: CVPixelBuffer = try await withCheckedThrowingContinuation { continuation in
            pipeline.armCapture(continuation: continuation)
        }

        // 4. Hand off to the shared encode path — vImage convert, build CGImage,
        //    EXIF, write to disk. Marked `"lane": "processed"` so consumers can
        //    distinguish from `captureNaturalPicture` output.
        let output = try await encode(
            buffer: readbackBuffer,
            captureSize: captureSize,
            deviceSnapshot: deviceSnapshot,
            focalLengthMm: focalLengthMm,
            apertureValue: apertureValue,
            outputURL: writeURL,
            format: .tiff,
            laneTag: "processed"
        )

        CameraKitLog.notice(.engine, "[still] capture complete path=\(output.filePath)")
        return output
    }

    // MARK: - Private helpers

    private func convertRGBA16FtoRGBA8(
        buffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(buffer) else {
            throw StillCaptureError.metalReadbackFailed
        }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(buffer)

        // Source format: RGBA 16-bit half-float, little-endian (MTKView / Metal default).
        var srcFormat = vImage_CGImageFormat(
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(
                rawValue:
                    CGBitmapInfo.byteOrder16Little.rawValue | CGBitmapInfo.floatComponents.rawValue
                    | CGImageAlphaInfo.last.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        // Destination format: RGBA 8-bit, no alpha.
        var dstFormat = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: nil,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        var convErr: vImage_Error = kvImageNoError
        guard
            let converterUnmanaged = vImageConverter_CreateWithCGImageFormat(
                &srcFormat, &dstFormat, nil, vImage_Flags(kvImageNoFlags), &convErr
            )
        else {
            throw StillCaptureError.metalReadbackFailed
        }
        let converter = converterUnmanaged.takeRetainedValue()

        var srcBuf = vImage_Buffer(
            data: baseAddr,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: srcRowBytes
        )

        let dstRowBytes = width * 4
        var rgbaBytes = [UInt8](repeating: 0, count: width * height * 4)
        let err = rgbaBytes.withUnsafeMutableBytes { ptr -> vImage_Error in
            var dstBuf = vImage_Buffer(
                data: ptr.baseAddress!,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: dstRowBytes
            )
            return vImageConvert_AnyToAny(converter, &srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))
        }
        guard err == kvImageNoError else {
            throw StillCaptureError.metalReadbackFailed
        }
        return rgbaBytes
    }

    private func makeCGImage(rgbaBytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        let bitsPerComponent = 8
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(rgbaBytes) as CFData) else {
            throw StillCaptureError.metalReadbackFailed
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            throw StillCaptureError.metalReadbackFailed
        }
        return image
    }

    private func buildCamPluginV1Json(
        deviceSnapshot: DeviceStateSnapshot?,
        laneTag: String?
    ) -> String {
        var fields: [String: Any] = [:]
        if let laneTag {
            fields["lane"] = laneTag
        }
        if let snap = deviceSnapshot {
            fields["iso"] = snap.iso
            fields["exposureDurationNs"] = snap.exposureDurationNs
            fields["wbGainR"] = snap.whiteBalanceGains.red
            fields["wbGainG"] = snap.whiteBalanceGains.green
            fields["wbGainB"] = snap.whiteBalanceGains.blue
            fields["lensPosition"] = snap.lensPosition
        }
        let envelope: [String: Any] = ["CamPlugin/v1": fields]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
            let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    private func buildImageProperties(
        cgImage: CGImage,
        deviceSnapshot: DeviceStateSnapshot?,
        focalLengthMm: Double,
        apertureValue: Double,
        captureSize: Size,
        timestamp: String,
        camPluginJson: String
    ) -> [String: Any] {
        var exifDict: [String: Any] = [
            kCGImagePropertyExifUserComment as String: camPluginJson,
            kCGImagePropertyExifDateTimeOriginal as String: timestamp,
            kCGImagePropertyExifFocalLength as String: focalLengthMm,
            kCGImagePropertyExifApertureValue as String: apertureValue,
        ]
        if let snap = deviceSnapshot {
            exifDict[kCGImagePropertyExifISOSpeedRatings as String] = [Int(snap.iso)]
            exifDict[kCGImagePropertyExifExposureTime as String] =
                Double(snap.exposureDurationNs) / 1_000_000_000.0
            exifDict[kCGImagePropertyExifSubjectDistance as String] = snap.lensPosition
            exifDict[kCGImagePropertyExifExposureProgram as String] = 1
        }
        let tiffDict: [String: Any] = [
            kCGImagePropertyTIFFOrientation as String: 1,
            kCGImagePropertyTIFFDateTime as String: timestamp,
        ]
        return [
            kCGImagePropertyExifDictionary as String: exifDict,
            kCGImagePropertyTIFFDictionary as String: tiffDict,
        ]
    }

    private func writeImage(
        cgImage: CGImage,
        metadata: [String: Any],
        format: UTType,
        to url: URL
    ) throws {
        guard
            let dest = CGImageDestinationCreateWithURL(
                url as CFURL, format.identifier as CFString, 1, nil
            )
        else {
            throw StillCaptureError.fileWriteFailed("CGImageDestinationCreateWithURL failed: \(url.path)")
        }
        CGImageDestinationAddImage(dest, cgImage, metadata as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw StillCaptureError.fileWriteFailed("CGImageDestinationFinalize failed: \(url.path)")
        }
    }

    // MARK: - Shared encode path

    /// Encodes a CPU-readable RGBA16F `CVPixelBuffer` to disk in the requested format.
    ///
    /// Used by `captureImage` (after a Pass-6 GPU readback) and by
    /// `CameraEngine.captureNaturalPicture` (latest Pass-1 buffer from the natural-lane
    /// `Mailbox<CVPixelBuffer>`). Also the seam used by unit tests that skip the
    /// pipeline-arm continuation.
    ///
    /// - Parameter format: `.tiff` for processed-lane stills, `.jpeg` for natural-lane.
    /// - Parameter laneTag: `"processed"` / `"natural"` / `nil`. When non-nil, written
    ///   into the `CamPlugin/v1` EXIF envelope under the `"lane"` key so consumers can
    ///   distinguish the two capture paths post-hoc.
    func encode(
        buffer: CVPixelBuffer,
        captureSize: Size,
        deviceSnapshot: DeviceStateSnapshot?,
        focalLengthMm: Double,
        apertureValue: Double,
        outputURL: URL,
        format: UTType,
        laneTag: String?
    ) async throws -> StillCaptureOutput {
        let rgbaBytes = try convertRGBA16FtoRGBA8(
            buffer: buffer, width: captureSize.width, height: captureSize.height)
        let cgImage = try makeCGImage(
            rgbaBytes: rgbaBytes, width: captureSize.width, height: captureSize.height)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let camPluginJson = buildCamPluginV1Json(deviceSnapshot: deviceSnapshot, laneTag: laneTag)
        let metadata = buildImageProperties(
            cgImage: cgImage,
            deviceSnapshot: deviceSnapshot,
            focalLengthMm: focalLengthMm,
            apertureValue: apertureValue,
            captureSize: captureSize,
            timestamp: timestamp,
            camPluginJson: camPluginJson
        )
        try writeImage(cgImage: cgImage, metadata: metadata, format: format, to: outputURL)
        return StillCaptureOutput(filePath: outputURL.path)
    }
}
