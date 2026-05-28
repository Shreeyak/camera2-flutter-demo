import Atomics

// Test-only seams for `CameraEngine`, kept in one DEBUG-gated extension so the
// scaffolding never ships in Release. Same-module extension: reaches the engine's
// `internal` members (and `clock` / `assetWriterFactory`, relaxed from `private`
// to `internal` for this file). Consumed by CameraKitTests via `@testable import`.
#if DEBUG
extension CameraEngine {
    /// Test-only: emit an arbitrary CameraError without driving the recovery machine.
    func _emitErrorForTest(_ err: CameraError) {
        publishError(err)
    }

    /// Test-only: drive the state machine into `.streaming` so teardown paths
    /// (`close()` and the `.cameraInUseEnded` self-heal) can be exercised
    /// without real hardware.
    ///
    /// Pokes `SessionStateMachine` directly via `_setCurrentForTest` (bypasses
    /// classification — matches the prior `isOpen = true` intent of skipping
    /// the normal `.opening`/`.streaming` path). No emission on the state
    /// stream — preserves the original `isOpen = true` semantics where the
    /// seam mutated state without publishing. Tests that need a published
    /// `.streaming` should call `engine.open()` or subscribe before posting
    /// events that advance state. `cameraSession`, `metalPipeline`, etc.
    /// stay nil — `close()` is nil-safe for all of them, so the path runs
    /// cleanly and reaches `publishState(.closed)`. Reproduces the realistic
    /// D-14 precondition: a `.cameraInUse` interruption only ever reaches a
    /// running session, i.e. an already-open engine.
    func _markOpenForTest() {
        stateMachine._setCurrentForTest(.streaming)
        // Seed the phase-derived hardware mirror the way open()-then-reconcile
        // would leave it for `currentPhase`, so phase-dependent tests (cheap
        // pause, F4) start from a faithful post-open state without real hardware
        // (`cameraSession` stays nil). Task 5 as-built.
        reconciledSessionRunning = (currentPhase != .background)
        setGate(currentPhase == .active)
        // open() requires camera permission, so a successfully-opened engine has
        // it. Mirror that: otherwise the `.active` reconcile's mid-session-
        // revocation guard reads the live AVFoundation check, whose result depends
        // on the test host's real permission state on the device — making these
        // pure state-machine tests pass/fail per-device. The revocation test
        // overrides this with `_setPermissionStatusForTest(.denied)` afterwards.
        permissionStatusProvider = { .authorized }
    }

    /// Test-only: read the state machine's current `SessionState` (stateStream only yields on publish).
    var _currentStateForTest: SessionState { stateMachine.current }

    /// Test-only: read the engine's current lifecycle phase.
    var _currentPhaseForTest: AppLifecyclePhase { currentPhase }

    /// Test-only: drive the state machine to an arbitrary `SessionState` without emission.
    ///
    /// Mirrors `_markOpenForTest`'s direct poke. The only way to observe the
    /// `.opening` origin — no engine command publishes `.opening` (`open()`
    /// jumps `.closed → .streaming`), so the `shouldDeferCommandLabel`
    /// `.opening → .paused` rider is otherwise untestable at the engine level.
    func _setStateForTest(_ state: SessionState) { stateMachine._setCurrentForTest(state) }

    /// Test-only: reconcile's last session-running decision.
    ///
    /// Logical mirror, not a hardware probe — see `reconciledSessionRunning`.
    /// `_markOpenForTest` seeds it from `currentPhase`.
    var _isSessionRunningForTest: Bool { reconciledSessionRunning }

    /// Test-only: install the `.background` reconcile seam (idempotent).
    ///
    /// Required before a test reads `_backgroundActionsForTest` after a plain
    /// `.background` transition; the park accessors install it implicitly.
    func _installLifecycleTestHookForTest() {
        if lifecycleTestHook == nil { lifecycleTestHook = LifecycleTestHook() }
    }

    /// Test-only: override the camera-permission probe the `.active` reconcile
    /// reads (drives the mid-session-revocation guard without real Settings).
    func _setPermissionStatusForTest(_ status: CameraPermissionStatus) {
        permissionStatusProvider = { status }
    }

    /// Test-only: ordered trace of the most recent `.background` reconcile.
    var _backgroundActionsForTest: [String] { lifecycleTestHook?.actions ?? [] }

    /// Test-only: arm a one-shot park of the next `.background` reconcile at its
    /// post-disarm checkpoint (latest-intent-wins interleave test).
    ///
    /// Installs the seam if needed. One-shot — call again to re-arm for a second park.
    func _armBackgroundReconcileParkForTest() {
        _installLifecycleTestHookForTest()
        lifecycleTestHook?.parkArmed = true
    }

    /// Test-only: true once the armed `.background` reconcile has parked.
    var _isBackgroundReconcileParkedForTest: Bool { lifecycleTestHook?.parked ?? false }

    /// Test-only: release a parked `.background` reconcile so it resumes (and
    /// aborts if a later phase superseded it).
    func _releaseBackgroundReconcileParkForTest() {
        lifecycleTestHook?.parkRelease?.resume()
        lifecycleTestHook?.parkRelease = nil
    }

    /// Test seam — swap the writer factory before startRecording().
    func _setAssetWriterFactoryForTest(_ f: @escaping AssetWriterFactory) {
        assetWriterFactory = f
    }

    /// Test-only: inject a session event directly (avoids needing avSession reference).
    func _postSessionEventForTest(_ event: CameraSession.SessionEvent) async {
        await onSessionEvent(event)
    }

    /// Test-only: armed token of the capture stall watchdog (nil when disarmed).
    ///
    /// Lets a test observe disarm-on-interruption / re-arm-on-resume directly.
    var _captureWatchdogArmedTokenForTest: UInt64? { watchdogs?.capture.armedSessionToken }

    /// Test-only: build and arm the stall watchdogs + recovery coordinator the
    /// way `open()` does, without a real `AVCaptureSession`.
    ///
    /// Exercises the lifecycle disarm/re-arm paths and the watchdog→recovery
    /// wiring under an injected clock. `performTeardownAndReopen` is a no-op —
    /// these tests assert that recovery is NOT spuriously triggered on the
    /// interrupted / background path.
    func _armWatchdogsForTest() {
        let gpu = Watchdog(kind: .gpu, clock: clock) { [weak self] fire in
            Task { [weak self] in await self?.handleWatchdogFire(fire) }
        }
        let cap = Watchdog(kind: .capture, clock: clock) { [weak self] fire in
            Task { [weak self] in await self?.handleWatchdogFire(fire) }
        }
        let pair = WatchdogPair(gpu: gpu, capture: cap)
        self.watchdogs = pair
        self.recovery = RecoveryCoordinator(
            clock: clock,
            hooks: RecoveryCoordinator.Hooks(
                performTeardownAndReopen: {},
                emitStateRecovering: { [weak self] in await self?.publishStateAsync(.recovering) },
                emitError: { [weak self] err in await self?.publishErrorAsync(err) },
                disarmWatchdogs: { [weak self] in await self?.disarmWatchdogsAsync() },
                incrementSessionToken: { [weak self] in
                    self?.sessionToken.wrappingIncrement(ordering: .sequentiallyConsistent)
                }
            )
        )
        armWatchdogs()
    }
}
#endif
