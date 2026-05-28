import AVFoundation
import Atomics

// Extension of `CameraEngine` holding the App-lifecycle reconciliation cluster —
// the *host-intent* side of lifecycle: `setLifecyclePhase(_:)` and the
// `reconcile()` routine that actuates the gate, session, watchdogs, and
// `SessionState` label from `currentPhase`.
//
// The *OS-event* side (`onSessionEvent`, `RecoveryCoordinator`, watchdog
// handling) deliberately stays in `CameraEngine.swift`; it calls `reconcile()`
// across the file boundary, which is why `reconcile` is `internal` here while the
// helpers it owns stay `private` to this file. This is the repo's first
// `Type+Feature.swift` split — extracted purely for file size; every member
// remains actor-isolated on `CameraEngine`, so behaviour is unchanged.
//
// Refs: ADR-09 (gate guards GPU commit), ADR-30 (async-with-timeout — see
// `Recording.swift` finalize), spec *OS-authoritative label*, adversarial F1
// (latest-intent-wins) and F2 (the OS-owned guard).
extension CameraEngine {

    // MARK: - App lifecycle (reconciliation)

    /// Update the host's current lifecycle phase.
    ///
    /// Never throws; safe on every transition and before `open()`. Writes
    /// `currentPhase` unconditionally and reconciles hardware (gate, session,
    /// watchdogs, label) only when the engine is open — before `open()` the phase
    /// is recorded, and `open()` applies it by running the same routine against
    /// `currentPhase`.
    ///
    /// Concurrency: the **latest call wins** — a superseded, still-in-flight
    /// reconciliation is abandoned rather than allowed to apply stale work, so
    /// rapid bounces (lock/unlock, app-switch) are safe.
    ///
    /// Calling convention:
    /// - **SwiftUI:** observe `@Environment(\.scenePhase)` and forward the
    ///   matching case — `.active` / `.inactive` / `.background` map 1:1.
    /// - **Flutter (cam2fd):** the plugin's *native* Swift layer implements
    ///   `FlutterSceneLifeCycleDelegate` (registered via `addSceneDelegate`) and
    ///   maps the UIScene callbacks to this call — `sceneDidBecomeActive →
    ///   .active`, `sceneWillResignActive → .inactive`, `sceneDidEnterBackground →
    ///   .background`. Do **not** forward lifecycle from Dart over the method
    ///   channel: observe natively so a backgrounding can't outrun an in-flight
    ///   recording's finalize and corrupt the `.mp4`.
    public func setLifecyclePhase(_ phase: AppLifecyclePhase) async {
        currentPhase = phase
        guard isOpen else { return }
        await reconcile()
    }

