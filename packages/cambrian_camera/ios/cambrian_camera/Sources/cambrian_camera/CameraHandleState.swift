import CameraKit
import Flutter
import Foundation

/// Mutable per-handle state for one open `CameraEngine` session.
///
/// Lives in a `[Int64: CameraHandleState]` map inside `CameraHostApiImpl`,
/// keyed by the same `Int64` handle that `HandleRegistry` uses. Holds the
/// pump, the texture bridge, the cached capabilities, and the texture ID
/// so every Pigeon method that needs them can look them up O(1).
///
/// Access is serialized by `CameraHostApiImpl`'s `statesLock`; this type
/// itself is not Sendable and must not be shared across concurrent contexts
/// without that external locking.
final class CameraHandleState {

    // MARK: - Stored properties

    /// The underlying CameraKit engine for this handle.
    let engine: CameraEngine

    /// Snapshot of capabilities returned by `engine.open(configuration:)`.
    /// Cached so subsequent `getCapabilities` calls don't re-query the device.
    let capabilities: SessionCapabilities

    /// Flutter texture ID for the processed (preview) lane.
    let previewTextureId: Int64

    /// Per-handle pump forwarding engine streams to `CameraFlutterApi`.
    let pump: FlutterApiPump

    /// Texture bridge for the processed lane.
    let processedBridge: CameraLaneBridge

    // MARK: - Initialization

    init(
        engine: CameraEngine,
        capabilities: SessionCapabilities,
        previewTextureId: Int64,
        pump: FlutterApiPump,
        processedBridge: CameraLaneBridge
    ) {
        self.engine = engine
        self.capabilities = capabilities
        self.previewTextureId = previewTextureId
        self.pump = pump
        self.processedBridge = processedBridge
    }

    // MARK: - Teardown

    /// Tears down the pump and the bridge. Must be called BEFORE
    /// `engine.close()` so no more Flutter callbacks fire while the engine is
    /// tearing down.
    ///
    /// Order matters: stop the pump first (no more `flutterApi.*` dispatches),
    /// then stop the bridge (which also unregisters the texture from
    /// `FlutterTextureRegistry`).
    func stopBridgesAndPump() async {
        pump.stop()
        await processedBridge.stop()
    }
}
