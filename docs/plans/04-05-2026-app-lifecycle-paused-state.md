# Plan: App Lifecycle Handling — PAUSED State

## Context

The Camera2 app has no handling for Android app lifecycle events (minimize, screen lock, task switch). The `WidgetsBindingObserver` mixin is present in `lib/main.dart` but only `didChangeMetrics()` is hooked up — the camera keeps streaming in the background.

The fix adds a `PAUSED` state to the existing Kotlin state machine, which is semantically distinct from `CLOSED`:
- `CLOSED` = fully torn down, instance dead (`released = true`, background thread killed)
- `PAUSED` = Camera2 resources released (device, session, GPU pipeline stopped), but the `CameraController` instance survives and can resume without re-creating anything

This is faster than close/reopen and gives the Dart app a clean state to react to.

---

## State Machine Changes

**Current:** `CLOSED → OPENING → STREAMING ⇄ RECOVERING → ERROR`

**New:**
```
STREAMING → pause() → PAUSED
PAUSED    → resume() → OPENING → STREAMING
```

`pause()` from any state other than STREAMING is a no-op (guards against double-pause or pausing an already-closed camera). `resume()` from any state other than PAUSED is a no-op.

---

## Implementation Steps

### Step 1 — Pigeon: add `pause` and `resume` to `CameraHostApi`

**File:** `packages/cambrian_camera/pigeons/camera_api.dart` (line 252, after `close`)

```dart
@async
void pause(int handle);

@async
void resume(int handle);
```

Then regenerate bindings:
```bash
cd packages/cambrian_camera
dart run pigeon --input pigeons/camera_api.dart
```

**Files modified:** `pigeons/camera_api.dart`, then auto-generated `lib/src/messages.g.dart` + `android/src/main/kotlin/.../Messages.g.kt`

---

### Step 2 — Kotlin: add `PAUSED` state + `pause()` / `resume()` methods

**File:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt`

**2a.** Add `PAUSED` to the enum (line 145):
```kotlin
private enum class State { CLOSED, OPENING, STREAMING, RECOVERING, PAUSED, ERROR }
```

**2b.** Add `pause()` after `close()` (around line 439):
```kotlin
fun pause(callback: (Result<Unit>) -> Unit) {
    if (state != State.STREAMING) {
        callback(Result.success(Unit))
        return
    }
    teardown()
    // NOTE: do NOT set released=true and do NOT quit backgroundThread — instance stays alive
    emitState("paused")
    setState(State.PAUSED)
    callback(Result.success(Unit))
}
```

**2c.** Add `resume()` after `pause()`:
```kotlin
fun resume(callback: (Result<Unit>) -> Unit) {
    if (state != State.PAUSED) {
        callback(Result.success(Unit))
        return
    }
    // Re-use the camera ID and settings cached from the original open() call
    open(resolvedCameraId, pendingSettings, callback)
}
```

`resolvedCameraId` (line 203) and `pendingSettings` are already stored on the controller from the original `open()` call — no new fields needed.

---

### Step 3 — Kotlin: wire up Pigeon handler in plugin

**File:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CambrianCameraPlugin.kt`

Add handlers for `pause` and `resume` in the Pigeon `CameraHostApi` setup block (mirror the existing `close` handler pattern):

```kotlin
override fun pause(handle: Long, callback: (Result<Unit>) -> Unit) {
    val controller = controllers[handle] ?: run {
        callback(Result.failure(FlutterError("invalid_handle", "No camera for handle $handle", null)))
        return
    }
    controller.pause(callback)
}

override fun resume(handle: Long, callback: (Result<Unit>) -> Unit) {
    val controller = controllers[handle] ?: run {
        callback(Result.failure(FlutterError("invalid_handle", "No camera for handle $handle", null)))
        return
    }
    controller.resume { result ->
        result.onSuccess { callback(Result.success(Unit)) }
        result.onFailure { callback(Result.failure(it)) }
    }
}
```

