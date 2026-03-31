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

// 1. Request permission
await Permission.camera.request();

// 2. Open camera (returns when streaming is active)
final camera = await CambrianCamera.open();

// 3. Show preview — use the returned Widget in your widget tree
child: camera.buildPreview(fit: BoxFit.cover),

// 4. Adjust settings
camera.updateSettings(CameraSettings(
  iso: AutoValue.manual(400),
  zoomRatio: 2.0,
));

// 5. Capture a still image
final path = await camera.takePicture();

// 6. Clean up
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
})
```

Opens the camera and returns once it is actively streaming. This is the only way to create a `CambrianCamera` instance.

- `cameraId` — optional Camera2 device ID. Pass `null` to auto-select the default back-facing camera.
- `settings` — optional initial ISP settings applied before the first frame.

Throws `PlatformException` on failure (e.g., permission denied, no camera found). After opening, errors are delivered via `errorStream`.

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

---

### Preview

#### `camera.buildPreview()`

```dart
Widget buildPreview({BoxFit fit = BoxFit.contain, Widget? placeholder})
```

Returns a widget that displays the live camera preview.

- `fit` — how the preview inscribes into available space (default: `BoxFit.contain`).
- `placeholder` — widget shown while not streaming (during opening, recovery, or error). Defaults to an empty `SizedBox`.

```dart
// Full-screen preview
Expanded(
  child: camera.buildPreview(
    fit: BoxFit.cover,
    placeholder: Center(child: CircularProgressIndicator()),
  ),
)
```

The preview automatically:
- Shows the placeholder during `opening`, `recovering`, and `error` states
- Switches to the live `Texture` when `streaming`
- Preserves the correct aspect ratio via `FittedBox`

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
| `histBlackPoint` | `double` | 0.0 | [0, 1] | Manual histogram black point |
| `histWhitePoint` | `double` | 1.0 | [0, 1] | Manual histogram white point |
| `autoStretch` | `bool` | false | | Auto-compute histogram stretch per-frame |
| `autoStretchLow` | `double` | 0.01 | [0, 1] | Lower percentile clip for auto-stretch |
| `autoStretchHigh` | `double` | 0.99 | [0, 1] | Upper percentile clip for auto-stretch |
| `brightness` | `double` | 0.0 | [-1.0, 1.0] | Brightness offset |
| `saturation` | `double` | 1.0 | [0, 3] | Saturation multiplier (1.0 = identity) |

```dart
camera.setProcessingParams(ProcessingParams(
  gamma: 1.2,
  brightness: 0.1,
  saturation: 1.3,
));
```

---

### Still Capture

#### `camera.takePicture()`

```dart
Future<String> takePicture()
```

Captures a JPEG still image using a pre-allocated ImageReader. Returns the absolute file path. Does not interrupt the streaming pipeline.

```dart
final path = await camera.takePicture();
// path is something like /data/.../cache/capture_1711929600000.jpg
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
| `error` | Fatal error; app must call `close()` and optionally reopen |

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
| `streamWidth` / `streamHeight` | `int` | YUV stream dimensions delivered to the C++ pipeline (pixels). Used by the preview widget for correct aspect ratio. |
| `estimatedMemoryBytes` | `int` | Estimated native memory usage |

---

### Native Consumer API (C++)

For apps that need direct access to processed frames in C++ (e.g., real-time computer vision, image stitching), the plugin provides a generic consumer sink model. Your app registers C++ callbacks that receive post-processed RGBA frames — the same pixels shown in the preview. Each sink has its own ring buffer and dispatch thread, so slow consumers don't stall the preview.

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

Include the public header `cambrian_camera_native.h` and register sinks. Each sink receives post-processed frames independently, at the resolution and channel configuration you specify.

