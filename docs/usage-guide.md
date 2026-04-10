# Cambrian Camera — Usage Guide

## Overview

`cambrian_camera` is a Flutter plugin that wraps Android's Camera2 API with a C++ native pipeline. It handles camera lifecycle, frame delivery, and error recovery automatically. The plugin is designed to be integrated into apps that need:

- Real-time camera preview with post-processing (brightness, contrast, black balance, etc.)
- High-resolution frame capture (4K or native sensor resolution)
- Multiple consumers receiving processed frames at different resolutions
- Automatic error recovery with exponential backoff

The preview is pixel-identical to the frames delivered to native consumers.

## Installation

Add `cambrian_camera` as a dependency in your app's `pubspec.yaml`:

```yaml
dependencies:
  cambrian_camera:
    path: ../packages/cambrian_camera  # adjust relative path
```

Your app also needs `permission_handler` (or equivalent) to request camera access at runtime:

```yaml
dependencies:
  permission_handler: ^12.0.1
```

### Android requirements

- `minSdk`: 33+
- Camera permission in `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-feature android:name="android.hardware.camera" android:required="true"/>
```

---

## Quick Start

```dart
import 'package:cambrian_camera/cambrian_camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';

// 1. Request permission
await Permission.camera.request();

// 2. Open camera (returns when streaming is active)
final camera = await CambrianCamera.open();

// 3. Show preview — build your own widget from the texture stream
child: StreamBuilder<CameraTextureInfo>(
  stream: camera.toneMappedTexture,
  builder: (context, snap) {
    if (!snap.hasData) return const ColoredBox(color: Colors.black);
    final t = snap.data!;
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: t.width.toDouble(),
        height: t.height.toDouble(),
        child: Texture(textureId: t.textureId),
      ),
    );
  },
),

// 4. Adjust settings
camera.updateSettings(CameraSettings(
  iso: AutoValue.manual(400),
  zoomRatio: 2.0,
));

// 5. Capture a still image
final path = await camera.captureNaturalPicture();

// 6. Record video
final (uri, name) = await camera.startRecording();
// ... recording in progress ...
await camera.stopRecording(); // file finalized and visible in gallery

// 7. Clean up
await camera.close();
```

---

## API Reference

### Opening and Closing

#### `CambrianCamera.open()`

```dart
static Future<CambrianCamera> open({
  String? cameraId,
  CameraSettings? settings,
  bool enableRawStream = false,
  int rawStreamHeight = 0,
})
```

Opens the camera and returns once it is actively streaming. This is the only way to create a `CambrianCamera` instance.

- `cameraId` — optional Camera2 device ID. Pass `null` to auto-select the default back-facing camera.
- `settings` — optional initial ISP settings applied before the first frame.
- `enableRawStream` — if `true`, allocates a second GPU render path (passthrough shader → rawFBO) that delivers unprocessed RGBA frames. Off by default; incurs additional GPU memory for rawFBO + rawPBOs.
- `rawStreamHeight` — height of the raw stream in pixels. The width is auto-computed from the camera's aspect ratio. Ignored when `enableRawStream` is `false`.

Throws `PlatformException` on failure (e.g., permission denied, no camera found). After opening, errors are delivered via `errorStream`.

If `enableRawStream` is `true` but raw initialization fails (e.g., insufficient GPU resources), the failure is logged, raw is silently disabled, and the processed pipeline continues normally. Check `capabilities.rawStreamWidth > 0` after `open()` to confirm raw is active.

```dart
try {
  final camera = await CambrianCamera.open();
  // camera is now streaming
} on PlatformException catch (e) {
  print('Failed to open camera: ${e.message}');
}
```

#### `camera.close()`

```dart
Future<void> close()
```

Closes the camera and releases all native resources. The instance must not be used after this call.

#### `camera.pause()` / `camera.resume()`

```dart
Future<void> pause()
Future<void> resume()
```

`pause()` tears down the capture session and GPU pipeline but keeps the `CameraDevice` open for fast restart. The camera state transitions to `CameraState.paused`. `resume()` restarts the capture session on the already-open device, transitioning through `opening` back to `streaming`.

- `pause()` is a no-op if the camera is not streaming.
- `resume()` is a no-op if the camera is not in the paused state (unless the app was backgrounded while paused — see below).
- Use these for **in-app navigation** (e.g. switching away from the camera screen while the app stays in the foreground).

**Background lifecycle is automatic.** You do **not** need to call `pause()`/`resume()` from `didChangeAppLifecycleState`. The plugin registers a `ProcessLifecycleOwner` observer that fully releases the camera device when the app goes to the background (`onStop`) and reopens it when the app returns (`onStart`). This ensures other apps can use the camera while yours is invisible.

If Dart calls `pause()` and the app then goes to background, the plugin remembers the Dart-paused intent. On foreground return, the camera is **not** automatically reopened — Dart must call `resume()` when it is ready for frames (e.g. when the user navigates back to the camera screen). `resume()` detects that the device was fully closed during the background cycle and performs a full reopen.

```dart
// In-app navigation example:
void onLeaveCameraScreen() {
  _camera?.pause();   // fast: session-only teardown
}
void onReturnToCameraScreen() {
  _camera?.resume();  // fast if app stayed foreground; full reopen if backgrounded
}
```

---

### Preview Streams

The library exposes texture streams as data primitives. Your app builds widgets from these primitives, giving you full control over layout, rotation, and display logic.

#### `camera.toneMappedTexture`

```dart
Stream<CameraTextureInfo> get toneMappedTexture
```

Emits a `CameraTextureInfo` describing the processed (color-corrected) preview stream each time the camera transitions to `streaming` state.

`CameraTextureInfo` contains:
- `textureId` — Flutter texture ID (pass to `Texture` widget)
- `width`, `height` — native pixel dimensions

```dart
StreamBuilder<CameraTextureInfo>(
  stream: camera.toneMappedTexture,
  builder: (context, snap) {
    if (!snap.hasData) {
      return const ColoredBox(color: Colors.black);
    }
    final t = snap.data!;
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: t.width.toDouble(),
        height: t.height.toDouble(),
        child: Texture(textureId: t.textureId),
      ),
    );
  },
)
```