    /// Reconcile actual hardware state to the target `currentPhase` implies.
    ///
    /// The single routine behind the three lifecycle actuation sites:
    /// `setLifecyclePhase`, `open()`, and the OS-recovery exit
    /// (`onSessionEvent(.otherInterruptionEnded)`). Derives the target from
    /// `currentPhase` alone — no previous-phase
    /// tracking — per the design's target table: `.active` → gate open / session
    /// running / watchdogs armed; `.inactive` → gate closed / session running /
    /// disarmed (cheap pause, ~4 ms gate-flip vs ~410 ms restart); `.background`
    /// → gate closed / session stopped + recording finalized / disarmed.
    ///
    /// Also publishes the `SessionState` label (the OS-authoritative label
    /// publish, formerly a standalone scenePhase mirror) and applies the phase→OS
    /// guard (F2): while `osOwnsDevice` the `.active`/`.inactive` rows neither
    /// `startRunning` nor re-arm the watchdogs.
    func reconcile() async {
        // Latest-intent-wins (F1): each entry bumps the generation so a later
        // call supersedes an in-flight one. The `.background` path re-checks
        // `generation` after each suspending step and aborts if a newer call
        // bumped it.
        reconcileGeneration &+= 1
        let generation = reconcileGeneration

        // Mid-session permission revocation: a `.background → .active` resume after
        // camera permission was revoked in Settings (backgrounding stopped the
        // session, so the app survived the revocation that would otherwise kill a
        // process holding a live session). Don't restart a session whose input is
        // now unauthorized — surface `.permissionDenied` on the error stream
        // (matching `open()`'s `cameraDenied` precedent) and leave the state as-is
        // (`.paused` from the prior `.background`); the `.streaming` label below is
        // skipped by returning early. Other phases need no guard (gate stays closed,
        // nothing to start). Route revocation is N/A — CameraKit captures no audio.
        if currentPhase == .active, permissionStatusProvider() != .authorized {
            CameraKitLog.error(
                .engine,
                "[lifecycle] .active reconcile blocked — camera permission not authorized "
                    + "(mid-session revocation); emitting .permissionDenied")
            publishError(
                CameraError(
                    code: .permissionDenied,
                    message: "Camera permission was revoked; re-enable it in Settings.",
                    isFatal: false))
            return
        }

        // Label half — the OS-authoritative label publish (spec
        // *OS-authoritative label*): `.active` publishes `.streaming`, every gated
        // phase publishes `.paused`; `publishCommandLabel` defers to OS truth.
        // Published before the (suspending) `.background` steps so latest-intent-
        // wins covers the label too: only `.background` suspends, and it aborts
        // without republishing, so a superseding `.active`'s `.streaming` is the
        // last word.
        publishCommandLabel(currentPhase == .active ? .streaming : .paused)

        switch currentPhase {
        case .active:
            setGate(true)
            CameraKitLog.notice(.engine, "[resume] gate opened (t0b)")
            // Arm the pipeline's one-shot commit/texture probes (t1b/t1c): the first
            // frame past the now-open gate logs its commit and texture-store, which
            // splits AVF delivery-resume (t1) from GPU/commit cost downstream.
            metalPipeline?.logNextCommit = true
            // Resume-latency probe: arm the one-shot first-frame log so
            // `[resume] first frame (t1)` also covers a pure `.inactive → .active`
            // (Control Center, no interruption) resume. t1 minus the `scenePhase:
            // … → active` time (t0) splits "OS throttled delivery while .inactive"
            // (t1 ≈ 500 ms) from a downstream submit/draw delay (t1 ≈ one frame) —
            // ADR-09: the gate gates GPU commit, not delivery, so framesToLog
            // (capture delegate) logs delivery cadence — continuous vs stall.
            captureDelegate?.framesToLog = 1
            // Phase → OS guard (F2; spec *The OS-owned guard*): while the OS owns
            // the device (`.interrupted`/`.recovering`/`.error`) the host command
            // must not fight it — no `startRunning`, no watchdog re-arm. A re-armed
            // watchdog fires a spurious stall → `RecoveryCoordinator` teardown
            // while frames are still OS-stopped (and for the terminal `.error`
            // case escalates toward a fatal `maxRetriesExceeded` the OS would
            // otherwise let self-heal).
            if !osOwnsDevice {
                startSessionIfNeeded()
                armWatchdogs()
            }
        case .inactive:
            setGate(false)
            // F2: same OS-owned guard on the session-start (the `.inactive` row
            // restarts the session unless the OS owns the device).
            if !osOwnsDevice {
                startSessionIfNeeded()
            }
            disarmWatchdogsAsync()
        case .background:
            // Field-guide §5 ordered suspend: gate close (synchronous, before any
            // suspending step) → disarm + cancel retry → finalize any active
            // recording → drain → stopRunning. After each suspending step a
            // latest-intent-wins re-check (F1) aborts a superseded reconcile
            // before it applies stale work — a `.background` straggled by a
            // completing `.active` must not stop the session `.active` just kept
            // running. The pre-checkpoint gate-close + disarm are left unguarded:
            // cheap, idempotent, and overwritten by the winning `.active`.
            // `lifecycleTestHook` records the order for the 5b test (nil in
            // production — finalize-before-stop needs a live recording → Task 13 HITL).
            lifecycleTestHook?.actions.removeAll(keepingCapacity: true)
            setGate(false)
            disarmWatchdogsAsync()
            lifecycleTestHook?.actions.append("disarm")
            await parkBackgroundReconcileIfArmed()
            guard generation == reconcileGeneration else { return }
            await recovery?.cancelPendingRetry()
            guard generation == reconcileGeneration else { return }
            if recording != nil {
                _ = await finalizeActiveRecording()
                lifecycleTestHook?.actions.append("finalize")
                guard generation == reconcileGeneration else { return }
            }
            await drainSubmittedFrame()
            lifecycleTestHook?.actions.append("drain")
            guard generation == reconcileGeneration else { return }
            reconciledSessionRunning = false
            await cameraSession?.stopRunningAsync()
            lifecycleTestHook?.actions.append("stop")
        }
    }