```cpp
// In your application's native library (e.g., my_consumers.cpp)
#include <cambrian_camera_native.h>

static int g_stitchSinkId = -1;
static int g_trackSinkId  = -1;

// Called from Dart FFI or JNI with the pipeline pointer
extern "C" void registerConsumers(int64_t pipelinePtr) {
    auto* pipeline = reinterpret_cast<cam::IImagePipeline*>(
            static_cast<uintptr_t>(pipelinePtr));
    if (!pipeline) return;

    // ── Consumer 1: Full-resolution RGBA for stitching ──────────────
    cam::SinkConfig stitchCfg;
    stitchCfg.name       = "stitcher";
    stitchCfg.width      = 0;      // 0 = match source (full resolution)
    stitchCfg.height     = 0;      // 0 = match source
    stitchCfg.channels   = 4;      // RGBA
    stitchCfg.ringSize   = 4;      // 4 pre-allocated ring buffer slots
    stitchCfg.dropOnFull = false;   // log warning on backpressure

    g_stitchSinkId = pipeline->addSink(stitchCfg, [](cam::SinkFrame& frame) {
        // frame.data   → pixel buffer (row-major RGBA)
        // frame.width  → image width in pixels
        // frame.height → image height in pixels
        // frame.stride → row stride in bytes (>= width * channels)
        // frame.meta   → sensor metadata (timestamp, ISO, exposure, etc.)

        processForStitching(frame.data, frame.width, frame.height, frame.stride);
        // No need to call frame.release() — the dispatch thread manages the ring
        // buffer slot automatically. Copy the data if you need it past the callback.
    });

    // ── Consumer 2: Second full-res RGBA sink for tracking ─────────
    cam::SinkConfig trackCfg;
    trackCfg.name       = "tracker";
    trackCfg.width      = 0;       // 0 = match source (full resolution)
    trackCfg.height     = 0;       // 0 = match source
    trackCfg.channels   = 4;       // RGBA
    trackCfg.ringSize   = 8;       // deeper ring — tracker may lag
    trackCfg.dropOnFull = true;    // drop stale frames silently

    g_trackSinkId = pipeline->addSink(trackCfg, [](cam::SinkFrame& frame) {
        runTrackingAlgorithm(frame.data, frame.width, frame.height);
    });
}

// Called when your app no longer needs the consumers
extern "C" void unregisterConsumers(int64_t pipelinePtr) {
    auto* pipeline = reinterpret_cast<cam::IImagePipeline*>(
            static_cast<uintptr_t>(pipelinePtr));
    if (!pipeline) return;

    if (g_stitchSinkId >= 0) pipeline->removeSink(g_stitchSinkId);
    if (g_trackSinkId  >= 0) pipeline->removeSink(g_trackSinkId);
    g_stitchSinkId = -1;
    g_trackSinkId  = -1;
}
```

#### `SinkConfig` reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | `string` | — | Human-readable label (used in log messages) |
| `width` | `int` | 0 | Output width. 0 = match source (full resolution). |
| `height` | `int` | 0 | Output height. 0 = match source. |
| `channels` | `int` | 4 | Bytes per pixel. 4 = RGBA. |
| `channelIndex` | `int` | -1 | Reserved for future single-channel extraction. Currently ignored. |
| `ringSize` | `int` | 4 | Number of pre-allocated ring buffer slots. |
| `dropOnFull` | `bool` | true | `true`: silently drop newest frame when ring is full. `false`: currently also drops (blocking not yet implemented). |

> **Not yet implemented:** Downscaling (width/height smaller than source crops rather than scales), single-channel extraction (`channelIndex`), and blocking on full ring (`dropOnFull=false`). These are defined in the API for forward compatibility.

#### `SinkFrame` reference

| Field | Type | Description |
|-------|------|-------------|
| `data` | `const uint8_t*` | Pixel buffer pointer (row-major, tightly packed per channel) |
| `width` | `int` | Frame width in pixels |
| `height` | `int` | Frame height in pixels |
| `stride` | `int` | Row stride in bytes (may be > width * channels due to alignment) |
| `channels` | `int` | Bytes per pixel (4 = RGBA, 1 = single channel) |
| `meta` | `FrameMetadata` | Sensor metadata for this frame |
| `release` | `function<void()>` | Reserved for future use. Currently a no-op — ring buffer slots are managed automatically by the dispatch thread. |

#### `FrameMetadata` reference