#### `camera.rawTexture`

```dart
Stream<CameraTextureInfo> get rawTexture
```

Emits a `CameraTextureInfo` describing the raw (passthrough, unprocessed) preview stream. Only emits if `enableRawStream: true` was passed to `open()`.

The raw stream provides the camera image before any GPU shader adjustments (brightness, contrast, saturation, etc.). It is not Bayer RAW sensor data — it is the Camera2/SurfaceTexture output as-is, in RGBA. Useful for side-by-side debugging. Most apps only need `toneMappedTexture`.

```dart
// Only available if enableRawStream: true
StreamBuilder<CameraTextureInfo>(
  stream: camera.rawTexture,
  builder: (context, snap) {
    if (!snap.hasData) return const SizedBox.shrink();
    final t = snap.data!;
    return Texture(textureId: t.textureId);
  },
)
```

#### Device Rotation

Handle rotation via `WidgetsBindingObserver` and `getDisplayRotation()`. Use the `quarterTurnsFromDisplayRotation()` helper to convert degrees to `RotatedBox.quarterTurns`:

```dart
import 'package:cambrian_camera/cambrian_camera.dart' 
    show quarterTurnsFromDisplayRotation;

class _MyState extends State<MyWidget> with WidgetsBindingObserver {
  int _displayRotationDeg = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetchRotation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _fetchRotation();
  }

  Future<void> _fetchRotation() async {
    final deg = await CambrianCamera.getDisplayRotation();
    if (mounted) setState(() => _displayRotationDeg = deg);
  }

  int get _quarterTurns => quarterTurnsFromDisplayRotation(_displayRotationDeg);

  // Use _quarterTurns in RotatedBox wrapping your texture
}
```

---

### Camera Settings (ISP-Level)

#### `camera.updateSettings()`

```dart
Future<void> updateSettings(CameraSettings settings)
```

Updates per-frame Camera2 capture request parameters. Uses a **latest-value-wins** strategy: rapid calls (e.g., from slider scrubbing) don't queue up stale requests. Each call replaces any pending value.

**Only send the fields you want to change.** Null fields are ignored and their previous values are preserved on the native side. Settings accumulate across calls.

```dart
camera.updateSettings(CameraSettings(
  iso: AutoValue.manual(800),
  exposureTimeNs: AutoValue.manual(16666666),  // ~1/60s
  zoomRatio: 2.0,
));
```

#### `CameraSettings`

All fields are nullable. `null` means "don't change this setting."

**Auto-capable settings** use sealed types that make the three states explicit:

| Field | Type | States |
|-------|------|--------|
| `iso` | `AutoValue<int>?` | `null` = don't change, `AutoValue.auto()` = AE controls ISO, `AutoValue.manual(400)` = fixed value |
| `exposureTimeNs` | `AutoValue<int>?` | `null` = don't change, `AutoValue.auto()` = AE controls shutter, `AutoValue.manual(ns)` = fixed value |
| `focus` | `AutoValue<double>?` | `null` = don't change, `AutoValue.auto()` = continuous autofocus, `AutoValue.manual(diopters)` = fixed distance (0 = infinity) |
| `whiteBalance` | `WhiteBalance?` | `null` = don't change, `WhiteBalance.auto()` = AWB runs, `WhiteBalance.locked()` = freeze current, `WhiteBalance.manual(gainR, gainG, gainB)` = user gains |

**Non-auto settings** use plain nullable types:

| Field | Type | Description |
|-------|------|-------------|
| `zoomRatio` | `double?` | Zoom level (1.0 = no zoom). Null = don't change. |
| `noiseReductionMode` | `NoiseReductionMode?` | Camera2 noise reduction mode enum. Null = don't change. |
| `edgeMode` | `EdgeMode?` | Camera2 edge enhancement mode enum. Null = don't change. |
| `evCompensation` | `int?` | Exposure compensation in AE steps. **No effect when ISO or exposure is manual** (AE is disabled). Null = don't change. |

> **ISO + Exposure coupling:** `iso` and `exposureTimeNs` share a single Camera2 flag (`CONTROL_AE_MODE`: ON = both auto, OFF = both manual).
>
> - **Auto is contagious.** Setting either field to `AutoValue.auto()` propagates to the other automatically. You only need to set one:
>   ```dart
>   // Switches BOTH iso and exposureTimeNs to auto:
>   camera.updateSettings(CameraSettings(iso: AutoValue.auto()));
>   ```
> - **Manual latches from last AE values.** You only need to set one field to manual — the partner is automatically seeded from the last sensor value that AE was using, keeping brightness continuous. This is useful for ISO/exposure sliders:
>   ```dart
>   // Drag an ISO slider — exposureTimeNs fills in from the last AE value:
>   camera.updateSettings(CameraSettings(iso: AutoValue.manual(800)));
>   ```
>   You can still provide both explicitly for full control:
>   ```dart
>   camera.updateSettings(CameraSettings(
>     iso: AutoValue.manual(800),
>     exposureTimeNs: AutoValue.manual(16666666), // 1/60 s
>   ));
>   ```
>   If the camera has not yet delivered a capture result (just opened), single-field manual is rejected with `CameraErrorCode.settingsConflict`.
> - **Auto wins over manual in a mixed update.** If one field is `auto` and the other is `manual`, both switch to `auto`. This handles the UI slider case: moving the ISO slider to auto sends `{iso: auto, exposure: manual(lastValue)}` — the stale manual exposure value is correctly discarded.
>
> | Intent | Expression |
> |---|---|
> | Slide ISO to manual — exposure continuous | `CameraSettings(iso: AutoValue.manual(800))` |
> | Set both to specific values | `CameraSettings(iso: AutoValue.manual(800), exposureTimeNs: AutoValue.manual(...))` |
> | Switch back to auto | `CameraSettings(iso: AutoValue.auto())` — or either field; auto wins |
> | Mixed (one auto, one manual) | Both go to auto — auto wins |

#### Examples

