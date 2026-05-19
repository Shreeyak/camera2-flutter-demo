import CameraKit
import CoreVideo
import Flutter
import Foundation

/// `FlutterTexture` adapter for one CameraKit stream lane.
///
/// On every `copyPixelBuffer()` call, asks the engine for the latest pixel
/// buffer on `stream` and hands it back to Flutter with a +1 retain. Spec §4:
/// "simple pull" — no mitigations, no buffering inside the texture. Whatever
/// the engine has cached at the moment Flutter pulls is what we return.
///
/// ## Threading
///
/// `copyPixelBuffer()` is an `@objc` synchronous protocol method invoked by
/// Flutter on its GPU thread. `CameraEngine.currentPixelBuffer(stream:)` is
/// `nonisolated` and synchronous precisely so this hot path doesn't suspend
/// (CameraEngine.swift line 783-784).
///
/// ## Lifetime
///
/// Holds a `weak` reference to the engine so closing the engine doesn't keep
/// this adapter alive past its registration in `FlutterTextureRegistry`.
/// Closing the engine before `CameraLaneBridge.stop()` unregisters the texture
/// causes `copyPixelBuffer()` to return nil — Flutter handles that gracefully.
final class CameraLaneTexture: NSObject, FlutterTexture {

    // MARK: - Stored properties

    private weak var engine: CameraEngine?
    private let stream: StreamId

    // MARK: - Initialization

    init(engine: CameraEngine, stream: StreamId) {
        self.engine = engine
        self.stream = stream
        super.init()
    }

    // MARK: - FlutterTexture

    /// Returns the engine's latest pixel buffer for `stream`, retained for
    /// Flutter's consumption.
    ///
    /// `Unmanaged.passRetained` produces +1 retain on a Core Foundation object.
    /// The `FlutterTexture` contract says Flutter will `CFRelease` the returned
    /// pointer once the GPU is done with it — net effect is zero on the
    /// buffer's other references (the engine's `latest` cache stays valid).
    /// `passUnretained` would over-release the underlying IOSurface and crash.
    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let engine else { return nil }
        guard let buffer = engine.currentPixelBuffer(stream: stream) else {
            return nil
        }
        return Unmanaged.passRetained(buffer)
    }
}
