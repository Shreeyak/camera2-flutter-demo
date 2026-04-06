# Plan: Logging Improvements

Hardens the diagnostic logging system so a debugger can identify any camera failure from logs alone, and so log verbosity is controllable at runtime without rebuilding.

Depends on: current logging implementation (commit c5cc576).
Depends-before: `04-07-2026-self-healing.md` (that plan consumes the detection mechanisms added here).

---

## Step 1: Override missing Camera2 capture callbacks

### Why

`repeatingCaptureCallback` only overrides `onCaptureCompleted`. When the HAL drops a frame, `onCaptureFailed` and `onCaptureBufferLost` fire — but the default implementations are silent no-ops. We are blind to HAL-level frame drops and can't distinguish "slow pipeline" from "hardware error."

### What to change

**File:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt`

Inside the `repeatingCaptureCallback` object (the anonymous `CameraCaptureSession.CaptureCallback()` starting around line 1539), add three overrides:

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
}

override fun onCaptureBufferLost(
    session: CameraCaptureSession,
    request: CaptureRequest,
    target: Surface,
    frameNumber: Long,
) {
    val surfaceName = describeTargetSurface(target)
    Log.w("CC/Cam", "buffer lost: surface=$surfaceName frame=$frameNumber")
    bufferLostCount++
}

override fun onCaptureSequenceAborted(
    session: CameraCaptureSession,
    sequenceId: Int,
) {
    Log.w("CC/Cam", "capture sequence aborted: seq=$sequenceId")
}
```

Add instance fields near the other counters (`captureResultCount`, `streamFrameCount`, etc.):

```kotlin
private var captureFailureCount = 0L
private var bufferLostCount = 0L
```

Reset both to 0 in `teardown()` alongside the existing counter resets.

Include the counters in the existing heartbeat log (the `[HB #...]` line around line 1597) by appending `capFail=$captureFailureCount bufLost=$bufferLostCount`. Reset them after each heartbeat so the numbers represent per-interval counts, not cumulative.

### Verify

- Build and run. Force a capture failure by covering the lens + uncovering rapidly while in manual exposure. Check `adb logcat | grep "CC/Cam"` for `capture failed:` or `buffer lost:` lines.
- Verify heartbeat lines now include `capFail=` and `bufLost=` fields.
- Confirm `onCaptureSequenceAborted` fires during close (expected; the repeating request is cancelled).

---

## Step 2: Add recovery-success logging

### Why

When auto-recovery succeeds, `onOpened` logs `"device opened"` — indistinguishable from first-time open. A debugger can't tell how many retries it took or that recovery happened at all.

### What to change

**File:** `CameraController.kt`

In the `onOpened` callback (around line 396–401), the current code is:

```kotlin
override fun onOpened(camera: CameraDevice) {
    openLock.release()
    cameraDevice = camera
    retryCount = 0
    Log.i("CC/Cam", "device opened")
    startCaptureSession(safeCallback)
}
```

Change to log *before* resetting `retryCount`:

```kotlin
override fun onOpened(camera: CameraDevice) {
    openLock.release()
    cameraDevice = camera
    if (retryCount > 0) {
        Log.i("CC/Cam", "device reopened after recovery (retries=$retryCount)")
    } else {
        Log.i("CC/Cam", "device opened")
    }
    retryCount = 0
    startCaptureSession(safeCallback)
}
```

### Verify

- Trigger recovery by pulling the USB camera briefly (or simulating disconnect). Check logs for `"device reopened after recovery (retries=N)"` where N > 0.
- Normal open should still show `"device opened"`.

---

## Step 3: Pass debug level from Kotlin to C++

### Why

C++ logging is unconditional — ~116 log calls fire in release builds. The periodic performance logs (`ImagePipeline.cpp:361` every 60 frames, `GpuRenderer.cpp:209` every 300 frames) create noise for end users. Kotlin has runtime flags but C++ doesn't know about them.

### What to change

**A. Define the C++ side**

**File:** `packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h`

Add a field to `ImagePipeline`:

```cpp
int debugLevel_ = 0;  // 0=errors only, 1=lifecycle, 2=periodic/perf
```

Expose a setter or accept it in the constructor. Constructor is cleaner — add `int debugLevel` as the last parameter.

**File:** `packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp`

Store the constructor arg. Gate the periodic perf log (around line 361):

```cpp
if (debugLevel_ >= 2 && frameCount_ % kLogInterval == 0) {
    LOGD("perf [%llu] fps=%.1f ...", ...);
}
```

Leave LOGE calls ungated (errors always log). Leave one-time lifecycle logs (constructor, destructor, `processingLoop: started/exiting`) gated at level 1:

```cpp
if (debugLevel_ >= 1) {
    LOGD("ImagePipeline created, window=%p dims=%dx%d", ...);
}
```

**File:** `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h` / `GpuRenderer.cpp`

