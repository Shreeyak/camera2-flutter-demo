import CoreVideo
import Foundation

@testable import CameraKit

/// Float16 RGBA pixel for IOSurface-backed `kCVPixelFormatType_64RGBAHalf` writes.
struct HalfPixel { let r, g, b, a: UInt16 }

/// Packs four normalized floats into half-float bit patterns suitable for direct
/// CVPixelBuffer writes when the buffer is `kCVPixelFormatType_64RGBAHalf`.
func packHalfRGBA(r: Float, g: Float, b: Float, a: Float) -> HalfPixel {
    HalfPixel(
        r: Float16(r).bitPattern,
        g: Float16(g).bitPattern,
        b: Float16(b).bitPattern,
        a: Float16(a).bitPattern)
}

/// Writes a uniform RGBA half-float fill into an IOSurface-backed CVPixelBuffer
/// of pixel format `kCVPixelFormatType_64RGBAHalf`.
///
/// Throws `MetalError.unsupportedFormat` if the buffer base address cannot be
/// locked.
func fillBufferUniform(
    _ buffer: CVPixelBuffer,
    r: Float, g: Float, b: Float, a: Float
) throws {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        throw MetalError.unsupportedFormat
    }
    let pixel = packHalfRGBA(r: r, g: g, b: b, a: a)
    for y in 0..<height {
        let row = base.advanced(by: y * bytesPerRow)
            .assumingMemoryBound(to: UInt16.self)
        for x in 0..<width {
            row[x * 4 + 0] = pixel.r
            row[x * 4 + 1] = pixel.g
            row[x * 4 + 2] = pixel.b
            row[x * 4 + 3] = pixel.a
        }
    }
}
