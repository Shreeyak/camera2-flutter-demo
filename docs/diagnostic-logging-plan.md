# Diagnostic Logging Plan

## The bug

The camera preview stops displaying frames while the app is still running.
Symptoms: raw stream shows pure black, tonemapped stream shows deep blue
(shader math on zero input). Restart fixes it. No error is reported to Dart.

This means Camera2 stopped delivering frames to the OES SurfaceTexture, but
the GPU pipeline is still alive and rendering. The library has no way to
detect or report this condition because the critical path
(`GpuPipeline.onFrameAvailable`) has zero logging and no health monitoring.

### Root cause candidates

1. **Hot restart orphans the native session.** Dart state is wiped but
   `CambrianCameraPlugin.sessions` survives. The old `CameraController` +
   `GpuPipeline` keep running. Dart calls `open()` again, but the old session
   still holds the camera device. No `close()` is called on the old session.

2. **Surface lifecycle breaks the GPU pipeline.** When the app backgrounds,
   `onSurfaceCleanup` fires and `nativeSetPreviewWindow(ptr, null)` is called
   on the ImagePipeline (CPU path). But the GpuRenderer's EGL window surface
   is baked in at construction — there is no equivalent recovery call for the
   GPU path. When the app returns to foreground, the GpuRenderer still renders
   to the dead EGL surface.

3. **Camera2 session silently invalidated.** Another app seizes the camera, or
   a transient Camera2 error triggers recovery that fails silently. The
   `handleNonFatalError` path has zero logging — retries happen in the dark.

We cannot distinguish between these without logging.

## Logging categories

### Always-on (not gated)

These log at most once per lifecycle event or error. No per-frame cost.

| Location | Log | Why always-on |
|---|---|---|
| `CameraController.onSurfaceAvailable` | `Log.i` surface dimensions | Surface lifecycle is the #1 suspect and happens rarely |
| `CameraController.onSurfaceCleanup` | `Log.i` | Same — must always know when surfaces die |
| `CameraController.setState/emitState` | `Log.i` state name | State transitions are rare and critical for diagnosis |
| `CameraController.handleNonFatalError` | `Log.w` error code, message, retry count | Errors that trigger recovery must always be visible |
| `CameraController.handleFatalError` | `Log.e` error code, message | Fatal errors must never be silent |
| `CameraController.release()` | `Log.i` handle | Must know when teardown happens |
| `CameraController` device callbacks: `onOpened`, `onDisconnected`, `onError` | `Log.i`/`Log.w`/`Log.e` | Rare, critical Camera2 lifecycle events |
| `CameraController.onConfigureFailed` | `Log.e` | Session config failure must never be silent |
| `GpuPipeline.stop()` | `Log.i` | Must know when the GL thread is torn down |
| `GpuRenderer.cpp eglSwapBuffers` | `LOGE` on failure | EGL surface death is a likely cause of this bug |
| `GpuRenderer.cpp release()` | `LOGI` | Resource cleanup marker |
| `CambrianCameraPlugin.open()` | `Log.i` handle, cameraId | Session creation is rare |
| `CambrianCameraPlugin.close()` | `Log.i` handle | Session teardown is rare |
| `CambrianCameraPlugin.onDetachedFromEngine` | `Log.i` session count | Must know when engine detaches |

### Gated behind `CambrianCameraConfig.debugDataFlow`

These fire per-frame or at high frequency. Gate them to avoid log spam at
30 fps in production.

| Location | Log | Frequency |
|---|---|---|
| `GpuPipeline.onFrameAvailable` frame heartbeat | `Log.d` frame count every 100 frames | ~3x/sec at 30fps |
| `GpuPipeline.onFrameAvailable` stall detector | `Log.w` if >2s since last frame | At most once per stall event |
| `GpuRenderer.cpp drawAndReadback` frame heartbeat | `LOGD` frame count every 300 frames | ~1x/sec at 30fps |

### Gated behind `CambrianCameraConfig.verboseDiagnostics`

Already exists for settings and capture result logging. No changes needed
to this category.

## Self-diagnosis: frame stall detection

The library should detect when frames stop arriving and report it to Dart
through the existing `errorStream`. This turns an invisible failure into a
recoverable error.

### Implementation

Add to `GpuPipeline`:

```kotlin
private var lastFrameTimeMs = 0L
private var frameCount = 0L
private var stalled = false
```

In `onFrameAvailable`:

```kotlin
val now = SystemClock.elapsedRealtime()
frameCount++

if (CambrianCameraConfig.debugDataFlow && frameCount % 100 == 0L) {
    Log.d(TAG, "[DataFlow] frame #$frameCount")
}

lastFrameTimeMs = now
stalled = false
```

Add a periodic stall check on the GL thread (posted every 3 seconds):