    /// Start the capture session unless `reconcile` already decided it runs.
    ///
    /// Records the decision in `reconciledSessionRunning` *before* dispatching so
    /// the mirror reflects intent (the start itself is fire-and-forget on
    /// sessionQueue, matching `open()`'s original step-9b timing). No-op without
    /// a live `cameraSession` (the test pattern).
    private func startSessionIfNeeded() {
        guard !reconciledSessionRunning else { return }
        reconciledSessionRunning = true
        // Resume-latency instrumentation: this line on a resume means a real
        // session restart was issued (~400 ms `startRunning`); its ABSENCE
        // confirms the cheap path — e.g. a Control Center interruption never stops
        // the session, so no restart is on the resume critical path.
        CameraKitLog.notice(.engine, "[resume] startSessionIfNeeded — issuing startRunning")
        if let session = cameraSession {
            session.sessionQueue.async { session.startRunning() }
        }
    }

    /// True when the OS owns the device: a foreground interruption, an in-flight
    /// recovery, or a terminal error.
    ///
    /// The reconciliation must not fight the OS for the device while this holds
    /// (spec *The OS-owned guard*, adversarial review F2): the `.active`/
    /// `.inactive` rows skip both `startRunning` and the watchdog arm. Reads the
    /// single source of truth — `SessionStateMachine.current` — with no parallel
    /// mirror.
    ///
    /// Ordering invariant (P4): a path that *exits* OS ownership and then runs
    /// `reconcile()` — today only `onSessionEvent(.otherInterruptionEnded)` in
    /// `CameraEngine.swift` — must first publish the OS-authoritative label (e.g.
    /// `.streaming` as a `.event`) so this reads `false` by the time `reconcile`'s
    /// own `publishCommandLabel` runs; otherwise that publish defers and the label
    /// stays stuck at the OS-owned value. Keep that publish-then-reconcile order if
    /// a second OS-exit site is ever added.
    private var osOwnsDevice: Bool {
        switch stateMachine.current {
        case .interrupted, .recovering, .error: return true
        case .opening, .streaming, .paused, .closed: return false
        }
    }

    /// True when a host `.command` label publish must defer to OS truth.
    ///
    /// `osOwnsDevice` plus the `.opening → .paused` launch race (a pre-`open()`
    /// `.inactive`/`.background` phase arriving before `open()` publishes
    /// `.streaming`). The rider is the one off-map edge `osOwnsDevice` alone does
    /// not cover but the prior `classify(...) == .offMap` check did
    /// (`commandMap[.opening]` has no `.paused`); honestly named separately
    /// because the watchdog/start guard must NOT carry it (spec: a single shared
    /// helper would hide the `.opening` clause at the device-guard site).
    private func shouldDeferCommandLabel(target: SessionState) -> Bool {
        osOwnsDevice || (stateMachine.current == .opening && target == .paused)
    }

    /// Publish a host-`.command` `SessionState` label, deferring to OS truth.
    ///
    /// The label half of reconciliation — the OS-authoritative label publish
    /// (spec *OS-authoritative label*, Bug 2): publishes `.streaming`/`.paused`
    /// as a `.command` transition unless `shouldDeferCommandLabel` holds — in
    /// which case the OS event path owns the terminal label
    /// (`onSessionEvent`/recovery) and this publish is skipped (logged), so a UI
    /// command can't overwrite `.interrupted`/`.recovering`/`.error` with a stale
    /// `.paused`/`.streaming`.
    private func publishCommandLabel(_ target: SessionState, function: String = #function) {
        guard !shouldDeferCommandLabel(target: target) else {
            CameraKitLog.notice(
                .engine,
                "[lifecycle] skipping command label from=\(stateMachine.current.rawValue) "
                    + "to=\(target.rawValue) caller=\(function) (deferring to OS-owned state)"
            )
            return
        }
        publishState(target, kind: .command)
    }

    /// Production-flow interleave checkpoint for the `.background` reconcile.
    ///
    /// Inert in production: returns immediately because `lifecycleTestHook` is
    /// only ever installed by DEBUG test seams. When a test has armed a park via
    /// `_armBackgroundReconcileParkForTest()`, this suspends the in-flight
    /// reconcile at the post-disarm checkpoint until the test releases it —
    /// proving a superseding `.background` straggler aborts. Lives in production
    /// flow (not the DEBUG test section) because the suspension must happen
    /// mid-reconcile; only the arm/release/query seams are DEBUG-only.
    private func parkBackgroundReconcileIfArmed() async {
        guard let hook = lifecycleTestHook, hook.parkArmed else { return }
        hook.parkArmed = false
        hook.parked = true
        await withCheckedContinuation { hook.parkRelease = $0 }
        hook.parked = false
    }
}