```dart
// Slide ISO slider — exposure auto-fills from last AE value, brightness is continuous
camera.updateSettings(CameraSettings(iso: AutoValue.manual(800)));

// Or provide both explicitly if you want a specific shutter speed too
camera.updateSettings(CameraSettings(
  iso: AutoValue.manual(800),
  exposureTimeNs: AutoValue.manual(16666666), // 1/60 s
  focus: AutoValue.auto(),
));

// Switch iso back to auto — exposureTimeNs follows automatically
camera.updateSettings(CameraSettings(iso: AutoValue.auto()));

// Switch to full auto (explicit; equivalent to the line above for iso+exposure)
camera.updateSettings(CameraSettings(
  iso: AutoValue.auto(),
  exposureTimeNs: AutoValue.auto(),
  focus: AutoValue.auto(),
  whiteBalance: WhiteBalance.auto(),
));

// Lock white balance, change nothing else
camera.updateSettings(CameraSettings(
  whiteBalance: WhiteBalance.locked(),
));

// Manual white balance from a calibration patch
camera.updateSettings(CameraSettings(
  whiteBalance: WhiteBalance.manual(gainR: 1.82, gainG: 1.0, gainB: 1.45),
));

// Just change zoom — all other settings are preserved
camera.updateSettings(CameraSettings(zoomRatio: 3.0));
```

---

### Processing Parameters (C++ Pipeline)

#### `camera.setProcessingParams()`

```dart
void setProcessingParams(ProcessingParams params)
```

Updates the C++ post-processing pipeline. **Fire-and-forget** — the next frame picks up the new values. No queuing or serialization is applied.

Currently **saturation** is the only parameter applied per-frame. The remaining fields (black balance, gamma, histogram stretch, brightness) are stored and will be wired incrementally.

#### `ProcessingParams`

All fields have sensible defaults (identity/no-op).

| Field | Type | Default | Range | Description |
|-------|------|---------|-------|-------------|
| `blackR` | `double` | 0.0 | [0.0, 0.5] | Red channel black level subtraction |
| `blackG` | `double` | 0.0 | [0.0, 0.5] | Green channel black level subtraction |
| `blackB` | `double` | 0.0 | [0.0, 0.5] | Blue channel black level subtraction |
| `gamma` | `double` | 1.0 | [0.1, 4.0] | Gamma correction (1.0 = identity) |
| `brightness` | `double` | 0.0 | [-1.0, 1.0] | Brightness offset |
| `saturation` | `double` | 1.0 | [0, 3] | Saturation multiplier (1.0 = identity) |

```dart
camera.setProcessingParams(ProcessingParams(
  gamma: 1.2,
  brightness: 0.1,
  saturation: 1.3,
));
```

#### `camera.getPersistedProcessingParams()`

```dart
Future<ProcessingParams?> getPersistedProcessingParams()
```

Returns processing params persisted from a previous session, or `null` on first run. Call this after `open()` to initialize your UI (e.g. slider positions) with the user's last-known values instead of sending default zeros that would overwrite the persisted state.

```dart
final camera = await CambrianCamera.open();
final persisted = await camera.getPersistedProcessingParams();
final params = persisted ?? ProcessingParams();
await camera.setProcessingParams(params);
// Initialize slider UI with `params`
```

