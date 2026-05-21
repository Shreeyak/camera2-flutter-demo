import CameraKit
import Foundation
import UIKit

/// Bridges UIScene lifecycle transitions onto every `CameraEngine` in the
/// plugin's `HandleRegistry`, replicating the engine's full scene-phase
/// teardown/restore contract.
///
/// SwiftUI's `scenePhase` is not visible to a Flutter plugin, so we subscribe
/// to the equivalent UIKit notifications on `NotificationCenter.default` and
/// reproduce the gold-standard SwiftUI host sequence (eva-swift-stitch
/// `ViewModel.handleScenePhase`, the `.inactive`/`.background`/`.active`
/// switch). The earlier observer called only `notifyScenePhasePaused`, which
/// per its engine doc (`CameraEngine.notifyScenePhasePaused`) ONLY mirrors
/// `SessionState` — it does no gating, draining, or session teardown. That
/// left the `AVCaptureSession` running on background; iOS then interrupted it
/// and the engine's stall-watchdog race produced an off-map FSM transition
/// that `assertionFailure`d on debug builds. Stopping the session ourselves on
/// background removes that interrupt entirely.
///
/// ## Notification → engine-action mapping
///
/// - `UIScene.willDeactivateNotification` (resign-active, == SwiftUI
///   `.inactive`): `setGate(false)` → `drainSubmittedFrame()` →
///   `notifyScenePhasePaused(true)`. Closes the GPU submission gate and
///   flushes the in-flight frame before the app loses the foreground.
/// - `UIScene.didEnterBackgroundNotification` (== SwiftUI `.background`):
///   `backgroundSuspend()` (gate-close + drain + `stopRunning`) →
///   `notifyScenePhasePaused(true)`. Latches `cameFromBackground` so the
///   matching foreground transition knows to restart the session.
/// - `UIScene.didActivateNotification` (== SwiftUI `.active`):
///   `backgroundResume()` (only if `cameFromBackground`) → `setGate(true)` →
///   `notifyScenePhasePaused(false)`.
///
/// We key the restore step on `didActivate`, NOT `willEnterForeground`,
/// because a Control Center / Notification Center pull-down (or app-switcher
/// peek) makes the scene `inactive` WITHOUT backgrounding it: in that case no
/// foreground/background notifications fire, only `willDeactivate` then
/// `didActivate`. Keying restore on `didActivate` reopens the gate after both
/// a transient peek and a real background return — exactly mirroring SwiftUI's
/// `.active`, which fires in both cases. Keying on `willEnterForeground` would
/// leave the gate closed forever after a Control Center peek.
///
/// `cameFromBackground` gates the (cost-bearing) session restart so a transient
/// peek does not pay for a full `backgroundResume` — `backgroundSuspend` only
/// ran on a real `didEnterBackground`, so only then is a restart needed.
///
/// AVCaptureSession interruption observation is handled inside `CameraEngine`
/// itself — this observer is strictly about the scene-phase lifecycle signal.
///
/// The observer is plugin-internal — it is NOT exposed across the Pigeon
/// boundary. The Pigeon `pause`/`resume` methods carry different (explicit
/// user) semantics and are wired separately.
///
/// ## Multi-scene apps (iPad split-view)
///
/// We observe with `object: nil`, so we receive one notification per `UIScene`
/// instance that transitions. The engine actions are all idempotent —
/// `setGate`/`notifyScenePhasePaused` are atomic stores / state re-publishes,
/// `drainSubmittedFrame` is a no-op when nothing is in flight, and
/// `backgroundSuspend`/`backgroundResume` stop/start an already-stopped/running
/// session as a no-op — so duplicate per-scene fan-out is harmless. The
/// `cameFromBackground` latch is read-and-cleared on the first `didActivate`,
/// so the session restart fires exactly once per background cycle.
///
/// Notifications fire on the main thread, so the `cameFromBackground`
/// read/write is serialized there; the actor-isolated engine calls hop off via
/// the per-notification `Task`.
///
/// `didActivate` also fires at scene first-activation (cold launch) before any
/// camera is opened — the registry is empty then, so the active branch is a
/// harmless no-op.
final class LifecycleObserver {

    // MARK: - State

    private weak var registry: HandleRegistry?
    private var observers: [NSObjectProtocol] = []

    /// True once `didEnterBackground` has fired and `backgroundSuspend` ran,
    /// until the matching `didActivate` restarts the session. Distinguishes a
    /// real background round-trip (needs `backgroundResume`) from a transient
    /// `inactive` peek (does not). Touched only on the main thread (see class
    /// doc).
    private var cameFromBackground = false

    // MARK: - Initialization

    /// - Parameter registry: stashed weakly so that the observer never extends
    ///   the lifetime of the plugin (which owns the registry). If the plugin
    ///   is torn down while a notification is in flight, the weak load returns
    ///   nil and the handler becomes a no-op.
    init(registry: HandleRegistry) {
        self.registry = registry
        subscribe()
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    // MARK: - Private

    private func subscribe() {
        let center = NotificationCenter.default

        // `object: nil` so we observe every UIScene in the process, not just a
        // specific one. Multi-scene apps (iPad split-view) fire the
        // notification per scene; the engine actions are idempotent so the
        // duplicate fan-out is harmless (see class doc).
        let willDeactivate = center.addObserver(
            forName: UIScene.willDeactivateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleInactive()
        }

        let didBackground = center.addObserver(
            forName: UIScene.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleBackground()
        }

        let didActivate = center.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleActive()
        }

        observers = [willDeactivate, didBackground, didActivate]
    }

    /// SwiftUI `.inactive`: close the gate and flush the in-flight frame, then
    /// mirror `.paused`.
    private func handleInactive() {
        forEachEngine { engine in
            await engine.setGate(false)
            await engine.drainSubmittedFrame()
            await engine.notifyScenePhasePaused(true)
        }
    }

    /// SwiftUI `.background`: fully suspend the capture session, then mirror
    /// `.paused`. Latches `cameFromBackground` for the matching `.active`.
    private func handleBackground() {
        cameFromBackground = true
        forEachEngine { engine in
            await engine.backgroundSuspend()
            await engine.notifyScenePhasePaused(true)
        }
    }

    /// SwiftUI `.active`: restart the session if we returned from background,
    /// re-open the gate, then mirror `.streaming`.
    private func handleActive() {
        let resume = cameFromBackground
        cameFromBackground = false
        forEachEngine { engine in
            if resume {
                await engine.backgroundResume()
            }
            await engine.setGate(true)
            await engine.notifyScenePhasePaused(false)
        }
    }

    /// Runs `body` against every engine currently in the registry, hopping off
    /// the notification thread into a fresh `Task` (both the registry hop and
    /// the per-engine calls are `actor`-isolated and require `await`).
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