---

### Step 4 — Dart: add `paused` to `CameraState` enum

**File:** `packages/cambrian_camera/lib/src/camera_state.dart` (line 5)

```dart
enum CameraState {
  closed,
  opening,
  streaming,
  recovering,
  paused,   // ← new: resources released, instance alive, can resume
  error;

  static CameraState fromString(String s) => switch (s) {
    'closed'     => closed,
    'opening'    => opening,
    'streaming'  => streaming,
    'recovering' => recovering,
    'paused'     => paused,   // ← new
    _            => error,
  };
}
```

---

### Step 5 — Dart: add `pause()` / `resume()` to `CambrianCamera`

**File:** `packages/cambrian_camera/lib/src/cambrian_camera_controller.dart`

Add after the existing `close()` method:

```dart
/// Pauses the camera: releases Camera2 resources but keeps the instance alive.
/// Call [resume] to restart streaming with the same configuration.
/// No-op if the camera is not currently streaming.
Future<void> pause() async {
  if (_closed) return;
  await _hostApi.pause(_handle);
}

/// Resumes a paused camera. No-op if not in the paused state.
Future<void> resume() async {
  if (_closed) return;
  await _hostApi.resume(_handle);
}
```

---

### Step 6 — Dart app: wire up `didChangeAppLifecycleState` in `main.dart`

**File:** `lib/main.dart`

`_CameraScreenState` already has `with WidgetsBindingObserver` and `addObserver`/`removeObserver`. Add the missing callback:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  switch (state) {
    case AppLifecycleState.paused:
    case AppLifecycleState.hidden:    // screen locked or covered on Android 14+
      _camera?.pause();
    case AppLifecycleState.resumed:
      _camera?.resume();
    default:
      break;
  }
}
```

The `_camera` field already holds the `CambrianCamera` instance — no new state needed.

---

## Critical Files

| File | Change |
|------|--------|
| `packages/cambrian_camera/pigeons/camera_api.dart` | Add `pause`/`resume` to `CameraHostApi` |
| `packages/cambrian_camera/lib/src/messages.g.dart` | Auto-generated (pigeon) |
| `android/.../Messages.g.kt` | Auto-generated (pigeon) |
| `android/.../CameraController.kt:145` | Add `PAUSED` to enum |
| `android/.../CameraController.kt:~439` | Add `pause()` and `resume()` |
| `android/.../CambrianCameraPlugin.kt` | Wire Pigeon handlers |
| `packages/cambrian_camera/lib/src/camera_state.dart:5` | Add `paused` to enum |
| `packages/cambrian_camera/lib/src/cambrian_camera_controller.dart` | Add `pause()`/`resume()` methods |
| `lib/main.dart` | Implement `didChangeAppLifecycleState` |

---

## How the App Uses the Paused State

The `CameraState.paused` state is broadcast on the existing `stateStream`. The app UI can react to it just like any other state:

```dart
StreamBuilder<CameraState>(
  stream: _camera.stateStream,
  builder: (context, snap) {
    return switch (snap.data) {
      CameraState.streaming => CameraPreviewWidget(...),
      CameraState.paused    => const SizedBox.shrink(), // hide preview while paused
      CameraState.opening   => const CircularProgressIndicator(),
      CameraState.recovering => const Text('Reconnecting…'),
      CameraState.error     => const Text('Camera error'),
      _                     => const SizedBox.shrink(),
    };
  },
)
```

On Android 14+, `AppLifecycleState.hidden` fires when the screen is locked (before `paused`). Both are handled by the same branch above.

---

## Verification

1. `flutter run` on a physical Android device
2. Start camera streaming — confirm preview is visible
3. Press Home → logcat shows `CameraController: state=paused`; return to app → `state=streaming` resumes
4. Lock screen → same as step 3
5. Switch to another camera app while your app is paused — no "camera in use by another app" error
6. Run `flutter test` to ensure no regressions in unit tests