See [Settings Persistence](#settings-persistence) for full details.

---

### Still Capture

There are two capture methods with different trade-offs:

| Method | Source | Post-processing | Format | Quality |
|--------|--------|-----------------|--------|---------|
| `captureNaturalPicture()` | Camera2 hardware ISP | None | JPEG | Highest (hardware encoder) |
| `captureImage()` | GPU post-processed pipeline | Full (LUT, color, gamma…) | JPEG or PNG | Good (software encoder) |

#### `camera.captureNaturalPicture()`

```dart
Future<String> captureNaturalPicture()
```

Captures a JPEG still image using Camera2's hardware ISP ImageReader. Returns the absolute file path. Does **not** interrupt the streaming pipeline.

**Important:** This method bypasses the GPU post-processing pipeline. The resulting image reflects raw ISP output — no LUT, color transforms (saturation, contrast, brightness, black-level, gamma) are applied. Use this when you need the highest-fidelity hardware-encoded JPEG.

```dart
final path = await camera.captureNaturalPicture();
// path is something like /data/.../cache/capture_1711929600000.jpg
```

#### `camera.captureImage()`

```dart
Future<String> captureImage({String? outputDirectory, String? fileName})
```

Captures the GPU post-processed frame (exactly what the user sees on screen) from the C++ pipeline. Encodes as JPEG or PNG and writes EXIF metadata (ISO, exposure, focal length, aperture, WB gains, orientation, timestamp).

- **Format:** inferred from `fileName` extension (`.jpg`/`.jpeg` → JPEG quality 90, else → PNG)
- **Default directory:** app-specific Pictures folder (no storage permission needed on API 33+)
- **Default filename:** `capture_<timestamp>.png`

```dart
// Save as PNG (default)
final path = await camera.captureImage();

// Save as JPEG with a specific name
final path = await camera.captureImage(fileName: 'my_photo.jpg');

// Save to a custom directory as PNG
final path = await camera.captureImage(
  outputDirectory: '/sdcard/MyApp/captures',
  fileName: 'frame_001.png',
);
```

---

### Video Recording

#### `camera.startRecording()`

```dart
Future<(String, String)> startRecording({
  String? outputDirectory,
  String? fileName,
  int? bitrate,
  int? fps,
})
```

Starts encoding to an MP4 file. Returns `(contentUri, displayName)` where `contentUri` is the MediaStore content URI and `displayName` is the file name (e.g. `cambrian_1712345678.mp4`).

| Parameter | Default | Description |
|---|---|---|
| `outputDirectory` | `Movies/CambrianCamera/` | MediaStore `RELATIVE_PATH` (e.g. `Movies/MyApp/`) |
| `fileName` | `cambrian_<timestamp>` | File name without extension; `.mp4` appended automatically |
| `bitrate` | `50000000` (50 Mbps) | Target encoder bitrate in bits per second |
| `fps` | `30` | Target encoder frame rate |

```dart
// Minimal
final (uri, name) = await camera.startRecording();

// Custom location, name, and encoding parameters
final (uri, name) = await camera.startRecording(
  outputDirectory: 'Movies/MyApp/',
  fileName: 'session_01',  // saved as session_01.mp4
  bitrate: 8_000_000,      // 8 Mbps
  fps: 24,
);
```

When recording starts, Camera2 switches from `TEMPLATE_PREVIEW` to `TEMPLATE_RECORD` for video-optimised capture settings. The AE target fps range upper bound is set to match the configured encoder fps (default 30), while the lower bound is half of that — this gives AE headroom to extend exposure in dark scenes rather than underexposing, while keeping the upper bound frame-aligned with the encoder. Both the template and fps range revert automatically when `stopRecording()` is called. The file is written continuously via a MediaCodec drain thread; it remains hidden in MediaStore (`IS_PENDING=1`) until `stopRecording()` finalizes it. If manual ISO or exposure time is active when `startRecording()` is called, the AE fps-range adjustment is skipped because AE is disabled; the encoder receives frames at the camera's current capture rate.

**Throws** `PlatformException` if:
- Already recording (call `stopRecording()` first)
- Encoder initialization fails
- MediaStore entry creation fails (insufficient storage or scoped-storage permission denied)

#### `camera.stopRecording()`

```dart
Future<String> stopRecording()
```

Signals end-of-stream to the encoder, waits for the drain thread to flush, writes the `moov` atom, and marks the MediaStore entry as `IS_PENDING=0` — making the file visible in the gallery. Returns the finalized content URI. Camera2 reverts to `TEMPLATE_PREVIEW` automatically.

```dart
final uri = await camera.stopRecording();
// file is fully written and visible in gallery
```

**Throws** `PlatformException` if:
- Not currently recording
- File finalization fails (disk full, I/O error during `moov` write)

On error the MediaStore entry is deleted (no partial file is left as `IS_PENDING=1`). Camera2 still reverts to `TEMPLATE_PREVIEW`.

#### `camera.recordingStateStream`

```dart
Stream<RecordingState> get recordingStateStream
```

Broadcasts recording lifecycle changes.

| State | When |
|---|---|
| `RecordingState.recording` | Encoder is active; file is being written |
| `RecordingState.idle` | Recording stopped; file is finalized |
| `RecordingState.error` | Start or stop failed |

`RecordingState.error` is emitted when:
- Encoder initialization fails during `startRecording()`
- A file I/O error (e.g., disk full) occurs during recording
- `stopRecording()` finalization fails

When an error occurs, the recording is automatically stopped and the state transitions to `idle` on the next successful operation. Detailed error information is available via `camera.errorStream`. The app can retry by calling `startRecording()` again.

```dart
camera.recordingStateStream.listen((state) {
  switch (state) {
    case RecordingState.recording:
      print('Recording…');
    case RecordingState.idle:
      print('File saved');
    case RecordingState.error:
      print('Recording failed');
      // Retry or surface error to user; check camera.errorStream for details.
  }
});
```

---

### State and Error Streams

#### `camera.stateStream`

```dart
Stream<CameraState> get stateStream
```

Broadcasts camera lifecycle state changes. Use `camera.state` for the current value (avoids `StreamBuilder` initial-data race conditions).

```dart
camera.stateStream.listen((state) {
  switch (state) {
    case CameraState.streaming:
      print('Camera is live');
    case CameraState.recovering:
      print('Camera is recovering from an error...');
    case CameraState.error:
      print('Fatal error — close and reopen');
    default:
      break;
  }
});
```

#### `CameraState`

| Value | Description |
|-------|-------------|
| `closed` | Camera is not open |
| `opening` | Initializing (opening device, configuring session) |
| `streaming` | Actively delivering frames |
| `recovering` | Non-fatal error occurred; auto-recovering with exponential backoff |
| `paused` | Dart-initiated pause (in-app navigation). Session torn down, device still held. Call `resume()` to restart |
| `suspended` | App moved to background. Camera device fully released so other apps can use it. Automatically reopens on foreground return (unless Dart-paused) |
| `error` | Fatal error, or retries exhausted. Automatically recovers when the camera becomes available again (via `AvailabilityCallback`). Call `close()` to give up permanently |

#### `camera.errorStream`

```dart
Stream<CameraError> get errorStream
```

Broadcasts camera errors. Check `isFatal` to determine severity.

```dart
camera.errorStream.listen((error) {
  if (error.isFatal) {
    // Must close camera. Show error UI.
    showDialog(...);
    camera.close();
  } else {
    // Informational — camera is auto-recovering.
    showSnackBar('Reconnecting: ${error.message}');
  }
});
```

#### `CameraError`

| Field | Type | Description |
|-------|------|-------------|
| `code` | `CameraErrorCode` | Error type (see enum below) |
| `message` | `String` | Human-readable description |
| `isFatal` | `bool` | `false` = auto-recovering, `true` = requires close/reopen |

#### `CameraErrorCode`

| Code | Fatal? | Description |
|------|--------|-------------|
| `cameraDevice` | No | Hardware camera error (transient) |
| `cameraService` | No | Android camera service error (transient) |
| `cameraDisconnected` | No | Camera disconnected (USB, system reclaim) |
| `cameraInUse` | No | Another app currently holds the camera |
| `cameraAccessError` | No | Transient `CameraAccessException` from the OS |
| `configurationFailed` | No | Session configuration failed |
| `previewSurfaceLost` | No | Flutter surface recycled |
| `pipelineError` | No | C++ processing error |
| `settingsConflict` | No | Invalid settings combination — see note below |
| `frameStall` | No | GPU pipeline stopped receiving frames (>3 s with no frame) |
| `captureFailure` | No | HAL reported 5+ consecutive `REASON_ERROR` failures; recovery triggered automatically |
| `fpsDegraded` | No | Sustained FPS below 15 for 3+ consecutive heartbeat intervals (~3 s) |
| `aeConvergenceTimeout` | No | Auto-exposure stuck in `SEARCHING` for >5 s |
| `recordingTruncated` | No | EOS drain timed out during `stopRecording()`; saved file may be incomplete |
| `permissionDenied` | **Yes** | Camera permission revoked |
| `cameraDisabled` | **Yes** | Camera disabled by system policy |
| `maxCamerasInUse` | **Yes** | Too many cameras open in the system |
| `maxRetriesExceeded` | **Yes** | Auto-recovery gave up after 5 retries |
| `unknown` | No | Unclassified error (treat as transient) |

> **`settingsConflict`:** Sent when a single-field manual ISO or exposure update is
> rejected because the camera has not yet delivered a capture result (no AE seed
> available). This can happen if `updateSettings()` is called with
> `AutoValue.manual(...)` immediately after `open()`, before the first frame arrives.
>
> **Mitigation:** Wait for at least one non-null `iso` + `exposureTimeNs` pair from
> `frameResultStream` before allowing manual AE control. On conflict, revert the UI
> back to auto:
>
> ```dart
> bool _aeSeeded = false;
>
> camera.frameResultStream.listen((result) {
>   if (!_aeSeeded && result.iso != null && result.exposureTimeNs != null) {
>     setState(() => _aeSeeded = true);
>   }
>   // ... update sliders ...
> });
>
> camera.errorStream.listen((error) {
>   if (error.code == CameraErrorCode.settingsConflict) {
>     // Revert UI to auto — the camera rejected the manual update
>     setState(() { isIsoAuto = true; isExposureAuto = true; });
>   }
> });
>
> void onIsoSliderChanged(int iso) {
>   if (!_aeSeeded) return;  // guard: no AE seed yet
>   camera.updateSettings(CameraSettings(iso: AutoValue.manual(iso)));
> }
> ```

#### `camera.frameResultStream`

```dart
Stream<FrameResult> get frameResultStream
```

Broadcasts actual sensor values reported by the camera hardware after each captured frame. Emits approximately **3 times per second** (every 10th capture result, throttled in native code).

Use this to keep UI controls — sliders, readouts, overlays — in sync with what the hardware is actually doing. Particularly useful in auto modes, where the hardware is constantly adjusting ISO, exposure, and focus without any app input.

```dart
camera.frameResultStream.listen((result) {
  print('ISO: ${result.iso}');
  print('Exposure: ${result.exposureTimeNs} ns');
  print('Focus: ${result.focusDistanceDiopters} dpt');
});
```

#### `FrameResult`

All fields are nullable — `null` means the hardware did not report that value for this frame (e.g., `focusDistanceDiopters` is null on fixed-focus cameras).

| Field | Type | Description |
|-------|------|-------------|
| `iso` | `int?` | Actual sensor sensitivity (ISO) used for this frame |
| `exposureTimeNs` | `int?` | Actual exposure duration in nanoseconds |
| `focusDistanceDiopters` | `double?` | Actual focus distance in diopters (0.0 = infinity) |
| `wbGainR` | `double?` | Red channel gain from `COLOR_CORRECTION_GAINS` |
| `wbGainG` | `double?` | Green channel gain (average of greenEven + greenOdd) |
| `wbGainB` | `double?` | Blue channel gain from `COLOR_CORRECTION_GAINS` |

> **Relationship to `updateSettings`:** `FrameResult` reports what the hardware *did*, not what was *requested*. In auto modes the values reflect what the AE/AF algorithms chose. In manual mode the hardware value should match your request within 1–2 frames.

#### Typical pattern: auto-mode slider feedback

In auto mode, update the slider position from the stream. Stop updating as soon as the user touches the slider (which switches to manual mode):

```dart
camera.frameResultStream.listen((result) {
  // Only update while the camera is running auto-exposure
  if (isIsoAuto && result.iso != null) {
    setState(() => currentIso = result.iso!);
  }
  if (isExposureAuto && result.exposureTimeNs != null) {
    setState(() => currentExposureNs = result.exposureTimeNs!);
  }
});

// When the user drags the ISO slider:
void onIsoSliderChanged(int iso) {
  setState(() {
    isIsoAuto = false;   // stop stream updates for ISO
    currentIso = iso;
  });
  camera.updateSettings(CameraSettings(iso: AutoValue.manual(iso)));
}
```

---

### Device Capabilities

#### `camera.capabilities`

```dart
CameraCapabilities get capabilities
```

Available after `open()`. Reports device hardware limits.

```dart
final caps = camera.capabilities;
print('ISO range: ${caps.isoMin}–${caps.isoMax}');
print('Zoom range: ${caps.zoomMin}–${caps.zoomMax}x');
print('Resolutions: ${caps.supportedSizes}');
```

#### `CameraCapabilities` fields

| Field | Type | Description |
|-------|------|-------------|
| `supportedSizes` | `List<CameraSize>` | Available resolutions (largest first) |
| `isoMin` / `isoMax` | `int` | Sensor sensitivity range |
| `exposureTimeMinNs` / `exposureTimeMaxNs` | `int` | Exposure time range (nanoseconds) |
| `focusMin` / `focusMax` | `double` | Focus distance range in diopters (0 = infinity) |
| `zoomMin` / `zoomMax` | `double` | Zoom ratio range |
| `evCompMin` / `evCompMax` | `int` | EV compensation range (in steps) |
| `evCompensationStep` | `double` | Size of one EV step |
| `yuvStreamWidth` / `yuvStreamHeight` | `int` | YUV stream dimensions delivered to the C++ pipeline (pixels). Used by the preview widget for correct aspect ratio. |
| `rawStreamTextureId` | `int` | Flutter texture ID for the raw (passthrough) preview stream. `0` when raw is disabled. Available via `rawTexture` stream. |
| `rawStreamWidth` / `rawStreamHeight` | `int` | Raw stream dimensions in pixels. Both are `0` when raw is disabled (either `enableRawStream` was `false`, or raw init failed). Width is auto-computed from aspect ratio; height matches the `rawStreamHeight` passed to `open()`. |

---

### Native Consumer API (C++)

For apps that need direct access to processed frames in C++ (e.g., real-time computer vision, image stitching), the plugin provides a generic consumer sink model. Your app registers C++ callbacks (`SinkCallback`) that receive post-processed BGR `SinkFrame` objects — the same pixels shown in the preview. Each sink uses a 1-slot mailbox (latest-frame-wins) with its own dispatch thread, so slow consumers don't stall the preview. The `SinkFrame` pixel buffer is valid only for the duration of the callback; copy the data if you need it beyond that scope.

#### Step 1: Get the pipeline handle from Dart

```dart
Future<int> getNativePipelineHandle()
```

Returns the native `IImagePipeline*` pointer as an int64. Call this after `open()` returns.

```dart
final camera = await CambrianCamera.open();
final pipelinePtr = await camera.getNativePipelineHandle();
// pipelinePtr is now a non-zero int64 you can pass to native code
```

#### Step 2: Pass the handle to your native code

There are two ways to get the pointer into your C++ consumer code:

**Option A — Dart FFI (recommended for pure-Dart apps):**

```dart
// In your app's Dart code
import 'dart:ffi';

// Declare your native registration function
typedef RegisterConsumersNative = Void Function(Int64 pipelinePtr);
typedef RegisterConsumersDart = void Function(int pipelinePtr);

final dylib = DynamicLibrary.open('libmy_app.so');
final registerConsumers = dylib
    .lookupFunction<RegisterConsumersNative, RegisterConsumersDart>(
        'registerConsumers');

// Call it with the handle from the plugin
final ptr = await camera.getNativePipelineHandle();
registerConsumers(ptr);
```

**Option B — Link directly against `libcambrian_camera.so`:**

Your app's `CMakeLists.txt` links against the camera library's shared object:

```cmake
# Application CMakeLists.txt
find_library(cambrian-camera cambrian_camera)
target_link_libraries(my_app ${cambrian-camera})
target_include_directories(my_app PRIVATE ${cambrian_camera_INCLUDE_DIR})
```

Then use `cam::getPipeline()` from C++ directly (no Dart pointer needed).

#### Step 3: Register consumer sinks in C++

Include the public header `cambrian_camera_native.h` and register sinks. Each sink receives full-resolution processed BGR frames independently via a dedicated dispatch thread.

```cpp
// In your application's native library (e.g., my_consumers.cpp)
#include <cambrian_camera_native.h>

// Called from Dart FFI or JNI with the pipeline pointer
extern "C" void registerConsumers(int64_t pipelinePtr) {
    auto* pipeline = reinterpret_cast<cam::IImagePipeline*>(
            static_cast<uintptr_t>(pipelinePtr));
    if (!pipeline) return;

    // ── Consumer 1: Full-resolution BGR for stitching ──────────────
    cam::SinkConfig stitchCfg;
    stitchCfg.name = "stitcher";

    pipeline->addSink(stitchCfg, [](const cam::SinkFrame& frame) {
        // frame.data    → pixel buffer (row-major BGR, CV_8UC3)
        // frame.width   → image width in pixels
        // frame.height  → image height in pixels
        // frame.stride  → row stride in bytes (may exceed width * 3)
        // frame.format  → cam::PixelFormat::BGR
        // frame.frameId → monotonic frame counter
        // frame.meta    → sensor metadata (timestamp, ISO, exposure)
        //
        // data is valid only for the duration of this callback.
        // Copy it if you need it longer.
        processForStitching(frame.data, frame.width, frame.height, frame.stride);
    });

    // ── Consumer 2: Second BGR sink for tracking ────────────────────
    cam::SinkConfig trackCfg;
    trackCfg.name = "tracker";

    pipeline->addSink(trackCfg, [](const cam::SinkFrame& frame) {
        runTrackingAlgorithm(frame.data, frame.width, frame.height);
    });
}

// Called when your app no longer needs the consumers
extern "C" void unregisterConsumers(int64_t pipelinePtr) {
    auto* pipeline = reinterpret_cast<cam::IImagePipeline*>(
            static_cast<uintptr_t>(pipelinePtr));
    if (!pipeline) return;

    pipeline->removeSink("stitcher");  // blocks until dispatch thread exits
    pipeline->removeSink("tracker");
}
```

#### `SinkRole` reference

Sinks are routed by role, controlling which frame path they receive. Pass `role` in `SinkConfig`:

| Role | Default? | Frame source | Pixel format | Description |
|------|----------|-------------|--------------|-------------|
| `SinkRole::FULL_RES` | yes | processedFBO | RGBA | Full-resolution color-processed frames (default for all sinks) |
| `SinkRole::TRACKER` | — | processedFBO | RGBA | Same processed frames, typically registered at lower resolution |
| `SinkRole::RAW` | — | rawFBO | RGBA | Passthrough frames — no shader adjustments applied. Camera2/SurfaceTexture output as-is in RGBA. Only available when `enableRawStream: true`. |

`SinkRole::RAW` sinks receive frames from the raw render path at `rawStreamHeight` resolution. Register a `RAW` sink only when the raw stream is enabled; frames will not be delivered if raw was disabled at `open()` time.

```cpp
cam::SinkConfig rawCfg;
rawCfg.name = "raw_consumer";
rawCfg.role = cam::SinkRole::RAW;  // receives passthrough RGBA from rawFBO

pipeline->addSink(rawCfg, [](const cam::SinkFrame& frame) {
    // frame.data  → bit-exact RGBA, no processing applied
    // frame.width / frame.height → rawStreamWidth / rawStreamHeight
    saveRawFrame(frame.data, frame.width, frame.height, frame.stride);
});
```

#### `SinkConfig` reference

| Field | Type | Description |
|-------|------|-------------|
| `name` | `std::string` | Unique identifier for this sink. Used as the key for `removeSink()`. |
| `role` | `SinkRole` | Which frame path this sink receives. Default: `SinkRole::FULL_RES`. Use `SinkRole::RAW` for passthrough frames. |

#### `SinkFrame` reference

| Field | Type | Description |
|-------|------|-------------|
| `data` | `const uint8_t*` | Pixel buffer pointer (row-major). Valid only for the duration of the callback. |
| `width` | `int` | Frame width in pixels |
| `height` | `int` | Frame height in pixels |
| `stride` | `int` | Row stride in bytes (may exceed `width * 3` due to OpenCV alignment) |
| `format` | `PixelFormat` | Pixel layout — `PixelFormat::BGR` for external sinks |
| `frameId` | `uint64_t` | Monotonic frame counter |
| `meta` | `FrameMetadata` | Per-frame sensor metadata |

#### `FrameMetadata` reference

| Field | Type | Description |
|-------|------|-------------|
| `frameNumber` | `int64_t` | Monotonically increasing frame counter |
| `sensorTimestampNs` | `int64_t` | Sensor capture start time (monotonic clock, same as IMU) |
| `exposureTimeNs` | `int64_t` | Actual exposure duration in nanoseconds |
| `iso` | `int32_t` | Sensor sensitivity (ISO equivalent) |

> **Note:** The fields listed above (`frameNumber`, `sensorTimestampNs`, `exposureTimeNs`, `iso`) are already populated by `nativeDeliverYuv` from JNI parameters. Additional `FrameMetadata` fields that may be added in the future are not yet wired from Camera2 capture results and will remain zero until that plumbing is implemented.

#### Lifetime and threading rules

- **`frame.data` is valid only for the duration of the callback.** The ring buffer slot is recycled when the callback returns. Copy the data if you need it longer.
- **Each sink has a dedicated dispatch thread.** Callbacks run on per-sink threads, not the pipeline's frame-processing thread, so a slow callback does not stall the preview or other sinks.
- **`addSink()` / `removeSink()` are thread-safe.** You can register or remove sinks at any time, even while streaming.
- **`removeSink()` blocks** until the sink's dispatch thread exits (including any in-flight callback and queued frames), so it is safe to free resources immediately after it returns.

#### Memory budget

Processed frames are shared across all consumers via `shared_ptr` — there is only one BGR allocation per frame regardless of the number of registered sinks. Each sink holds at most one pending frame at a time (latest-frame-wins mailbox).

Memory per frame (BGR, 3 bytes/pixel):

```
width * height * 3 bytes per frame × (up to consumers + 1 in-flight) frames
```

Example at 4K (4160×3120, as reported by `yuvStreamWidth`/`yuvStreamHeight`):

| Allocation | Size |
|-----------|------|
| Input ring (4 YUV slots, Y+UV) | ~78 MB |
| Per-frame BGR (shared across all consumers) | ~37 MB |
| Preview RGBA conversion buffer | ~49 MB |

> **Tip:** Keep sink callbacks fast. Each sink has a dedicated dispatch thread and a 1-slot mailbox — a slow callback causes frames to be dropped, not queued.

---

## Complete Integration Example

```dart
import 'package:cambrian_camera/cambrian_camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class MyCameraScreen extends StatefulWidget {
  const MyCameraScreen({super.key});

  @override
  State<MyCameraScreen> createState() => _MyCameraScreenState();
}

class _MyCameraScreenState extends State<MyCameraScreen> {
  CambrianCamera? _camera;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _error = 'Camera permission denied');
      return;
    }

    try {
      final camera = await CambrianCamera.open();

      // Listen for errors
      camera.errorStream.listen((error) {
        if (error.isFatal) {
          setState(() => _error = error.message);
          camera.close();
        }
      });

      setState(() => _camera = camera);
    } on PlatformException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  void dispose() {
    _camera?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(child: Text('Error: $_error'));
    }

    final camera = _camera;
    if (camera == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // Live preview
        Expanded(
          child: StreamBuilder<CameraTextureInfo>(
            stream: camera.toneMappedTexture,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final t = snap.data!;
              return FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: t.width.toDouble(),
                  height: t.height.toDouble(),
                  child: Texture(textureId: t.textureId),
                ),
              );
            },
          ),
        ),

        // Controls
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ElevatedButton(
              onPressed: () => camera.updateSettings(
                CameraSettings(
                  iso: AutoValue.auto(),
                  exposureTimeNs: AutoValue.auto(),
                  focus: AutoValue.auto(),
                  whiteBalance: WhiteBalance.auto(),
                  zoomRatio: 1.0,
                ),
              ),
              child: const Text('Reset'),
            ),
            ElevatedButton(
              onPressed: () async {
                final path = await camera.captureNaturalPicture();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Saved: $path')),
                  );
                }
              },
              child: const Text('Capture'),
            ),
          ],
        ),
      ],
    );
  }
}
```

---

## Architecture at a Glance

```
Dart: CambrianCamera
  |  (Pigeon type-safe interface)
Kotlin: CambrianCameraPlugin
  |  (delegates to)
Kotlin: CameraController
  |  (Camera2 lifecycle, ISP settings, auto-recovery)
  |
  |  Camera2 capture request targets only the YUV ImageReader.
  |  The SurfaceProducer is NOT a Camera2 session output — the
  |  C++ pipeline is the sole producer for the Flutter Texture.
  |
  |  (JNI: nativeDeliverYuv → OES texture upload)
C++: GpuRenderer / ImagePipeline
  |
  |  Camera2 → SurfaceTexture → OES texture
  |    ├── [color shader]       → processedFBO → preview surface + FULL_RES/TRACKER sinks
  |    └── [passthrough shader] → rawFBO(rawH) → raw preview surface + RAW sinks
  |         (only when enableRawStream: true)
  |
  +-> ANativeWindow (Flutter processed preview)
  +-> ANativeWindow (Flutter raw preview, when raw enabled)
  +-> FULL_RES / TRACKER sinks (per-sink mailbox + dispatch thread, processed RGBA)
  +-> RAW sinks (passthrough RGBA at rawStreamHeight resolution)
```

**Processed frame path:** Camera2 → OES texture → color shader → processedFBO → preview surface + FULL_RES/TRACKER sinks

**Raw frame path (optional):** OES texture → passthrough shader → rawFBO → raw preview surface + RAW sinks

**Surface ownership invariant:** A BufferQueue surface can only have one producer. Camera2 session outputs claim surfaces via `connect(NATIVE_WINDOW_API_CAMERA)`. `ANativeWindow_lock` claims via `connect(NATIVE_WINDOW_API_CPU)`. The preview surface must be in one or the other — never both. In the current architecture, the C++ pipeline owns it.

The plugin manages everything below the Dart API line. Your app interacts only with `CambrianCamera` and optionally registers C++ consumers via the native pipeline handle.

---

## Auto-Recovery

The plugin handles transient camera errors internally:

1. Non-fatal error detected (device error, disconnect, config failure, camera in use)
2. State transitions to `recovering` (visible via `stateStream`)
3. Resources torn down, then retry with exponential backoff (500ms, 1s, 2s, 4s, 8s)
4. After 5 failed retries, state transitions to `error`
5. When the camera becomes available again (e.g. phone call ends, other app releases it), a `CameraManager.AvailabilityCallback` automatically triggers a fresh recovery from `error` — no app restart needed

Your app does not need to implement retry logic. Just listen to `stateStream` and show appropriate UI feedback during `recovering`. Even `error` state is not permanent — the plugin recovers automatically when the camera hardware is free.

The only truly fatal error is `ERROR_CAMERA_DISABLED` (device policy / MDM), which requires admin intervention.

---

## Settings Update Strategies

The plugin uses two different strategies depending on the parameter type:

**CameraSettings (ISP)** — Latest-value-wins serializer with server-side accumulation. Each update requires a Dart-to-Kotlin-to-Camera2 round trip. If a new value arrives while the previous is in-flight, the old pending value is replaced (not queued). On the Kotlin side, incoming non-null fields are merged into the accumulated settings state — omitted (null) fields retain their previous values. This means you only need to send the fields you want to change.

**ProcessingParams (C++ pipeline)** — Fire-and-forget. A direct pass-through to native code. The next frame picks up the new values atomically. No queuing.

You can safely call `updateSettings()` on every slider tick without worrying about request accumulation or losing other settings.

---

## App Lifecycle

The plugin automatically manages the camera across all Android lifecycle transitions. **No manual lifecycle code is needed in your app.**

### What happens automatically

| Event | Plugin behavior | State emitted |
|-------|----------------|---------------|
| Home button / task switch / screen lock | Full `CameraDevice` close (other apps can use camera) | `suspended` |
| App returns to foreground | Full device reopen with previous settings | `opening` → `streaming` |
| Incoming call preempts camera | Recovery retries with backoff; `AvailabilityCallback` recovers from `error` | `recovering` → `error` → `opening` |
| Another app takes camera (multi-window) | Same as incoming call | `recovering` → `error` → `opening` |
| OS kills app for memory | Kernel reclaims resources; no leak | (fresh start) |
| Screen rotation | Camera stays alive (ProcessLifecycleOwner ignores config changes) | (no change) |

### Dart-paused + background round-trip

If your app calls `pause()` (e.g. user navigated to a settings screen) and the app then goes to background:

1. The plugin fully closes the camera device (emits `suspended`)
2. On foreground return, the plugin sees Dart had paused — it does **not** reopen
3. When Dart calls `resume()`, a full reopen happens automatically

This prevents wasteful streaming to a screen the user isn't looking at.

### What your app should do

- Listen to `stateStream` for UI feedback (show "Camera paused" overlay during `suspended`, "Reconnecting..." during `recovering`)
- Use `pause()` / `resume()` only for in-app navigation (leave/return to camera screen)
- Do **not** call `pause()`/`resume()` from `didChangeAppLifecycleState` — the plugin handles this

---

## Settings Persistence

Both `CameraSettings` (ISP parameters) and `ProcessingParams` (GPU shader adjustments) are automatically persisted to `SharedPreferences` on every change. This means:

- Settings survive a full process kill (OS reclaims memory, user force-stops the app)
- On the next app start, `open()` restores the persisted ISP settings (zoom, focus mode, exposure mode, WB, etc.) and applies them to the first `CaptureRequest`
- Processing params (brightness, contrast, saturation, gamma, black levels) are also restored

### Restoring processing params in your UI

After `open()`, call `getPersistedProcessingParams()` to get the user's last-known values. Use these to initialize your slider UI:

```dart
final camera = await CambrianCamera.open(settings: myInitialSettings);

// Restore persisted GPU params (or use defaults on first run).
final persisted = await camera.getPersistedProcessingParams();
final params = persisted ?? ProcessingParams();
await camera.setProcessingParams(params);

setState(() {
  _processingParams = params;  // sliders show correct values
});
```

If you skip this step and send `ProcessingParams()` (all defaults), the persisted values are overwritten and the user's adjustments are lost.

### ISP settings persistence

ISP settings (`CameraSettings`) are persisted and restored automatically inside `open()`. The incoming settings from Dart are merged with persisted values: incoming non-null fields take priority, persisted values fill in unspecified fields.

---

## Debugging

### Log filtering

All plugin log tags share a `CC/` prefix. Filter with:

```bash
adb logcat | grep "CC/"
```

Key tags: `CC/Cam` (camera lifecycle, capture failures), `CC/3A` (3A state + heartbeat), `CC/Gpu` (GPU pipeline), `CC/Dart` (Dart layer, debug builds only).

### Runtime log-level toggling

Increase log verbosity in the field without rebuilding by sending an ADB broadcast:

```bash
adb shell am broadcast -a com.cambrian.camera.SET_LOG_LEVEL --ei level 2
```

| Level | Effect |
|-------|--------|
| 0 | Quiet — errors and lifecycle transitions only |
| 1 | Default — adds `verboseSettings` and `verboseDiagnostics` (3A heartbeat every 30 frames) |
| 2 | Verbose — adds `debugDataFlow` (C++ perf logs, GPU frame counter) |
| 3 | Full — adds `verboseFullResult` (full `TotalCaptureResult` dump every 30 frames) |

**Limitation:** Runtime toggling takes effect immediately for Kotlin-side logging (CameraController, GpuPipeline). C++ components (`ImagePipeline`, `GpuRenderer`) receive their log level once at pipeline construction; changing the level after construction has no effect on C++ output. To change C++ log verbosity, restart the pipeline (`close()` then `open()` on `CambrianCamera`).

### Diagnostic string representations

`CameraSettings` and `ProcessingParams` both implement `toString()` that summarizes non-null / non-identity fields. These appear automatically in `CC/Dart` log lines:

```
CC/Dart: updateSettings handle=1 CameraSettings(iso=manual(400), focus=auto)
CC/Dart: setProcessingParams handle=1 ProcessingParams(black=[0.0,0.0,0.0] gamma=1.2 brightness=0.1 contrast=0.0 saturation=0.0)
```
