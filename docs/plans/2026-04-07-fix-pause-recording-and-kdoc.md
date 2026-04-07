# Fix: Pause/recording safety and KDoc accuracy

**PR comments:** #18 thread 3042331855 (HAL error guard), #19 threads 3042351416 (KDoc), 3042351425 (pause+recording), #20 threads 3042374997 (KDoc), 3042374989 (teardownSession+recording)

## Problems

1. **`pause()` KDoc** references `CameraState.PAUSED` which doesn't exist in Kotlin. Should say `"paused"` state string.
2. **`pause()` while recording** is unsafe — `teardownSession()` doesn't stop the recorder, leaving it running with no frames.
3. **`handleNonFatalError()` during RECOVERING** — repeated HAL errors can enqueue duplicate recovery retries.

## Changes

### 1. Fix KDoc (CameraController.kt ~line 508)

Replace `[CameraState.PAUSED]` with plain text:
```kotlin
 * Emits a "paused" state event to Dart.
```

### 2. Stop recording before pause (CameraController.kt — `pause()`)

At the top of `pause()`, before `teardownSession()`:
```kotlin
if (isRecording) {
    Log.w("CC/Cam", "[$handle] auto-stopping recording before pause")
    isRecording = false
    gpuPipeline?.setEncoderSurface(null)
    try { videoRecorder?.stop() } catch (e: Exception) {
        Log.w("CC/Cam", "recording stop on pause failed: ${e.message}")
    }
    mainHandler.post { flutterApi.onRecordingStateChanged(handle, "idle") {} }
}
```

Also add same guard in `teardownSession()`.

### 3. Guard HAL error threshold against RECOVERING (CameraController.kt — `onCaptureFailed`)

In the HAL error threshold check, add:
```kotlin
if (state == State.RECOVERING) {
    Log.d("CC/Cam", "ignoring HAL capture failure while already recovering")
} else {
    consecutiveHalErrors++
    if (consecutiveHalErrors >= HAL_ERROR_THRESHOLD) { ... }
}
```

## Acceptance criteria

- KDoc compiles without broken doc references
- `pause()` while recording auto-stops the recording cleanly (emits "idle", not "error")
- `teardownSession()` also handles active recording
- HAL errors during RECOVERING don't enqueue duplicate retries
