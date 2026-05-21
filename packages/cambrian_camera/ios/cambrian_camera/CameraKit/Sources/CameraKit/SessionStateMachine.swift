import Foundation

/// Authoritative `SessionState` for the engine actor, with an
/// expected-transition classifier.
///
/// # Why not a strict FSM
///
/// `AVCaptureSession` has independent state (`isRunning`, `isInterrupted`,
/// KVO-observable) that the OS mutates asynchronously via
/// `wasInterruptedNotification`, `interruptionEndedNotification`, and
/// `runtimeErrorNotification`. Those are inbound events, not commands.
/// Hard-rejecting off-map transitions could wedge a session on a
/// legitimate-but-rare OS event ordering (e.g. system-pressure
/// interruption followed by a runtime error during the interruption:
/// `.paused → .recovering`, which is rare but legitimate per Apple's
/// model).
///
/// The classifier distinguishes two kinds:
///   - `.command` — host-initiated (open/close/pause/resume) or
///     engine-self-commanded (D-14 self-heal, scenePhase mirror). Strict
///     expected set.
///   - `.event`   — OS-initiated via AVCaptureSession notifications,
///     surfaced by `CameraSession.SessionEvent` and handled in
///     `CameraEngine.onSessionEvent`. Permissive expected set; can arrive
///     from many states.
///
/// Off-map transitions are LOGGED (`CameraKitLog.warning`) with from /
/// to / kind / caller context, then APPLIED — in every build config. The
/// state machine is a diagnostic instrument, not a gate. A `paused →
/// recovering` log entry correlated with a preceding OS notification is the
/// legitimate path; the same entry with no OS event in the preceding window
/// is the watchdog-race bug the retrospective predicted.
///
/// Off-map is deliberately NOT fatal. An earlier design tripped
/// `assertionFailure(...)` on off-map in DEBUG, which aborted on-device
/// DEBUG builds on legitimate-but-rare OS lifecycle races (e.g. an
/// interruption ending while backgrounded) that RELEASE handled gracefully.
/// Because the OS event space is not fully enumerable, crashing on it traded
/// a real diagnostic (the log) for a DEBUG/RELEASE divergence that amplified
/// bugs rather than catching them (measurements 2026-05-20 §1). The log
/// alone carries the signal; genuine state-logic regressions are caught by
/// the classifier tests, not by aborting the running app.
struct SessionStateMachine {

    /// Classification of the trigger for a transition.
    enum Kind: String, Sendable {
        /// Host-initiated, engine-self-commanded (D-14, scenePhase mirror),
        /// or recovery's natural teardown-and-reopen through `.closed`.
        case command
        /// OS-initiated via AVCaptureSession notification. Originates from
        /// `CameraEngine.onSessionEvent` and from the RecoveryCoordinator
        /// hook (which fires in response to `runtimeErrorNotification`).
        case event
    }

    /// Outcome of classifying a `(from, to, kind)` triple.
    enum Classification: String, Sendable, Equatable {
        case expected
        case offMap
    }

    private(set) var current: SessionState = .closed

    /// Pure classifier — no mutation.
    ///
    /// Used internally by `transition` and directly by tests.
    static func classify(
        from: SessionState,
        to: SessionState,
        kind: Kind
    ) -> Classification {
        // Self-transition (re-affirm same state) always expected.
        if from == to { return .expected }
        switch kind {
        case .command:
            return commandMap[from]?.contains(to) == true ? .expected : .offMap
        case .event:
            return eventMap[from]?.contains(to) == true ? .expected : .offMap
        }
    }

    /// Apply a transition.
    ///
    /// Returns the classification so the caller can log off-map cases with
    /// surrounding context. `current` is updated regardless of classification
    /// (observability-first behavior).
    @discardableResult
    mutating func transition(
        to next: SessionState,
        kind: Kind
    ) -> Classification {
        let cls = Self.classify(from: current, to: next, kind: kind)
        current = next
        return cls
    }

    // MARK: - Expected-transition maps

    /// Command-driven transitions — host-initiated, engine-self-commanded,
    /// or recovery's teardown-and-reopen path through `.closed`.
    ///
    /// `closed → opening` is reserved for the case where the engine
    /// emits `.opening` explicitly before `.streaming`. Today the engine
    /// jumps `closed → streaming` directly inside `open()`; both are
    /// listed as expected so the table accommodates the future state
    /// without immediately producing off-map logs.
    ///
    /// `closed → paused` is the pre-`open()` pause edge (D-2P-07). The
    /// declarative model *records* a pre-open `.inactive`/`.background` phase as
    /// `currentPhase` and `open()` applies it, rather than publishing `.paused`
    /// from `.closed` directly (field guide §3a) — so the table keeps this as a
    /// tolerated edge (Phase-3 Pigeon adapter / ErrorPresenter consume pre-open
    /// pauses on `stateStream`), not an actively host-driven transition.
    private static let commandMap: [SessionState: Set<SessionState>] = [
        .closed: [.opening, .streaming, .paused],
        .opening: [.streaming, .closed, .error],
        .streaming: [.paused, .closed],
        .paused: [.streaming, .closed],
        .recovering: [.closed],
        .error: [.closed],
        .interrupted: [.closed],
    ]

    /// Event-driven transitions — OS-initiated via AVCaptureSession notifications.
    ///
    /// The "any → error" pattern is encoded explicitly per-from-state for clarity.
    private static let eventMap: [SessionState: Set<SessionState>] = [
        .opening: [.error, .interrupted],
        .streaming: [.recovering, .error, .paused, .interrupted],
        .paused: [.streaming, .recovering, .error, .interrupted],
        .recovering: [.streaming, .error],
        .interrupted: [.streaming, .error],
        .closed: [.error],
        .error: [],
    ]

    // MARK: - Test seams

    #if DEBUG
    /// Force-set the current state without classification — for tests
    /// that need to enter a specific state to exercise transitions out
    /// of it without running through the full state space first.
    mutating func _setCurrentForTest(_ state: SessionState) {
        current = state
    }
    #endif
}
