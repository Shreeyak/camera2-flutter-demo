import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Orchestrates one-shot still image capture per architecture §D-05 and §D-09.
///
/// Both still paths read the latest delivered BGRA8 lane buffer directly from
/// `MetalPipeline` (`captureImage` → processed lane, `captureNaturalPicture` →
/// natural lane) and encode it to disk — no GPU readback pass, no vImage
/// conversion. The input is already 8-bit BGRA (the single delivery format), so
/// `encode` just locks the IOSurface and builds the CGImage with BGRA byte
/// order.
final class StillCapture: @unchecked Sendable {

    init() {}

    // MARK: - Private helpers

    /// Builds a `CGImage` from a BGRA8 (`kCVPixelFormatType_32BGRA`) buffer.
    ///
    /// The data provider copies the locked bytes (it must outlive the buffer
    /// lock) and preserves the source `bytesPerRow` — IOSurface-backed pools
    /// commonly pad rows past `width * 4`.
    private func makeCGImage(buffer: CVPixelBuffer) throws -> CGImage {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw StillCaptureError.metalReadbackFailed
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData) else {
            throw StillCaptureError.metalReadbackFailed
        }
        // `kCVPixelFormatType_32BGRA` stores bytes `[B, G, R, A]`. Read as a
        // little-endian 32-bit word that is `A<<24 | R<<16 | G<<8 | B`
        // (ARGB-in-register); `noneSkipFirst` drops the leading alpha, leaving
        // RGB. (Was `noneSkipLast` when the input was RGBA8 from vImage.)
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.noneSkipFirst.rawValue)
        guard
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
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

    /// Encodes a CPU-readable BGRA8 `CVPixelBuffer` to disk in the requested format.
    ///
    /// Used by `CameraEngine.captureImage` (latest processed-lane buffer,
    /// `.tiff`) and `CameraEngine.captureNaturalPicture` (latest natural-lane
    /// buffer, `.jpeg`). Both source the same BGRA8 IOSurface delivered to the
    /// preview/bridge — no separate readback or precision-preserving copy.
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
        let cgImage = try makeCGImage(buffer: buffer)
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