```kotlin
private fun scheduleStallCheck() {
    glHandler.postDelayed({
        if (gpuHandle == 0L) return@postDelayed
        val elapsed = SystemClock.elapsedRealtime() - lastFrameTimeMs
        if (elapsed > STALL_THRESHOLD_MS && !stalled) {
            stalled = true
            Log.w(TAG, "Frame stall detected: ${elapsed}ms since last frame (frame #$frameCount)")
            onStallDetected?.invoke(elapsed)
        }
        scheduleStallCheck()
    }, STALL_CHECK_INTERVAL_MS)
}

companion object {
    private const val STALL_THRESHOLD_MS = 3000L
    private const val STALL_CHECK_INTERVAL_MS = 3000L
}
```

Wire `onStallDetected` through `CameraController` to emit a non-fatal
`CameraError` with a new error code (e.g., `frameStall`) to Dart. This
lets the app show a "camera feed lost" indicator or trigger recovery.

## eglSwapBuffers error checking

In `GpuRenderer::drawAndReadback()`, the `eglSwapBuffers` call (line 255)
does not check its return value. If the EGL surface is dead, this fails
silently every frame.

### Implementation

```cpp
// Replace:
eglSwapBuffers(eglDisplay_, eglWindowSurface_);

// With:
if (!eglSwapBuffers(eglDisplay_, eglWindowSurface_)) {
    EGLint err = eglGetError();
    LOGE("eglSwapBuffers failed: 0x%x", err);
    if (err == EGL_BAD_SURFACE || err == EGL_BAD_NATIVE_WINDOW) {
        eglWindowSurface_ = EGL_NO_SURFACE;  // stop blitting until surface is restored
    }
}
```

Same check for `rawEGLSurface_` (line 364).

## Dart-side logging

The Dart side of the library (`cambrian_camera_controller.dart`) has zero
logging. Add `debugPrint` calls gated behind `kDebugMode`:

| Location | Log |
|---|---|
| `open()` success | `debugPrint('CambrianCamera: opened handle=$handle')` |
| `open()` failure | `debugPrint('CambrianCamera: open failed: $e')` |
| `close()` | `debugPrint('CambrianCamera: closing handle=$_handle')` |
| `_onStateChanged` | `debugPrint('CambrianCamera: state=$_currentState')` |
| `_onError` | `debugPrint('CambrianCamera: error=${error.code} fatal=${error.isFatal}')` |

These only fire in debug builds (`kDebugMode` is tree-shaken in release).
No gating flag needed.

## How to use these logs to diagnose the bug

### Reproduction

1. `flutter run` the app
2. Wait for camera to stream normally
3. Trigger the suspected cause: hot restart (capital `R`), or background/foreground the app
4. Observe if preview goes black/blue

### Capture logs

```bash
adb logcat CambrianCamera:V GpuPipeline:V GpuRenderer:V CameraController:V flutter:V *:S
```

### What to look for

**If hot restart is the cause:**
- Two "Camera session configured" logs without an intervening "close" or
  "release" log — proves the old session was orphaned
- "opened handle=X" in Dart followed by "opened handle=Y" without
  "closing handle=X" — proves Dart didn't clean up

**If surface lifecycle is the cause:**
- "onSurfaceCleanup" log followed by "onSurfaceAvailable"
- Then "eglSwapBuffers failed: 0x300d" (EGL_BAD_SURFACE) or similar
- No "Frame stall detected" — frames are rendering but to a dead surface

**If Camera2 session is the cause:**
- "onDisconnected" or "onError" log from Camera2 device callback
- "Frame stall detected: Xms since last frame" — Camera2 stopped delivering
- Check if "handleNonFatalError" log shows retry attempts and whether they
  succeeded (look for subsequent "streaming" state transition)

**If the stall detector fires but no other error precedes it:**
- The OES SurfaceTexture may be detached from the GL context
- Check for any GL errors logged by `checkGlError()` in the frames before
  the stall

## Files to modify

| File | Changes |
|---|---|
| `CameraController.kt` | Add always-on logging to surface callbacks, state transitions, error handlers, device callbacks, release |
| `GpuPipeline.kt` | Add frame heartbeat (gated), stall detector, stop() logging |
| `GpuRenderer.cpp` | Add eglSwapBuffers error check, release() logging |
| `cambrian_camera_controller.dart` | Add kDebugMode-gated logging to open/close/state/error |
| `CambrianCameraConfig.kt` | No changes needed — existing `debugDataFlow` flag is sufficient |
| `camera_state.dart` | Add `frameStall` to error code handling if stall detection is wired to Dart |
| `pigeons/camera_api.dart` | Add `frameStall` to `CamErrorCode` enum (append only) |