Same pattern. Add `int debugLevel_` field. Accept in constructor or `init()`. Gate the every-300-frames log (`drawAndReadback`, around line 209) at level 2. Gate lifecycle logs (`init: OK`, `release`, surface binds) at level 1.

**B. Thread through JNI**

**File:** `packages/cambrian_camera/android/src/main/cpp/src/CameraBridge.cpp`

Add `jint debugLevel` parameter to `nativeInit` and `nativeGpuInit` JNI signatures. Pass through to constructors.

**C. Thread through Kotlin**

**File:** `GpuPipeline.kt`

Update the `external fun nativeGpuInit(...)` signature to accept `debugLevel: Int`. Compute the level from config flags:

```kotlin
private fun computeDebugLevel(): Int = when {
    CambrianCameraConfig.verboseFullResult -> 2
    CambrianCameraConfig.debugDataFlow -> 2
    CambrianCameraConfig.verboseDiagnostics -> 1
    else -> 0
}
```

Pass `computeDebugLevel()` to `nativeGpuInit`.

**File:** `CameraController.kt`

Same for `nativeInit` — add `debugLevel` parameter, pass computed level.

### Verify

- Default config (`verboseDiagnostics=true`, `debugDataFlow=false`): C++ logs lifecycle events but NOT perf-every-60-frames or frame-counter-every-300.
- Set `debugDataFlow=true`: C++ perf logs appear.
- Set all flags false: only LOGE lines from C++.
- Run `adb logcat | grep -E "CC/Renderer|CambrianCamera"` and confirm noise reduction.

---

## Step 4: Make GPU lifecycle logs unconditional in Kotlin

### Why

`GpuPipeline.kt` gates init/release logs behind `debugDataFlow` (default: false). These fire once per session — zero volume concern — but they're critical breadcrumbs for debugging pipeline startup failures.

### What to change

**File:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt`

Remove the `if (CambrianCameraConfig.debugDataFlow)` guard around lines 88-89 and 97-99:

Before:
```kotlin
if (CambrianCameraConfig.debugDataFlow) {
    Log.i(TAG, "Initializing GpuPipeline: ${width}x${height}, raw: ${rawW}x${rawH}")
}
```

After:
```kotlin
Log.i(TAG, "Initializing GpuPipeline: ${width}x${height}, raw: ${rawW}x${rawH}")
```

Same for the `"GpuPipeline initialized successfully"` log.

Keep the per-100-frame heartbeat (line 232-234) gated behind `debugDataFlow` — that's periodic noise.

### Verify

- With `debugDataFlow=false` (default), `adb logcat | grep CC/Gpu` still shows `"Initializing GpuPipeline"` and `"initialized successfully"` on camera open.
- The `"frame #N"` every-100-frames log does NOT appear unless `debugDataFlow=true`.

---

## Step 5: Expand Dart-layer logging

### Why

The Dart layer is the library consumer's debugging surface. It has only 5 `debugPrint` calls — not enough to diagnose integration issues without also reading native logcat.

### What to change

**File:** `packages/cambrian_camera/lib/src/cambrian_camera_controller.dart`

Add `debugPrint` calls (all gated by `kDebugMode`) at these points:

**a) `updateSettings`** — log what the consumer sent:

```dart
Future<void> updateSettings(CameraSettings settings) async {
    if (kDebugMode) debugPrint('CC/Dart: updateSettings handle=$_handle $settings');
    _serializer.send(settings);
}
```

This requires `CameraSettings.toString()` to produce a useful summary. If it doesn't already, add one that prints only non-null fields.

**b) `setProcessingParams`** — log the params:

```dart
Future<void> setProcessingParams(ProcessingParams params) {
    if (kDebugMode) debugPrint('CC/Dart: setProcessingParams handle=$_handle $params');
    return _hostApi.setProcessingParams(_handle, params.toCam());
}
```

**c) `startRecording` / `stopRecording`**:

```dart
// In startRecording, after the await:
if (kDebugMode) debugPrint('CC/Dart: startRecording handle=$_handle → $uri');

// In stopRecording, after the await:
if (kDebugMode) debugPrint('CC/Dart: stopRecording handle=$_handle → $uri');
```

**d) Recording state changes** — in `_onRecordingStateChanged`:

```dart
void _onRecordingStateChanged(String state) {
    if (kDebugMode) debugPrint('CC/Dart: recordingState=$state handle=$_handle');
    _recordingStateController.add(RecordingState.fromString(state));
}
```

### Verify

- Run in debug mode. Open camera → logs show `open` with handle and resolution.
- Call `updateSettings` with manual ISO → logs show `updateSettings handle=1 iso=manual(400)`.
- Start/stop recording → logs show recording lifecycle.
- Build in release mode → none of these print (kDebugMode is false).

---

## Step 6: ADB broadcast receiver for runtime log-level toggling

### Why

In the field, a debugger needs to increase log verbosity without rebuilding. The `@Volatile` flags in `CambrianCameraConfig` are ready for runtime mutation but unreachable from outside the process.

### What to change

**A. Create receiver class**

**File:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/LogLevelReceiver.kt`

