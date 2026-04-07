# Fix: FPS degradation detection should run independently of verbose diagnostics

**PR comments:** #18 thread 3042331836

## Problem

`fpsDegraded` detection (low FPS streak → non-fatal error to Dart) is inside the `CambrianCameraConfig.verboseDiagnostics` gate at line ~1890 of `CameraController.kt`. In production where `verboseDiagnostics` may be false, the FPS degradation error is never emitted.

## Changes

**`CameraController.kt` — `repeatingCaptureCallback.onCaptureCompleted`:**
- Move the FPS evaluation + `lowFpsStreak` logic OUTSIDE the `verboseDiagnostics` block
- Keep the `Log.d` heartbeat line gated behind `verboseDiagnostics`
- The `handleNonFatalError(CamErrorCode.FPS_DEGRADED, ...)` call must fire regardless of logging config

```
// Always evaluate FPS degradation (every 30 frames)
if (captureResultCount % 30L == 0L) {
    val fps = ... // compute
    // FPS streak logic (always runs)
    ...
    // Verbose log (only when diagnostics enabled)
    if (CambrianCameraConfig.verboseDiagnostics) {
        Log.d(...)
    }
}
```

## Acceptance criteria

- `fpsDegraded` error emitted to Dart when FPS drops below threshold, regardless of `verboseDiagnostics` setting
- Verbose heartbeat logs still gated behind the flag
