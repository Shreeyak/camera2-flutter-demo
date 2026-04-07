# Fix: Stall watchdog should detect zero-frame sessions

**PR comments:** #20 thread 3042374965

## Problem

The stall watchdog checks `lastCaptureResultMs > 0L` before comparing elapsed time. If no capture results ever arrive after entering STREAMING (e.g. dead pipeline), `lastCaptureResultMs` stays 0 and the watchdog never triggers. The controller is stuck in STREAMING with no frames.

## Changes

**`CameraController.kt` — stall watchdog and `startCaptureSession`:**

Initialize `lastCaptureResultMs` to `SystemClock.elapsedRealtime()` when entering STREAMING (in the `onConfigured` callback, right before posting the watchdog):
```kotlin
lastCaptureResultMs = android.os.SystemClock.elapsedRealtime()
backgroundHandler.postDelayed(stallWatchdog, stallCheckIntervalMs)
```

This way, if no frames arrive within `stallTimeoutMs` of session start, the watchdog fires.

## Acceptance criteria

- If a session starts but delivers zero frames, stall watchdog triggers after 5 seconds
- Normal operation unaffected (first `onCaptureCompleted` updates `lastCaptureResultMs`)
