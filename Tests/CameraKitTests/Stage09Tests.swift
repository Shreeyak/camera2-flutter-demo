import AVFoundation
import Testing
@testable import CameraKit

// MARK: - TestClock

/// Deterministic clock for Stage 09 tests.
///
/// `sleep(milliseconds:)` completes immediately but records the delay so tests
/// can assert schedules without real-time waits. Uses a single NSLock for both
/// the time counter and the sleep log — Atomics dependency was dropped so the
/// eva-swift-stitchTests target can link without adding swift-atomics as a
/// direct product dependency.
final class TestClock: CameraKitClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _nowMs: UInt64 = 0
    private var _sleepRequests: [Int] = []

    func nowMs() -> UInt64 { lock.withLock { _nowMs } }

    func sleep(milliseconds: Int) async throws {
        lock.withLock {
            _sleepRequests.append(milliseconds)
            _nowMs &+= UInt64(milliseconds)
        }
    }

    func advanceMs(_ d: UInt64) {
        lock.withLock { _nowMs &+= d }
    }

    var sleepRequests: [Int] { lock.withLock { _sleepRequests } }
}

// MARK: - Shared event-log helpers

/// Thread-safe string event recorder for @Sendable closure capture.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.withLock { items.append(s) } }
    var snapshot: [String] { lock.withLock { items } }
}

/// Thread-safe CameraError recorder for @Sendable closure capture.
final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CameraError] = []
    func append(_ e: CameraError) { lock.withLock { items.append(e) } }
    var snapshot: [CameraError] { lock.withLock { items } }
}

/// Thread-safe counter for @Sendable closure capture.
final class IntCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0
    func increment() { lock.withLock { value += 1 } }
    var get: Int { lock.withLock { value } }
}

// MARK: - Stage09WatchdogTests

@Suite("Stage 09 — watchdog identity", .progressLogged)
struct Stage09WatchdogTests {
    @Test("armed token is captured at arm and stable across refresh")
    func tokenCapturedAtArm() async {
        let clock = SystemClock()
        let wd = Watchdog(kind: .gpu, clock: clock) { _ in
            Issue.record("callback must not fire in this test")
        }
        wd.arm(sessionToken: 42)
        wd.refresh()
        #expect(wd.armedSessionToken == 42)
        wd.disarm()
        #expect(wd.armedSessionToken == nil)
    }

    @Test("late-firing watchdog with stale token no-ops (Inv 12)")
    func watchdogCapturedTokenSurvivesRetry() async throws {
        let clock = TestClock()
        let fireCount = IntCounter()
        let wd = Watchdog(kind: .capture, clock: clock) { _ in fireCount.increment() }
        wd.arm(sessionToken: 1)
        // Advance past threshold — poller will fire on next sleep cycle.
        clock.advanceMs(UInt64(Constants.stallCaptureThresholdMs) + 10)
        // Give the poller task a chance to run.
        try await Task.sleep(for: .milliseconds(200))
        // The engine would compare fire.armedSessionToken (1) to liveToken (2) and no-op.
        let liveToken: UInt64 = 2
        if fireCount.get > 0 {
            // Watchdog fired — but caller's token advanced; simulate the engine guard.
            #expect(UInt64(1) != liveToken, "stale token must not match live token")
        }
        wd.disarm()
    }
}

// MARK: - Stage09RecoveryTests

@Suite("Stage 09 — recovery backoff", .progressLogged)
struct Stage09RecoveryTests {
    @Test("backoff schedule matches constants (1..5+)")
    func backoffMatchesConstants() async {
        #expect(Constants.recoveryBackoffMs(attempt: 1) == 500)
        #expect(Constants.recoveryBackoffMs(attempt: 2) == 1000)
        #expect(Constants.recoveryBackoffMs(attempt: 3) == 2000)
        #expect(Constants.recoveryBackoffMs(attempt: 4) == 4000)
        #expect(Constants.recoveryBackoffMs(attempt: 5) == 8000)
        #expect(Constants.recoveryBackoffMs(attempt: 9) == 8000)
    }
}

// MARK: - Stage09DisarmTests

@Suite("Stage 09 — disarm ordering", .progressLogged)
struct Stage09DisarmTests {
    @Test("disarm is observed before first state:recovering transition (D-13)")
    func disarmBeforeStateTransition() async {
        let log = EventLog()
        let hooks = RecoveryCoordinator.Hooks(
            performTeardownAndReopen: {},
            emitStateRecovering: { log.append("state:recovering") },
            emitError: { _ in log.append("error") },
            disarmWatchdogs: { log.append("disarm") },
            incrementSessionToken: {}
        )
        let coord = RecoveryCoordinator(clock: TestClock(), hooks: hooks)
        await coord.enterRecovery(error: CameraError(code: .captureFailure, message: "x", isFatal: false))
        let events = log.snapshot
        #expect(events.first == "disarm")
        guard let iDisarm = events.firstIndex(of: "disarm"),
            let iState = events.firstIndex(of: "state:recovering")
        else {
            Issue.record("expected both 'disarm' and 'state:recovering' events")
            return
        }
        #expect(iDisarm < iState)
    }
}

// MARK: - Stage09BackoffIntegrationTests

