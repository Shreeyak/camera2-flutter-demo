// UniformStorage.swift — permanent (Stage 05)
//
// Value type wrapping the host-written shader uniforms (Pass 1 crop + Pass 2 color).
// Owned by MetalPipeline via Mutex<UniformStorage> (Synchronization framework,
// iOS 18+; user-authorized override of D-17 which names OSAllocatedUnfairLock).
// Snapshotted on the delivery queue at the top of encode() — see MetalPipeline.swift.
//
// Hashable so Stage05Tests can use `Set<UniformStorage>` for the allowed-values
// containment check in the stress test.

struct UniformStorage: Sendable, Hashable {
    var color: ColorUniform
    var crop: CropUniform

    static func identity(captureSize: Size) -> UniformStorage {
        UniformStorage(color: .identity, crop: .full(width: captureSize.width, height: captureSize.height))
    }
}
