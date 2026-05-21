import CameraKit
import Flutter
import Foundation
import UIKit

/// Bridges iOS scene-lifecycle transitions onto every `CameraEngine` in the
/// plugin's `HandleRegistry`, forwarding the matching `AppLifecyclePhase` to
/// `CameraEngine.setLifecyclePhase(_:)` — the engine's single declarative
/// lifecycle entry point.
///
/// ## Why native, and why a scene delegate
///
/// CameraKit owns everything *downstream* of the phase (GPU gate, capture
/// session start/stop, stall watchdogs, recording finalize) plus the
/// device-interruption lifecycle; the host owns only *observing its own app
/// lifecycle* and forwarding the phase. For Flutter that observation MUST happen
/// natively: a Dart `didChangeAppLifecycleState` round-trip over the method
/// channel adds latency that can let a backgrounding outrun an in-flight
/// recording's finalize and corrupt the `.mp4` (CameraKit README, "Lifecycle is
/// native-only"). Dart therefore forwards nothing — this observer is the sole
/// driver.
///
/// We receive the transitions through Flutter's `FlutterSceneLifeCycleDelegate`
/// (registered via `FlutterPluginRegistrar.addSceneDelegate`), which the host's
/// `FlutterSceneDelegate` fans out to. Both bundled apps wire a
/// `FlutterSceneDelegate`-based scene delegate and run a single scene
/// (`UIApplicationSupportsMultipleScenes = false`), so Flutter auto-associates
/// the engine with the scene and these callbacks fire with no extra host wiring.
///
/// ## Scene callback → phase mapping (1:1, per the README)
///
/// - `sceneDidBecomeActive`    → `.active`     (gate open, session running, watchdogs armed)
/// - `sceneWillResignActive`   → `.inactive`   (gate closed, session running — cheap ~4 ms pause)
/// - `sceneDidEnterBackground` → `.background` (gate closed, session stopped, recording finalized)
///
/// `setLifecyclePhase` is safe to call on every transition: it never throws and
/// the latest call wins (a superseded, still-in-flight reconcile is abandoned).
/// The engine derives the target from the *current* phase alone — no
/// previous-phase tracking — so the `.background → .inactive → .active` restore
/// the OS emits needs no special-casing here, and there is no
/// `sceneWillEnterForeground` forward: `sceneDidBecomeActive` carries `.active`
/// for both a real foreground return and a transient Control Center peek
/// (which only fires `sceneWillResignActive` then `sceneDidBecomeActive`).
///
/// `sceneDidBecomeActive` also fires at first activation (cold launch) before any
/// camera is opened — the registry is empty then, so the fan-out is a harmless
/// no-op. The engine is constructed with `initialPhase: .background`, so it never
/// turns the camera on before this observer has forwarded a real `.active`.
///
/// AVCaptureSession interruption observation (Control Center, phone call, etc.)
/// is handled entirely inside `CameraEngine` — this observer is strictly about
/// the scene-phase lifecycle signal.
final class LifecycleObserver: NSObject, FlutterSceneLifeCycleDelegate {

    private weak var registry: HandleRegistry?

    /// - Parameter registry: stashed weakly so the observer never extends the
    ///   lifetime of the plugin (which owns the registry). If the plugin is torn
    ///   down while a scene callback is in flight, the weak load returns nil and
    ///   the handler becomes a no-op.
    init(registry: HandleRegistry) {
        self.registry = registry
        super.init()
    }

    /// Snapshot of the app's current lifecycle phase, read from the
    /// most-foreground connected scene.
    ///
    /// Used to seed `CameraEngine(initialPhase:)` at `open()` time. The engine's
    /// `open()` reconciles hardware against its `currentPhase` (CameraKit
    /// `CameraEngine.open` step 9b) — opening into `.background` deliberately
    /// skips `startRunning`. This observer fires only on subsequent UIScene
    /// *transitions*, never at registration, so if the engine were constructed
    /// with a blind `.background` it would open and never start streaming (no
    /// transition follows when the app is already foreground). Reading the
    /// *actual* phase here both fixes that and preserves the privacy guarantee:
    /// a camera opened while not foreground stays gated (the README's reason for
    /// rejecting a blind `.active` default).
    @MainActor
    static func currentPhase() -> AppLifecyclePhase {
        let states = UIApplication.shared.connectedScenes.map(\.activationState)
        if states.contains(.foregroundActive) { return .active }
        if states.contains(.foregroundInactive) { return .inactive }
        return .background
    }

    // MARK: - FlutterSceneLifeCycleDelegate

    func sceneDidBecomeActive(_ scene: UIScene) {
        forEachEngine { await $0.setLifecyclePhase(.active) }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        forEachEngine { await $0.setLifecyclePhase(.inactive) }
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        forEachEngine { await $0.setLifecyclePhase(.background) }
    }

    // MARK: - Private

    /// Runs `body` against every engine currently in the registry, hopping off
    /// the (main-thread) scene callback into a fresh `Task` — both the registry
    /// hop and the per-engine `setLifecyclePhase` are `actor`-isolated and
    /// require `await`.
    private func forEachEngine(_ body: @escaping @Sendable (CameraEngine) async -> Void) {
        Task { [weak registry] in
            guard let registry else { return }
            let engines = await registry.allEngines()
            for engine in engines {
                await body(engine)
            }
        }
    }
}
