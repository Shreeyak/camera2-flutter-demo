import CameraKit
import Foundation
import UIKit

/// Bridges UIScene lifecycle transitions onto every `CameraEngine` in the
/// plugin's `HandleRegistry`.
///
/// SwiftUI's `scenePhase` is not visible to a Flutter plugin, so we subscribe
/// to the equivalent UIKit notifications on `NotificationCenter.default`:
///
/// - `UIScene.didEnterBackgroundNotification` → `notifyScenePhasePaused(true)`
/// - `UIScene.willEnterForegroundNotification` → `notifyScenePhasePaused(false)`
///
/// AVCaptureSession interruption observation is handled inside `CameraEngine`
/// itself — this observer is strictly about the scene-phase lifecycle signal
/// (Control Center, app-switcher peek, multi-scene foreground/background).
///
/// The observer is plugin-internal — it is NOT exposed across the Pigeon
/// boundary. The Pigeon `pause`/`resume` methods carry different (explicit
/// user) semantics and are wired separately.
///
/// ## Multi-scene apps (iPad split-view)
///
/// We observe with `object: nil`, so we receive one notification per `UIScene`
/// instance that backgrounds/foregrounds. `notifyScenePhasePaused` is
/// idempotent at the engine level (it republishes the same `SessionState`),
/// so duplicate calls are safe.
final class LifecycleObserver {

    // MARK: - State

    private weak var registry: HandleRegistry?
    private var observers: [NSObjectProtocol] = []

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

        // `object: nil` so we observe every UIScene in the process, not just
        // a specific one. Multi-scene apps (iPad split-view) will fire the
        // notification per scene; `notifyScenePhasePaused` is idempotent so
        // duplicate fan-out is harmless.
        let didBackground = center.addObserver(
            forName: UIScene.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.fanOut(paused: true)
        }

        let willForeground = center.addObserver(
            forName: UIScene.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.fanOut(paused: false)
        }

        observers = [didBackground, willForeground]
    }

    /// Fans `notifyScenePhasePaused(paused)` out to every engine currently
    /// in the registry. Both the registry hop (`actor`) and the per-engine
    /// call (`actor CameraEngine`) require `await`, so we hop off the
    /// notification queue into a fresh detached `Task`.
    private func fanOut(paused: Bool) {
        Task { [weak registry] in
            guard let registry else { return }
            let engines = await registry.allEngines()
            for engine in engines {
                await engine.notifyScenePhasePaused(paused)
            }
        }
    }
}
