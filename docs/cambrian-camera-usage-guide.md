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
// child: camera.buildPreview(fit: BoxFit.cover),

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

> **ISO + Exposure coupling:** `iso` and `exposureTimeNs` must always be set to the **same mode** in the same call. Camera2 uses a single `CONTROL_AE_MODE` flag for both: `AE_MODE_ON` (both auto) or `AE_MODE_OFF` (both manual). A mixed update — one manual, one auto — leaves the "auto" partner with no explicit sensor value, producing undefined exposure. The plugin rejects mixed updates with a `CameraErrorCode.settingsConflict` error.

#### Examples

```dart
// Manual ISO + manual exposure (must be set together)
camera.updateSettings(CameraSettings(
  iso: AutoValue.manual(800),
  exposureTimeNs: AutoValue.manual(16666666), // 1/60 s
  focus: AutoValue.auto(),
));

// Switch to full auto
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

> Note: Phase 3 is an identity pipeline (no processing). These parameters will take effect when Phase 4 (C++ post-processing) is implemented.

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
| `configurationFailed` | No | Session configuration failed |
| `previewSurfaceLost` | No | Flutter surface recycled |
| `pipelineError` | No | C++ processing error |
| `permissionDenied` | **Yes** | Camera permission revoked |
| `cameraDisabled` | **Yes** | Camera disabled by system policy |
| `maxCamerasInUse` | **Yes** | Too many cameras open in the system |

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
| `supportsRgba8888` | `bool` | Whether device supports direct RGBA output |
| `estimatedMemoryBytes` | `int` | Estimated native memory usage |

---

### Native Consumer API (C++)

For apps that need direct access to processed frames in C++ (e.g., real-time computer vision, image stitching), the plugin provides a generic consumer sink model. Your app registers C++ callbacks that receive post-processed frames — the same pixels shown in the preview. The plugin knows nothing about your app's use case; it just delivers frames at the resolution and channel configuration you request.

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

        frame.release();  // MUST call — returns the ring buffer slot
    });

    // ── Consumer 2: Low-res single-channel for tracking ─────────────
    cam::SinkConfig trackCfg;
    trackCfg.name         = "tracker";
    trackCfg.width        = 960;    // downscale to 960x540
    trackCfg.height       = 540;
    trackCfg.channels     = 1;      // single channel
    trackCfg.channelIndex = 1;      // extract green (0=R, 1=G, 2=B, 3=A)
    trackCfg.ringSize     = 8;      // deeper ring — tracker may lag
    trackCfg.dropOnFull   = true;   // drop stale frames silently

    g_trackSinkId = pipeline->addSink(trackCfg, [](cam::SinkFrame& frame) {
        // frame.data is now 960x540, 1 byte per pixel (green channel only)
        runTrackingAlgorithm(frame.data, frame.width, frame.height);

        frame.release();  // MUST call
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
| `channels` | `int` | 4 | Bytes per pixel. 4 = RGBA, 1 = single channel. |
| `channelIndex` | `int` | -1 | Which channel to extract when `channels=1`. -1 = all (requires channels=4). 0=R, 1=G, 2=B, 3=A. |
| `ringSize` | `int` | 4 | Number of pre-allocated ring buffer slots. |
| `dropOnFull` | `bool` | true | `true`: silently drop newest frame when ring is full. `false`: log a warning (backpressure signal to your app). |

#### `SinkFrame` reference

| Field | Type | Description |
|-------|------|-------------|
| `data` | `const uint8_t*` | Pixel buffer pointer (row-major, tightly packed per channel) |
| `width` | `int` | Frame width in pixels |
| `height` | `int` | Frame height in pixels |
| `stride` | `int` | Row stride in bytes (may be > width * channels due to alignment) |
| `channels` | `int` | Bytes per pixel (4 = RGBA, 1 = single channel) |
| `meta` | `FrameMetadata` | Sensor metadata for this frame |
| `release` | `function<void()>` | **Must be called** when done with the frame data. Returns the ring buffer slot. |

#### `FrameMetadata` reference

| Field | Type | Description |
|-------|------|-------------|
| `frameNumber` | `int64_t` | Monotonically increasing frame counter |
| `sensorTimestampNs` | `int64_t` | Sensor capture start time (monotonic clock, same as IMU) |
| `exposureTimeNs` | `int64_t` | Actual exposure duration in nanoseconds |
| `iso` | `int32_t` | Sensor sensitivity (ISO equivalent) |

#### Lifetime and threading rules

- **`frame.release()` is mandatory.** Failing to call it leaks ring buffer slots until the ring is full and all frames are dropped.
- **`frame.data` is only valid until `release()` is called.** Copy the data if you need it longer.
- **Callbacks are invoked on the pipeline's processing thread.** Keep callbacks fast. For heavy work, copy the frame into your own queue and process on a separate thread.
- **`addSink()` / `removeSink()` are thread-safe.** You can register or remove sinks at any time, even while streaming.
- **`removeSink()` blocks** until any in-flight callback for that sink completes, so it is safe to free resources immediately after it returns.

#### Memory budget

All ring buffers are pre-allocated at `addSink()` time. Memory per sink:

```
width * height * channels * ringSize bytes
```

Example for a whole-slide imaging app at 4K (3840x2160):

| Sink | Resolution | Channels | Ring | Memory |
|------|-----------|----------|------|--------|
| "stitcher" | 3840x2160 | 4 (RGBA) | 4 | 133 MB |
| "tracker" | 960x540 | 1 (green) | 8 | 4 MB |
| **Total consumer memory** | | | | **~137 MB** |

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
  |  (JNI)
C++: ImagePipeline
  |  (post-processing, preview output, consumer fan-out)
  +-> ANativeWindow (Flutter preview)
  +-> Registered sinks (your app's C++ consumers)
```

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