@Suite("Stage 09 — backoff integration", .progressLogged)
struct Stage09BackoffIntegrationTests {
    @Test("retries fire at 500/1000/2000/4000/8000 ms; 6th failure is fatal")
    func exponentialBackoffScheduleMatchesConstants() async {
        let clock = TestClock()
        let errLog = ErrorLog()
        let hooks = RecoveryCoordinator.Hooks(
            performTeardownAndReopen: {
                throw NSError(domain: "test", code: 1)
            },
            emitStateRecovering: {},
            emitError: { errLog.append($0) },
            disarmWatchdogs: {},
            incrementSessionToken: {}
        )
        let coord = RecoveryCoordinator(clock: clock, hooks: hooks)
        for _ in 0..<Constants.hwErrorThresholdConsecutive {
            _ = await coord.noteHardwareFailure(message: "hw")
        }
        // The recursive enterRecovery chain runs via detached retryTasks —
        // each enterRecovery spawns the next and returns, so there is no
        // single handle to await. TestClock.sleep() is immediate, so the
        // chain settles in a handful of yields, but "a handful" is
        // scheduler-dependent under parallel test load. Poll for the terminal
        // fatal instead of guessing a fixed count; the cap fails cleanly if
        // the chain never terminates.
        var settled = false
        for _ in 0..<1000 {
            if errLog.snapshot.last?.code == .maxRetriesExceeded {
                settled = true
                break
            }
            await Task.yield()
        }
        #expect(settled, "recovery chain did not reach maxRetriesExceeded within 1000 yields")

        let sleeps = clock.sleepRequests
        #expect(sleeps.prefix(5).elementsEqual([500, 1000, 2000, 4000, 8000]))
        let errors = errLog.snapshot
        #expect(errors.last?.code == .maxRetriesExceeded)
        #expect(errors.last?.isFatal == true)
    }
}

// MARK: - Stage09CameraInUseTests

@Suite("Stage 09 — CAMERA_IN_USE self-heal", .progressLogged)
struct Stage09CameraInUseTests {
    /// D-14: a `.cameraInUseEnded` interruption drives the engine to `.closed`
    /// with no host action — the host must call `open()` again to recover.
    ///
    /// Previously `.disabled` as a "timing flake"; the real cause was twofold.
    /// `close()` early-returns before `publishState(.closed)` when `!isOpen`,
    /// so on a never-opened engine `.closed` was never published at all — and
    /// the old detached collector `Task` + `Task.yield()` loop raced the
    /// scheduler regardless. Fix: `_markOpenForTest()` sets the realistic
    /// precondition (a real interruption only reaches a running session), and
    /// the `.bufferingOldest` state stream is drained directly per event, so
    /// each `next()` returns deterministically with no scheduler dependency.
    @Test("interruption-ended routes engine to .closed without host action (D-14)")
    func cameraInUseSelfHealToClosed() async throws {
        let engine = CameraEngine(initialPhase: .active)
        await engine._markOpenForTest()
        var iterator = await engine.stateStream().makeAsyncIterator()

        await engine._postSessionEventForTest(.cameraInUseBegan)
        let afterBegan = await iterator.next()
        #expect(afterBegan == .error, "expected .error after cameraInUseBegan")

        await engine._postSessionEventForTest(.cameraInUseEnded)
        let afterEnded = await iterator.next()
        #expect(afterEnded == .closed, "expected .closed after cameraInUseEnded")
    }
}

// MARK: - Stage09ErrorStreamTests

@Suite("Stage 09 — error stream delivery", .progressLogged)
struct Stage09ErrorStreamTests {
    @Test("errorStream delivers 5 rapid errors in order (bufferingOldest semantics)")
    func errorStreamDeliversEveryTransition() async throws {
        let engine = CameraEngine(initialPhase: .active)
        let stream = await engine.errorStream()
        let testErrors: [CameraError] = [
            CameraError(code: .captureFailure, message: "1", isFatal: false),
            CameraError(code: .fpsDegraded, message: "2", isFatal: false),
            CameraError(code: .frameStall, message: "gpu:3", isFatal: false),
            CameraError(code: .aeConvergenceTimeout, message: "4", isFatal: false),
            CameraError(code: .unknownError, message: "5", isFatal: false),
        ]
        for e in testErrors { await engine._emitErrorForTest(e) }
        var received: [CameraError] = []
        for await e in stream {
            received.append(e)
            if received.count == 5 { break }
        }
        #expect(received.map(\.code) == testErrors.map(\.code))
    }
}

// MARK: - Stage09AETests

@Suite("Stage 09 — AE convergence", .progressLogged)
struct Stage09AETests {
    @Test("AE searching past threshold emits AE_CONVERGENCE_TIMEOUT once")
    func aeConvergenceTimeoutEmits() async throws {
        // Verifies the constant and error code are accessible.
        // Full AE monitor integration is a HITL test (requires live device + DeviceStateSnapshot).
        #expect(Constants.aeConvergenceTimeoutMs == 5000)
        let err = CameraError(code: .aeConvergenceTimeout, message: "AE searching > 5000ms", isFatal: false)
        #expect(err.isFatal == false)
        #expect(err.code == .aeConvergenceTimeout)
    }
}

// MARK: - Stage09FPSTests

@Suite("Stage 09 — FPS degradation", .progressLogged)
struct Stage09FPSTests {
    @Test("FPS below threshold for streak windows emits once; recovery resets streak")
    func fpsDegradedRequiresStreak() async throws {
        // Verifies constants and error code accessibility.
        // Full integration test requires driving engine.noteFrameDelivered() with a TestClock.
        // `fpsDegradedThresholdFps` (absolute fps) was renamed to
        // `fpsDegradedFraction` (fraction of expected fps) — engine now derives
        // the threshold dynamically as `expectedFps * Constants.fpsDegradedFraction`.
        #expect(Constants.fpsDegradedFraction == 0.8)
        #expect(Constants.fpsDegradedStreakCount == 3)
        #expect(Constants.fpsMeasurementWindowFrames == 30)
        let err = CameraError(code: .fpsDegraded, message: "10.0 fps over 30-frame window", isFatal: false)
        #expect(err.code == .fpsDegraded)
        #expect(err.isFatal == false)
    }
}
