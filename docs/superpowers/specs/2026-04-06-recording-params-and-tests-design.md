# Recording Params & Tests Design

**Date:** 2026-04-06
**Issues:** #5 (bitrate/fps params), #7 (already done), #8 (recording tests), #9 (resolved by #1)

---

## Status of issues 7 & 9

**Issue 7** (`isRecording` not `@Volatile`) — already fixed; `CameraController.kt:187` has `@Volatile private var isRecording = false`. No work required.

**Issue 9** (HUD timer drift) — resolved by the lifecycle fix (#1). The `Stopwatch` in `RecordingHud` starts on `RecordingState.recording` and stops on `idle`/`error`. Since encoding now stops on `AppLifecycleState.paused`, the timer accurately tracks recording duration. No code change needed.

---

## Issue 5 — Expose bitrate and fps as optional `startRecording` params

### Approach

Add `int? bitrate` and `int? fps` directly to the Pigeon `startRecording` signature, consistent with the existing `outputDirectory?`/`fileName?` params. Defaults (50 Mbps, 30 fps) stay in `VideoRecorder.prepare()`.

AE fps range: fix to `[15, 30]` (no dynamic adaptation — the current comment already says this is intentional for low-light AE flexibility).

### Layer-by-layer changes

**`pigeons/camera_api.dart`** — add two optional params to `startRecording`:
```dart
String startRecording(int handle, String? outputDirectory, String? fileName, int? bitrate, int? fps);
```

**`lib/src/messages.g.dart`** (generated, edited manually) — update `startRecording` to send `bitrate` and `fps` in the message list.

**`lib/src/cambrian_camera_controller.dart`** — add `bitrate` and `fps` named params to `startRecording()`, forward to `_hostApi.startRecording(...)`.

**`android/src/main/kotlin/com/cambrian/camera/Messages.g.kt`** (generated, edited manually) — decode two additional nullable `Long` args; cast to `Int?` before forwarding.

**`CambrianCameraPlugin.kt`** — update `startRecording` override to accept and forward `bitrate` and `fps`.

**`CameraController.kt`** — add `bitrate: Int? = null, fps: Int? = null` to `startRecording()`. Pass to `videoRecorder!!.prepare(previewWidth, previewHeight, bitrate = bitrate ?: 50_000_000, fps = fps ?: 30)`.

**`lib/main.dart`** — no change needed (call site uses named params, defaults apply).

### Wire format note

Pigeon encodes `int` as `Long` on the Kotlin side. The existing `outputDirectory`/`fileName` decode pattern (`args[2] as String?`) will extend to `args[4] as Long?` (bitrate) and `args[5] as Long?` (fps), cast to `Int?`.

---

## Issue 8 — Recording unit tests

### Approach

Add three test cases to the existing `CameraControllerGpuTest.kt`, using the same reflection-based injection pattern already in use for `GpuPipeline`.

Two new reflected fields needed:
- `videoRecorderField` — inject a `VideoRecorder` mock
- `isRecordingField` — set `isRecording = true` directly
- `stateField` — set controller `State` to `STREAMING` to allow `startRecording` to proceed

The `mockFlutterApi` already exists in the test's `setUp()`.

### Test cases

**`startRecording sets isRecording to true`**
1. Inject mock `VideoRecorder` (stub `prepare()`, `inputSurface` returns a mock `Surface`, `start()` returns `"content://fake/1"`)
2. Set `state = State.STREAMING` via reflection
3. Call `controller.startRecording { ... }` and wait for callback
4. Assert `isRecording == true`
5. Verify `mockVideoRecorder.prepare(any(), any(), any(), any())` was called

**`stopRecording without active recording returns failure`**
1. Call `controller.stopRecording { result -> ... }` with no prior startRecording
2. Assert callback receives `Result.failure` with FlutterError code `"invalid_state"`

**`teardown while recording emits error state and stops recorder`**
1. Inject mock `VideoRecorder`, stub `stop()` to succeed
2. Set `isRecording = true` via reflection
3. Call `controller.release()` (public wrapper that calls `teardown()`)
4. Drain the `mainHandler` (post a no-op and wait for it) to flush the `mainHandler.post` emission
5. Verify `mockFlutterApi.onRecordingStateChanged(1L, "error", any())` was called
6. Verify `mockVideoRecorder.stop()` was called

### Handler draining helper

`teardown()` posts the error state emission via `mainHandler.post { ... }`. The existing tests use `backgroundHandler.post { ... }` wait patterns via a `CountDownLatch`. A small helper `drainMainHandler()` using `mainHandler.post(latch::countDown)` followed by `latch.await(1, SECONDS)` will ensure the posted callbacks run before assertions.

---

## Files changed

| File | Change |
|------|--------|
| `pigeons/camera_api.dart` | Add `int? bitrate, int? fps` to `startRecording` |
| `lib/src/messages.g.dart` | Add bitrate/fps to send list and decode |
| `lib/src/cambrian_camera_controller.dart` | Add named params, forward to host API |
| `android/.../Messages.g.kt` | Decode two additional nullable Long args |
| `android/.../CambrianCameraPlugin.kt` | Forward bitrate/fps to controller |
| `android/.../CameraController.kt` | Accept and pass to `prepare()` |
| `android/.../CameraControllerGpuTest.kt` | Add 3 recording test cases |

`lib/main.dart` — no change (call site unchanged, defaults apply).

---

## Verification

1. **Bitrate/fps**: Call `camera.startRecording(bitrate: 10_000_000, fps: 60)` from Dart; verify logcat shows `prepare: ... bitrate=10000000 fps=60`.
2. **Defaults**: Call `camera.startRecording()` with no params; verify logcat shows `bitrate=50000000 fps=30`.
3. **Tests**: `./gradlew :cambrian_camera:testDebugUnitTest` — all three new tests pass.
