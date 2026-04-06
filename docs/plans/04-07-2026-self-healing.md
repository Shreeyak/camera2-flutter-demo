# Plan: Self-Healing Camera Pipeline

Uses detection mechanisms (logging counters, callbacks, timers) to automatically recover from degraded states without user intervention. Each step adds a fault detector and a response action, plus a new `CamErrorCode` so Dart consumers can observe what happened.

Depends on: `04-07-2026-logging-improvements.md` — specifically Step 1 (onCaptureFailed/onCaptureBufferLost counters) must be done first. Steps in this plan that don't depend on that are noted.

---

## Step 1: Auto-recovery on repeated HAL capture failures

### Problem

When `onCaptureFailed` fires with `REASON_ERROR` repeatedly, the HAL is in a degraded state. Currently nothing acts on this — frames silently vanish. Tearing down and rebuilding the capture session often clears transient HAL issues.

### Prerequisite

Logging plan Step 1 (override `onCaptureFailed`, `captureFailureCount` field).

### Detection logic

**File:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt`

In the `onCaptureFailed` override added by the logging plan, after incrementing `captureFailureCount`, add:

```kotlin
override fun onCaptureFailed(
    session: CameraCaptureSession,
    request: CaptureRequest,
    failure: CaptureFailure,
) {
    val reason = when (failure.reason) {
        CaptureFailure.REASON_ERROR -> "ERROR"
        CaptureFailure.REASON_FLUSHED -> "FLUSHED"
        else -> "UNKNOWN(${failure.reason})"
    }
    Log.w("CC/Cam", "capture failed: reason=$reason frame=${failure.frameNumber}")
    captureFailureCount++

    // --- NEW: trigger recovery on repeated HAL errors ---
    if (failure.reason == CaptureFailure.REASON_ERROR) {
        consecutiveHalErrors++
        if (consecutiveHalErrors >= HAL_ERROR_THRESHOLD) {
            Log.w("CC/Cam", "HAL error threshold reached ($consecutiveHalErrors consecutive failures), triggering recovery")
            consecutiveHalErrors = 0
            handleNonFatalError(CamErrorCode.CAPTURE_FAILURE, "Repeated HAL capture failures")
        }
    }
}
```

In `onCaptureCompleted`, reset the counter:

```kotlin
// At the top of onCaptureCompleted, before existing logic:
consecutiveHalErrors = 0
```

Add fields:

```kotlin
private var consecutiveHalErrors = 0
private companion object {
    const val HAL_ERROR_THRESHOLD = 5  // 5 consecutive failures before recovery
}
```

### New error code

**File:** `packages/cambrian_camera/pigeons/camera_api.dart`

Add to `CamErrorCode` enum:

```dart
captureFailure,      // HAL reported repeated capture failures
```

**File:** `packages/cambrian_camera/lib/src/camera_state.dart`

No change needed — `CameraError.fromPigeon` passes through any code.

After adding the enum value, run `scripts/regenerate_pigeon.sh` to update generated code.

### Verify

- This is hard to trigger on real hardware. Verify by:
  1. Reading the code path: `onCaptureFailed` → counter increment → threshold check → `handleNonFatalError` → existing recovery state machine kicks in.
  2. Unit test (if JVM testing is set up): mock `onCaptureFailed` calls and assert recovery triggers after threshold.
- Confirm `consecutiveHalErrors` resets on every successful `onCaptureCompleted`.
- Confirm `REASON_FLUSHED` does NOT increment the counter (expected during teardown).

---

## Step 2: Auto-rebind on repeated eglSwapBuffers failures

### Problem

`GpuRenderer.cpp` logs `eglSwapBuffers` failures but keeps trying with the stale surface. After Flutter recreates a `SurfaceProducer`, the old EGL surface is invalid. The preview goes black with repeated error logs but no recovery.

### Prerequisite

None (independent of logging plan).

### Detection logic

**File:** `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp`

Add a counter field to `GpuRenderer`:

```cpp
// In GpuRenderer.h, private section:
int consecutiveSwapFailures_ = 0;
static constexpr int kSwapFailureThreshold = 3;
```

In `drawAndReadback()`, around the `eglSwapBuffers` call for the processed preview (around line 279):

```cpp
if (!eglSwapBuffers(display_, windowSurface_)) {
    LOGE("drawAndReadback: eglSwapBuffers (processed) failed: 0x%x", eglGetError());
    consecutiveSwapFailures_++;
} else {
    consecutiveSwapFailures_ = 0;
}
```

### Response: signal Kotlin to rebind

Add a callback mechanism. The simplest approach: a boolean flag polled by Kotlin after each frame.

**File:** `GpuRenderer.h`

```cpp
public:
    bool needsPreviewRebind() const { return consecutiveSwapFailures_ >= kSwapFailureThreshold; }
    void clearRebindFlag() { consecutiveSwapFailures_ = 0; }