```kotlin
package com.cambrian.camera

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Toggles CambrianCameraConfig logging flags via ADB broadcast.
 *
 * Usage:
 *   adb shell am broadcast -a com.cambrian.camera.SET_LOG_LEVEL --ei level 0
 *
 * Levels:
 *   0 = quiet (all flags false)
 *   1 = default (verboseSettings=true, verboseDiagnostics=true)
 *   2 = verbose (adds debugDataFlow=true)
 *   3 = full (adds verboseFullResult=true)
 */
class LogLevelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val level = intent.getIntExtra("level", -1)
        if (level < 0) {
            Log.w(TAG, "SET_LOG_LEVEL: missing or invalid 'level' extra")
            return
        }
        CambrianCameraConfig.verboseSettings = level >= 1
        CambrianCameraConfig.verboseDiagnostics = level >= 1
        CambrianCameraConfig.debugDataFlow = level >= 2
        CambrianCameraConfig.verboseFullResult = level >= 3
        Log.i(TAG, "Log level set to $level: settings=${level >= 1} diag=${level >= 1} dataFlow=${level >= 2} fullResult=${level >= 3}")
    }

    companion object {
        private const val TAG = "CC/LogLevel"
    }
}
```

**B. Register in manifest**

**File:** `packages/cambrian_camera/android/src/main/AndroidManifest.xml`

Inside the `<application>` tag (or instruct the consuming app to register it):

```xml
<receiver
    android:name=".LogLevelReceiver"
    android:exported="true">
    <intent-filter>
        <action android:name="com.cambrian.camera.SET_LOG_LEVEL" />
    </intent-filter>
</receiver>
```

Note: `exported="true"` is fine for debug — this only writes log flags, not security-sensitive state. For release builds, gate with a BuildConfig check or remove via manifest merging.

### Verify

```bash
# Start with default level
adb logcat -c && adb logcat | grep "CC/" &

# Set to quiet
adb shell am broadcast -a com.cambrian.camera.SET_LOG_LEVEL --ei level 0
# → Heartbeat logs stop, 3A transitions still fire (unconditional)

# Set to verbose
adb shell am broadcast -a com.cambrian.camera.SET_LOG_LEVEL --ei level 2
# → debugDataFlow logs appear (GPU pipeline heartbeat, stream init details)

# Set to full
adb shell am broadcast -a com.cambrian.camera.SET_LOG_LEVEL --ei level 3
# → Full TotalCaptureResult dumps every 30 frames
```

---

## Step 7: Log `System.loadLibrary` failure

### Why

`GpuPipeline.kt:281` silently catches `UnsatisfiedLinkError`. If the native lib is missing at runtime (not in unit tests), every subsequent JNI call crashes with an unhelpful error. A log makes this immediately diagnosable.

### What to change

**File:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt`

```kotlin
init {
    try {
        System.loadLibrary("cambrian_camera")
    } catch (e: UnsatisfiedLinkError) {
        Log.w("CC/Gpu", "Native library not loaded (expected in JVM unit tests): ${e.message}")
    }
}
```

### Verify

- Normal run: no warning logged.
- Unit tests: warning appears but tests pass (existing behavior).

---

## Step 8: Log surface configuration on `onConfigureFailed`

### Why

`onConfigureFailed` currently logs `"session configure failed"` with no details about what was being configured. The surfaces and their sizes are the most useful diagnostic.

### What to change

**File:** `CameraController.kt`, in the `onConfigureFailed` override (around line 1047):

```kotlin
override fun onConfigureFailed(session: CameraCaptureSession) {
    val surfaceDesc = surfaces.joinToString { describeTargetSurface(it) }
    Log.e("CC/Cam", "session configure failed: surfaces=[$surfaceDesc] preview=${previewWidth}×${previewHeight}")
    handleNonFatalError(CamErrorCode.CONFIGURATION_FAILED, "CaptureSession configuration failed")
    // ... existing callback code
}
```

`surfaces` is the local `val surfaces = listOf(gpuSurface, jpegReader.surface)` from the enclosing scope. If it's not in scope, capture the surface descriptions before the session creation call.

### Verify

- This is hard to trigger intentionally. Verify by reading the code path and confirming the log format is correct. If you have a device that fails session config (rare), the log should now show which surfaces were involved.

---

## Order of execution

Steps 1–2 are independent of each other and of steps 3–8. Step 3 must complete before step 4 (step 4 changes gating logic that step 3's C++ level also affects). Steps 5–8 are all independent.

Suggested: 1 and 2 first (highest debugging value, smallest change), then 3, then 4–8 in any order.
