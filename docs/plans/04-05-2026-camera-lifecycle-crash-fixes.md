# Plan: Camera Lifecycle Crash Fixes

## Bug 3: Frame stall detection + lifecycle-aware pause/resume

### Problem

After a screen lock or app switch, Camera2 silently stops delivering frames with no error
callback. The GPU pipeline's `onFrameAvailable` stops being called. The existing recovery
system is never triggered. The user sees the last frame frozen indefinitely.

A naive watchdog — firing `handleNonFatalError` after N seconds without a frame — introduces
a new problem: the watchdog cannot distinguish between:
- **Foreground stall** — camera froze while the app was active (hardware error, another app
  seized the camera). Should trigger recovery.
- **Background pause** — camera stopped because the screen locked or the app switched away.
  Expected behaviour; retrying exhausts all 5 retries before the user returns, leaving the
  camera in a permanent `ERROR` state.

### Solution

**Proactively pause the camera on `ON_PAUSE`, resume on `ON_RESUME`.** The camera voluntarily
yields the session when backgrounded. The watchdog only runs while the app is in the
foreground, so it only fires for genuine stalls.

This is also good Android citizenship — releasing the capture session on pause lets other apps
(phone calls, system camera) access the hardware without fighting for it.

---

## Implementation

### Step 1: Add `teardownSession()` to CameraController

A targeted teardown that closes the capture session, GPU pipeline, and native pipeline, but
**keeps `CameraDevice` open**. Cheaper than a full teardown and avoids the slow device reopen
on resume.

If the HAL forcibly closes the device while paused (some devices do this), the existing
`onDisconnected` callback fires → `handleNonFatalError` → recovery, which is correct.

**File:** `CameraController.kt`

```kotlin
private fun teardownSession() {
    backgroundHandler.removeCallbacks(stallWatchdog)

    try { captureSession?.close() } catch (_: Exception) {}
    captureSession = null

    try { imageReader?.close() } catch (_: Exception) {}
    imageReader = null

    try { gpuPipeline?.stop() } catch (_: Exception) {}
    gpuPipeline = null

    try { jpegImageReader?.close() } catch (_: Exception) {}
    jpegImageReader = null
    repeatingTargetSurface = null
    streamFrameCount = 0L
    captureResultCount = 0L
    detectedYuvFormat = YUV_FORMAT_UNKNOWN

    synchronized(pipelineLock) {
        val ptr = nativePipelinePtr
        if (ptr != 0L) {
            nativePipelinePtr = 0L
            nativeRelease(ptr)
        }
    }
}
```

### Step 2: Add `pause()` and `resume()` to CameraController

```kotlin
fun pause() {
    if (state != State.STREAMING) return
    android.util.Log.i("CambrianCamera", "CameraController[$handle]: pausing")
    setState(State.OPENING)   // OPENING = "device held, no capture session"
    teardownSession()
}

fun resume() {
    if (state != State.OPENING || cameraDevice == null) return
    android.util.Log.i("CambrianCamera", "CameraController[$handle]: resuming")
    startCaptureSession {}
}
```

`OPENING` is reused — it already means "device ready, no session running." `resume()` guards
on `cameraDevice != null`: if the HAL closed the device while paused, `onDisconnected` will
have transitioned state to `RECOVERING`, making `resume()` a no-op while recovery handles the
reopen.

### Step 3: Observe process lifecycle in CambrianCameraPlugin

**File:** `CambrianCameraPlugin.kt`

```kotlin
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner

private val lifecycleObserver = object : DefaultLifecycleObserver {
    override fun onPause(owner: LifecycleOwner) {
        sessions.values.forEach { it.controller.pause() }
    }
    override fun onResume(owner: LifecycleOwner) {
        sessions.values.forEach { it.controller.resume() }
    }
}
```

Register/unregister tied to activity attachment:

```kotlin
override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
    ProcessLifecycleOwner.get().lifecycle.addObserver(lifecycleObserver)
}

override fun onDetachedFromActivity() {
    ProcessLifecycleOwner.get().lifecycle.removeObserver(lifecycleObserver)
    activity = null
}
// Mirror for onDetachedFromActivityForConfigChanges / onReattachedToActivityForConfigChanges
```

`ProcessLifecycleOwner` tracks the entire process (not one Activity), so config changes don't
cause spurious pause/resume events.

### Step 4: Add frame stall watchdog to CameraController

Runs only while `STREAMING` (i.e., only in the foreground after the above changes).

**State fields:**
```kotlin
@Volatile private var lastCaptureResultMs: Long = 0L
private val stallCheckIntervalMs = 3_000L
private val stallTimeoutMs       = 5_000L
```

**Watchdog runnable:**
```kotlin
private val stallWatchdog = object : Runnable {
    override fun run() {
        if (released || state != State.STREAMING) return
        val elapsed = SystemClock.elapsedRealtime() - lastCaptureResultMs
        if (lastCaptureResultMs > 0L && elapsed > stallTimeoutMs) {
            Log.w("CambrianCamera", "Frame stall detected: ${elapsed}ms — triggering recovery")
            handleNonFatalError(CamErrorCode.PIPELINE_ERROR, "Frame delivery stalled (${elapsed}ms)")
            return
        }
        backgroundHandler.postDelayed(this, stallCheckIntervalMs)
    }
}
```

Update `lastCaptureResultMs` in `onCaptureCompleted`. Start watchdog after
`setState(STREAMING)`. Stop it at the top of `teardown()` and `teardownSession()`.

### Step 5: Check/add Gradle dependency

`ProcessLifecycleOwner` and `DefaultLifecycleObserver` require:

**File:** `packages/cambrian_camera/android/build.gradle`

```gradle
implementation "androidx.lifecycle:lifecycle-process:2.6.2"
```

May already be a transitive dependency via `flutter_plugin_android_lifecycle` — check before adding.

---

## Scenario coverage

| Scenario | Behaviour |
|---|---|
| Screen lock / app switch | `ON_PAUSE` → `pause()` → session torn down, watchdog stopped. No stall fired. |
| Return from background | `ON_RESUME` → `resume()` → `startCaptureSession`. Watchdog restarts. |
| HAL closes device while paused | `onDisconnected` → `RECOVERING` → full reopen. |
| Foreground stall (camera seized by another app) | Watchdog fires after 5s → `handleNonFatalError` → recovery. |
| Config change (rotation) | `ProcessLifecycleOwner` is process-scoped — no spurious pause/resume. |

---

## Verification

1. **Screen lock:** Lock → wait 30s → unlock → preview resumes. Logcat: `pausing` / `resuming`. No stall warnings.
2. **App switch:** Switch away → return → preview resumes.
3. **Foreground stall:** Open system camera while this app is in foreground → watchdog fires after 5s → recovery.
4. **Build:** `flutter build apk`
5. **Tests:** `./gradlew :cambrian_camera:testDebugUnitTest`