```

**File:** `CameraBridge.cpp`

Add a JNI function:

```cpp
extern "C" JNIEXPORT jboolean JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuNeedsPreviewRebind(
    JNIEnv*, jclass, jlong gpuHandle
) {
    auto* renderer = reinterpret_cast<GpuRenderer*>(gpuHandle);
    if (!renderer) return JNI_FALSE;
    return renderer->needsPreviewRebind() ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuClearRebindFlag(
    JNIEnv*, jclass, jlong gpuHandle
) {
    auto* renderer = reinterpret_cast<GpuRenderer*>(gpuHandle);
    if (renderer) renderer->clearRebindFlag();
}
```

**File:** `GpuPipeline.kt`

Add the external declarations and poll after each frame:

```kotlin
@JvmStatic external fun nativeGpuNeedsPreviewRebind(gpuHandle: Long): Boolean
@JvmStatic external fun nativeGpuClearRebindFlag(gpuHandle: Long)
```

In `onFrameAvailable`, after the `nativeGpuDrawAndReadback` call:

```kotlin
if (nativeGpuNeedsPreviewRebind(handle)) {
    Log.w(TAG, "preview surface stale — requesting rebind")
    nativeGpuClearRebindFlag(handle)
    onPreviewRebindNeeded?.invoke()
}
```

Add the callback field:

```kotlin
var onPreviewRebindNeeded: (() -> Unit)? = null
```

**File:** `CameraController.kt`

Wire it up where `gpuPipeline` is created (near line 985, after `pipeline.onStallDetected`):

```kotlin
pipeline.onPreviewRebindNeeded = {
    Log.i("CC/Cam", "rebinding preview surface after swap failures")
    val newSurface = surfaceProducer?.getSurface()
    if (newSurface != null) {
        pipeline.rebindPreviewSurface(newSurface)
    } else {
        Log.w("CC/Cam", "no surface available for rebind")
    }
}
```

### Verify

- Hard to trigger intentionally. Verify by reading the code path.
- After 3 consecutive `eglSwapBuffers` failures, confirm:
  1. `"preview surface stale — requesting rebind"` appears in logcat.
  2. `rebindPreviewSurface` is called with a fresh surface.
  3. Counter resets after rebind.
- Normal operation: `consecutiveSwapFailures_` stays 0, no overhead (single int comparison per frame).

---

## Step 3: FPS degradation detection and alert

### Problem

The heartbeat logs FPS but nobody acts on sustained drops. If FPS drops below 15 for several seconds (thermal throttle, background load), the user sees stuttery preview with no feedback.

### Prerequisite

None (uses existing heartbeat data).

### New error code

**File:** `packages/cambrian_camera/pigeons/camera_api.dart`

```dart
fpsDegraded,         // sustained FPS drop below acceptable threshold
```

Run `scripts/regenerate_pigeon.sh` after adding.

### Detection logic

**File:** `CameraController.kt`

Add fields:

```kotlin
private var lowFpsStreak = 0
private companion object {
    // ... existing constants ...
    const val LOW_FPS_THRESHOLD = 15.0
    const val LOW_FPS_STREAK_LIMIT = 3  // 3 consecutive heartbeats (~3 seconds at 30fps/30-result intervals)
}
```

In the heartbeat block (inside `onCaptureCompleted`, around line 1593, where `verboseDiagnostics` is checked), compute and check FPS:

```kotlin
if (CambrianCameraConfig.verboseDiagnostics && captureResultCount % 30L == 0L) {
    val drops = maxOf(0L, 30L - (streamFrameCount - lastHeartbeatFrameCount))
    lastHeartbeatFrameCount = streamFrameCount
    val frameDuration = result.get(CaptureResult.SENSOR_FRAME_DURATION)
    val fps = frameDuration?.let { 1_000_000_000.0 / it }

    // --- NEW: FPS degradation detection ---
    if (fps != null && fps < LOW_FPS_THRESHOLD) {
        lowFpsStreak++
        if (lowFpsStreak == LOW_FPS_STREAK_LIMIT) {
            Log.w("CC/Cam", "sustained low FPS: ${fps.format(1)} for $lowFpsStreak heartbeats")
            mainHandler.post {
                flutterApi.onError(handle, CamError(
                    CamErrorCode.FPS_DEGRADED,
                    "FPS degraded to ${fps.format(1)} for ${lowFpsStreak}s",
                    false
                )) {}
            }
        }
        // Don't reset — keep counting, but only emit once at the threshold.
        // Reset happens when FPS recovers.
    } else {
        lowFpsStreak = 0
    }

    // existing heartbeat log line...
}
```

Note: FPS detection runs inside the `verboseDiagnostics` gate. This is intentional — if diagnostics are off, we don't want the overhead of FPS checking. But if you want this always-on, move the FPS check outside the gate and only keep the Log.d inside.

### Dart-side handling

The error arrives via `errorStream` with `isFatal=false`. The demo app can show a snackbar or reduce quality. The library does NOT auto-reduce resolution — that's an app-level decision. We only surface the signal.

**File:** `lib/main.dart`, in `_onCameraError`:

```dart
case CamErrorCode.fpsDegraded:
    _showError('FPS degraded: ${error.message}');
    break;
```

### Verify

- Force low FPS by setting very long manual exposure (e.g., 200ms → max 5 FPS).
- After ~3 seconds, confirm `"sustained low FPS"` appears in logcat.
- Confirm Dart receives the error via `errorStream`.
- Return to auto exposure → FPS recovers → no more alerts (streak resets).
- Verify alert fires only once per degradation episode (not every heartbeat after threshold).

---

## Step 4: 3A convergence timeout

### Problem

If AE stays in `SEARCHING` for >5 seconds, something is wrong — lens blocked, extreme darkness, hardware issue. The user sees auto-exposure hunting indefinitely with no feedback.

### Prerequisite

None (uses existing 3A state tracking).

### New error code

**File:** `packages/cambrian_camera/pigeons/camera_api.dart`

```dart
aeConvergenceTimeout, // auto-exposure failed to converge within timeout
```

Run `scripts/regenerate_pigeon.sh`.

### Detection logic

**File:** `CameraController.kt`

Add fields:

```kotlin
private var aeSearchingStartMs = 0L
private companion object {
    // ... existing constants ...
    const val AE_CONVERGENCE_TIMEOUT_MS = 5000L
}
```

In the 3A state tracking block inside `onCaptureCompleted` (around line 1576–1590), after the existing AE transition log:

```kotlin
if (newAeState != lastAeState) {
    Log.i("CC/3A", "[AE] ${aeStateName(lastAeState)} → ${aeStateName(newAeState)} ...")
    lastAeState = newAeState

    // --- NEW: track convergence timing ---
    if (newAeState == CaptureResult.CONTROL_AE_STATE_SEARCHING) {
        aeSearchingStartMs = SystemClock.elapsedRealtime()
    } else {
        aeSearchingStartMs = 0L  // converged or locked — reset
    }
}

// Check timeout even when state hasn't changed (AE stuck in SEARCHING)
if (lastAeState == CaptureResult.CONTROL_AE_STATE_SEARCHING && aeSearchingStartMs > 0L) {
    val elapsed = SystemClock.elapsedRealtime() - aeSearchingStartMs
    if (elapsed >= AE_CONVERGENCE_TIMEOUT_MS) {
        Log.w("CC/3A", "AE convergence timeout: stuck in SEARCHING for ${elapsed}ms")
        aeSearchingStartMs = 0L  // prevent repeated firing
        mainHandler.post {
            flutterApi.onError(handle, CamError(
                CamErrorCode.AE_CONVERGENCE_TIMEOUT,
                "Auto-exposure failed to converge after ${elapsed}ms",
                false
            )) {}
        }
    }
}
```

### Dart-side handling

Non-fatal error. App can show guidance to the user.

**File:** `lib/main.dart`, in `_onCameraError`:

```dart
case CamErrorCode.aeConvergenceTimeout:
    _showError('Auto-exposure struggling — try more light or manual mode');
    break;
```

### Verify

- Cover the camera lens completely → AE enters SEARCHING.
- After 5 seconds, confirm `"AE convergence timeout"` in logcat and Dart error stream.
- Uncover lens → AE converges → timer resets → no more alerts.
- Verify the alert fires only once per stuck episode (aeSearchingStartMs resets to 0 after firing).
- In manual exposure mode, AE state is typically INACTIVE or LOCKED — verify no false positives.

---

## Step 5: Recording EOS drain timeout surfacing

### Problem

`VideoRecorder` logs EOS drain timeouts (`"EOS drain timeout, forcing stop"`) but doesn't tell Dart. A recording that hit the timeout likely produced a truncated file. The user thinks recording succeeded.

### Prerequisite

None (independent).

### Detection logic

**File:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/VideoRecorder.kt`

Find the EOS drain timeout handling (around line 298-310). Currently it logs a warning and force-stops the muxer. After the force-stop, signal the result:

Identify how `VideoRecorder` communicates back to `CameraController`. If it's via a callback or return value from `stop()`, modify accordingly.

Looking at the existing code: `stop()` likely returns the URI or throws. Add a `truncated` flag or throw a specific exception:

```kotlin
// After the EOS timeout force-stop:
Log.w(TAG, "VideoRecorder: EOS drain timeout, forcing stop")
eosDrainTimedOut = true
```

Add field:

```kotlin
private var eosDrainTimedOut = false
```

In the stop result (where URI is returned), include the truncation info. The simplest approach — emit a recording state event from `CameraController`:

**File:** `CameraController.kt`

Where `stopRecording` is handled and calls `videoRecorder.stop()`:

```kotlin
val uri = videoRecorder.stop()
if (videoRecorder.wasEosDrainTimedOut()) {
    Log.w("CC/Cam", "recording may be truncated (EOS drain timeout)")
    mainHandler.post {
        flutterApi.onError(handle, CamError(
            CamErrorCode.RECORDING_TRUNCATED,
            "Recording may be truncated — EOS drain timed out",
            false
        )) {}
    }
}
```

### New error code

```dart
recordingTruncated,  // recording stopped but EOS drain timed out — file may be truncated
```

Run `scripts/regenerate_pigeon.sh`.

### Verify

- Hard to trigger intentionally. Verify by reading the code path.
- If testable: start recording, then immediately kill the encoder surface (this sometimes causes EOS timeout). Check that Dart receives `recordingTruncated` error.
- Normal stop (no timeout): no error emitted.

---

## Step 6: InputRing dimension mismatch counting

### Problem

`InputRing::push` logs dimension mismatches and drops the frame, but if this happens repeatedly it means something upstream changed resolution mid-stream. Nobody notices.

### Prerequisite

None (independent).

### Detection logic

**File:** `packages/cambrian_camera/android/src/main/cpp/src/InputRing.cpp`

Add a counter:

```cpp
// In InputRing.h:
std::atomic<int> dimensionMismatchCount_{0};

// In InputRing.cpp, in push(), where the mismatch is detected:
LOGD("InputRing::push: dimension mismatch (%dx%d vs %dx%d), dropping frame",
     w, h, expected_w, expected_h);
dimensionMismatchCount_++;
```

**File:** `ImagePipeline.h` / `ImagePipeline.cpp`

Expose it:

```cpp
int getDimensionMismatchCount() const { return inputRing_.dimensionMismatchCount_.load(); }
```

**File:** `CameraBridge.cpp`

Add JNI accessor:

```cpp
extern "C" JNIEXPORT jint JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGetDimensionMismatchCount(
    JNIEnv*, jclass, jlong pipelineHandle
) {
    auto* pipeline = reinterpret_cast<ImagePipeline*>(pipelineHandle);
    if (!pipeline) return 0;
    return pipeline->getDimensionMismatchCount();
}
```

**File:** `CameraController.kt`

Poll in the heartbeat and log if non-zero:

```kotlin
// In the heartbeat block:
val mismatches = nativeGetDimensionMismatchCount(nativePipelinePtr)
if (mismatches > 0) {
    Log.w("CC/Cam", "InputRing dimension mismatches: $mismatches since last heartbeat")
}
```

This is informational — no auto-recovery action, just visibility. If mismatches are sustained, it indicates a bug in the pipeline setup (resolution negotiation failed).

### Verify

- Normal operation: mismatch count stays 0, no extra log lines.
- To test: would require intentionally sending wrong-sized frames to the native pipeline (not feasible in normal use). Verify by code review that the counter increments correctly and the JNI bridge reads it.

---

## New error codes summary

After all steps, the following codes are added to `CamErrorCode`:

| Code | Step | Fatal | Meaning |
|------|------|-------|---------|
| `captureFailure` | 1 | no | HAL reported repeated capture failures, recovery triggered |
| `fpsDegraded` | 3 | no | Sustained FPS below threshold |
| `aeConvergenceTimeout` | 4 | no | AE stuck in SEARCHING for >5s |
| `recordingTruncated` | 5 | no | EOS drain timed out, file may be incomplete |

All are non-fatal — the library either self-recovers or surfaces the issue for app-level handling.

Run `scripts/regenerate_pigeon.sh` once after adding all four codes (not once per step).

---

## Order of execution

Steps 1 and 2 are the highest-value self-healing behaviors — implement first.

- **Step 1** requires logging plan Step 1 to be done first.
- **Steps 2, 3, 4, 5, 6** are independent of each other and can be done in any order.
- All new `CamErrorCode` values should be added at once, then `regenerate_pigeon.sh` run once.

Suggested order: 1 → 2 → 3 → 4 → 5 → 6 (descending impact).