| Field | Type | Description |
|-------|------|-------------|
| `frameNumber` | `int64_t` | Monotonically increasing frame counter |
| `sensorTimestampNs` | `int64_t` | Sensor capture start time (monotonic clock, same as IMU) |
| `exposureTimeNs` | `int64_t` | Actual exposure duration in nanoseconds |
| `iso` | `int32_t` | Sensor sensitivity (ISO equivalent) |

> **Note:** Metadata plumbing from Camera2 capture results to `SinkFrame.meta` is not yet wired. The fields will be zero until this is implemented.

#### Lifetime and threading rules

- **`frame.data` is valid only for the duration of the callback.** The ring buffer slot is recycled when the callback returns. Copy the data if you need it longer.
- **Each sink has a dedicated dispatch thread.** Callbacks run on per-sink threads, not the pipeline's frame-processing thread, so a slow callback does not stall the preview or other sinks.
- **`addSink()` / `removeSink()` are thread-safe.** You can register or remove sinks at any time, even while streaming.
- **`removeSink()` blocks** until the sink's dispatch thread exits (including any in-flight callback and queued frames), so it is safe to free resources immediately after it returns.

#### Memory budget

All ring buffers are pre-allocated at `addSink()` time. Memory per sink:

```
width * height * channels * ringSize bytes
```

Example for a whole-slide imaging app at 4K (3840x2160):

| Sink | Resolution | Channels | Ring | Memory |
|------|-----------|----------|------|--------|
| "stitcher" | 3840x2160 | 4 (RGBA) | 4 | 133 MB |
| "tracker" | 3840x2160 | 4 (RGBA) | 8 | 265 MB |
| **Total consumer memory** | | | | **~398 MB** |

> **Tip:** Keep ring sizes small and callbacks fast to minimize memory usage. For heavy processing, copy the frame data in the callback and process on your own thread.

Use `camera.capabilities.estimatedMemoryBytes` to check the plugin's own memory usage (input ring + preview). Plan your sink budgets accordingly.

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
          child: camera.buildPreview(fit: BoxFit.contain),
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
                final path = await camera.takePicture();
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
  |  (JNI: nativeDeliverYuv)
C++: ImagePipeline
  |  (YUV→RGBA conversion, per-frame processing, consumer dispatch)
  +-> ANativeWindow (Flutter preview — written via ANativeWindow_lock)
  +-> Registered sinks (per-sink ring buffer + dispatch thread)
```

**Frame path:** Camera2 → YUV ImageReader → `nativeDeliverYuv` (JNI) → `processFrameYuv` (C++) → ANativeWindow + sinks

**Surface ownership invariant:** A BufferQueue surface can only have one producer. Camera2 session outputs claim surfaces via `connect(NATIVE_WINDOW_API_CAMERA)`. `ANativeWindow_lock` claims via `connect(NATIVE_WINDOW_API_CPU)`. The preview surface must be in one or the other — never both. In the current architecture, the C++ pipeline owns it.

The plugin manages everything below the Dart API line. Your app interacts only with `CambrianCamera` and optionally registers C++ consumers via the native pipeline handle.

---

## Auto-Recovery

The plugin handles transient camera errors internally:

1. Non-fatal error detected (device error, disconnect, config failure)
2. State transitions to `recovering` (visible via `stateStream`)
3. Resources torn down, then retry with exponential backoff (500ms, 1s, 2s, 4s, 8s)
4. After 5 failed retries, state transitions to `error` (fatal)

Your app does not need to implement retry logic. Just listen to `stateStream` and show appropriate UI feedback during `recovering`.

---

## Settings Update Strategies

The plugin uses two different strategies depending on the parameter type:

**CameraSettings (ISP)** — Latest-value-wins serializer with server-side accumulation. Each update requires a Dart-to-Kotlin-to-Camera2 round trip. If a new value arrives while the previous is in-flight, the old pending value is replaced (not queued). On the Kotlin side, incoming non-null fields are merged into the accumulated settings state — omitted (null) fields retain their previous values. This means you only need to send the fields you want to change.

**ProcessingParams (C++ pipeline)** — Fire-and-forget. A direct pass-through to native code. The next frame picks up the new values atomically. No queuing.

You can safely call `updateSettings()` on every slider tick without worrying about request accumulation or losing other settings.
