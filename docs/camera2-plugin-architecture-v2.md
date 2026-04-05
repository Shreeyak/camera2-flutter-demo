# Camera2 Flutter Plugin Architecture v2

## Context

We're designing a unified Flutter plugin (`cambrian_camera`) for controlling a camera on Android (Camera2) with real-time C++ post-processing. The library captures frames, applies user-configurable image adjustments (brightness, saturation, gamma, white balance, etc.), and delivers post-processed frames to both a preview display and any number of native C++ consumers via ring buffers.

**The library is use-case agnostic.** It knows nothing about stitching, tracking, or any specific application. Applications register their own C++ consumers with the configuration they need (resolution, channels, ring size, drop policy). Two known applications:
- A whole-slide imaging scanner performing real-time CV (tracking at low-res, stitching at 4K)
- A slide annotation app capturing and annotating high-quality images

Both need user-adjustable post-processing visible in the preview. The image in the preview is pixel-identical to what consumers receive.

Only Android (Camera2) is implemented initially. The Dart API is platform-agnostic for future iOS support.

---

## Architecture Overview (6 Layers)

```
┌─────────────────────────────────────────────────────────────┐
│  L1: Dart Public API          (packages/cambrian_camera/lib)│
│  CambrianCamera, CameraSettings, ProcessingParams, streams  │
└──────────────────────────┬──────────────────────────────────┘
                           │ Pigeon-generated type-safe interface
┌──────────────────────────┴──────────────────────────────────┐
│  L2: Platform Interface   (Pigeon @HostApi / @FlutterApi)    │
│  CameraHostApi → Kotlin, CameraFlutterApi → Dart callbacks   │
└──────────────────────────┬──────────────────────────────────┘
                           │ Generated Kotlin bindings
┌──────────────────────────┴──────────────────────────────────┐
│  L3: Kotlin FlutterPlugin (CambrianCameraPlugin.kt)          │
│  FlutterPlugin + ActivityAware, TextureRegistry, Pigeon host │
└──────────────────────────┬──────────────────────────────────┘
                           │ direct Kotlin calls
┌──────────────────────────┴──────────────────────────────────┐
│  L4: Kotlin CameraController                                 │
│  Camera2 lifecycle, ImageReader, per-request ISP settings,   │
│  auto-recovery state machine                                 │
└──────────────────────────┬──────────────────────────────────┘
                           │ JNI (DirectByteBuffer + flat arrays)
┌──────────────────────────┴──────────────────────────────────┐
│  L5: C++ JNI Bridge  (CameraBridge.cpp)                      │
│  Deserialize metadata, wrap buffers, call pipeline           │
└──────────────────────────┬──────────────────────────────────┘
                           │ C++ calls
┌──────────────────────────┴──────────────────────────────────┐
│  L6: C++ ImagePipeline                                       │
│  Post-processing, preview output, generic consumer fan-out   │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Design Decisions

### Pigeon over raw MethodChannel

Raw MethodChannel with string-based method names and `Map<String, dynamic>` payloads is error-prone — typos, missing arguments, and type mismatches are caught only at runtime. Pigeon generates type-safe Dart and Kotlin code from a shared interface definition, eliminating this class of bugs.

`@FlutterApi` replaces EventChannel for state/error callbacks.

### YUV_420_888 for streaming

`YUV_420_888` is the streaming format. At session setup `resolveStreamFormat()` queries `StreamConfigurationMap.getOutputSizes(YUV_420_888)`, selects the largest 4:3 size (matching the sensor's native aspect ratio for highest quality), and falls back to 1280×960 if no 4:3 size is advertised. The chosen resolution is reported in `CameraCapabilities.yuvStreamWidth` / `yuvStreamHeight`.

### Per-request ISP settings

All CameraSettings (ISO, exposure, focus, WB, zoom, NR, edge mode) map to per-request CaptureRequest keys. Changing them rebuilds the repeating request — no session reconfiguration needed.

Session-level changes (stream format/size/buffer count) trigger a full stop/start cycle, but these are rare (only at initialization or explicit resolution change).

### SurfaceProducer for preview

The preview Surface comes from Flutter's `TextureRegistry.SurfaceProducer`:

```
Flutter Texture widget
    ↓ (textureId = SurfaceProducer.id, stable across surface recreations)
TextureRegistry.SurfaceProducer
    ↓ getSurface()
Camera2 repeating CaptureRequest target
    ↓ (Camera2 writes YUV frames directly into the Surface)
SurfaceProducer → Flutter compositor re-renders
```

Camera2 writes directly into the `SurfaceProducer` surface as a `CaptureRequest` target — no C++ memcpy on the preview path. JNI is used only for frame delivery to the C++ pipeline (Phase 4+).

### Generic consumer model (no use-case knowledge)

The library does NOT have hardcoded "stitcher" or "tracker" outputs. Instead, it provides a generic consumer sink registry. Application C++ code registers sinks with the configuration it needs. The library handles downscaling, channel extraction, and ring buffer management per-sink.

### Auto-recovery

The library handles camera errors internally with exponential backoff retry. The Dart layer receives state transitions (including `recovering`) and informational errors, but does not need to implement recovery logic.

---

## Dart Public API

```dart
class CambrianCamera {
  /// Opens camera and starts the pipeline. Single step to a working camera.
  static Future<CambrianCamera> open({
    String? cameraId,
    CameraSettings? settings,
    bool enableRawStream = false,
    int rawStreamHeight = 0,
  });

  /// Closes camera and releases all resources.
  Future<void> close();

  /// Emits the Flutter texture ID for the color-processed preview.
  /// Apps render it with Flutter's Texture widget.
  Stream<CameraTextureInfo> get toneMappedTexture;

  /// Emits the Flutter texture ID for the raw (passthrough) preview.
  /// Only emits if enableRawStream: true was passed to open().
  Stream<CameraTextureInfo> get rawTexture;

  /// Camera state transitions (ready, streaming, recovering, error).
  Stream<CameraState> get stateStream;

  /// Error events. Non-fatal errors (auto-recovering) are informational.
  /// Fatal errors (permission revoked, camera disabled) require app action.
  Stream<CameraError> get errorStream;

  /// Device capabilities, available after open().
  CameraCapabilities get capabilities;

  /// Update ISP-level camera settings (ISO, exposure, focus, WB, zoom).
  /// Uses latest-value-wins serialization — no artificial latency.
  Future<void> updateSettings(CameraSettings settings);

  /// Unique identifier for this camera instance (also the Flutter texture ID).
  int get id;

  /// Update C++ pipeline processing parameters (brightness, gamma, saturation, etc.).
  /// Returns a Future that completes when the channel round-trip finishes.
  /// Callers may await to observe errors or ignore for fire-and-forget semantics.
  Future<void> setProcessingParams(ProcessingParams params);

  /// Capture a high-quality still image. Returns the file path.
  Future<String> takePicture();

  /// Returns the native pipeline pointer for C++ consumer registration, or null
  /// if the pipeline is not yet initialized.
  Future<int?> getNativePipelineHandle();
}
```

### CameraSettings

Maps to per-request CaptureRequest keys. Auto-capable settings use sealed types so the three
states (don't change / auto / manual) are explicit at compile time:

```dart
class CameraSettings {
  final AutoValue<int>? iso;          // AutoValue.auto() | AutoValue.manual(800)
  final AutoValue<int>? exposureTimeNs; // nanoseconds; auto is contagious with iso
  final AutoValue<double>? focus;     // diopters; AutoValue.auto() = continuous AF
  final WhiteBalance? whiteBalance;   // WhiteBalance.auto() | .locked() | .manual(gainR,gainG,gainB)
  final double? zoomRatio;
  final NoiseReductionMode? noiseReductionMode; // off / fast / highQuality / minimal / zeroShutterLag
  final EdgeMode? edgeMode;           // off / fast / highQuality / zeroShutterLag
  final int? evCompensation;          // steps; no effect when AE is disabled
}
```

`null` means "don't change" — the Kotlin side accumulates settings so omitted fields
retain their previous values. ISO and exposure share a single Camera2 AE flag: setting
either to `auto` propagates to the other automatically.

### ProcessingParams

Maps to C++ pipeline controls:

```dart
class ProcessingParams {
  final double blackR, blackG, blackB;   // [0.0, 0.5] per-channel black level
  final double gamma;                     // [0.1, 4.0], 1.0 = identity
  final double brightness;               // [-1.0, +1.0]
  final double saturation;               // [0, 3], 1.0 = identity
}
```

Note: no `trackingScale` — downscaling is per-consumer, configured at the C++ level.

### CameraState

```dart
enum CameraState {
  closed,       // camera not open
  opening,      // initializing
  streaming,    // actively delivering frames
  recovering,   // error occurred, auto-recovering
  error,        // fatal error, requires app action
}
```

### CameraCapabilities

```dart
class CameraCapabilities {
  final List<CameraSize> supportedSizes;
  final int isoMin, isoMax;
  final int exposureTimeMinNs, exposureTimeMaxNs;
  final double focusMin, focusMax;
  final double zoomMin, zoomMax;
  final int evCompMin, evCompMax;
  final double evCompensationStep;
  final int yuvStreamWidth, yuvStreamHeight;  // resolution chosen by resolveStreamFormat()
  // Raw stream fields — all 0 when raw is disabled (enableRawStream: false or raw init failed)
  final int rawStreamTextureId;   // Flutter texture ID for raw preview; 0 when disabled
  final int rawStreamWidth;       // auto-computed from aspect ratio; 0 when disabled
  final int rawStreamHeight;      // matches rawStreamHeight passed to open(); 0 when disabled
}
```

### CameraError

```dart
class CameraError {
  final CameraErrorCode code;
  final String message;
  final bool isFatal;   // false = informational (auto-recovering)
}

enum CameraErrorCode {
  cameraDevice,          // hardware error
  cameraService,         // system service error
  cameraDisconnected,    // USB disconnect, system reclaim
  configurationFailed,   // session config failed
  permissionDenied,      // fatal
  cameraDisabled,        // system policy, fatal
  maxCamerasInUse,       // fatal
  previewSurfaceLost,    // recovering
  pipelineError,         // C++ processing error
}
```

---

## C++ Native Consumer API

### Public header: `cambrian_camera_native.h`

This header is the contract between the library and application C++ code. It does NOT include OpenCV or any library internals.

```cpp
#pragma once
#include <cstdint>
#include <functional>
#include <string>

namespace cam {

// ---- Frame metadata (subset relevant to consumers) ----

struct FrameMetadata {
    int64_t frameNumber;
    int64_t sensorTimestampNs;      // monotonic, same clock as IMU
    int64_t exposureTimeNs;
    int32_t iso;

    // Focus
    float focusDistanceDiopters;
    float depthOfFieldNearM;
    float depthOfFieldFarM;

    // Lens
    float focalLengthMm;
    float aperture;
    float zoomRatio;

    // White balance
    float wbGains[4];               // [R, G_even, G_odd, B]
    float colorMatrix[9];           // row-major 3x3
    int32_t colorTemperatureK;

    // Intrinsics (camera calibration)
    float fx, fy, cx, cy, skew;
    float distortion[5];            // Brown-Conrady k[5]
    int32_t intrinsicWidth;         // resolution intrinsics were computed for
    int32_t intrinsicHeight;

    // Geometry
    int32_t sensorOrientation;
    int32_t cropX, cropY, cropW, cropH;

    // State
    int32_t aeState;
    int32_t afState;
    int32_t awbState;
    int64_t rollingShutterSkewNs;
    int64_t frameDurationNs;
};

// ---- Consumer sink types ----

struct SinkFrame {
    const uint8_t* data;
    int width;
    int height;
    int stride;                     // bytes per row
    int channels;                   // 4=RGBA, 1=single channel
    FrameMetadata meta;
    std::function<void()> release;  // MUST be called when done with frame data
};

enum class SinkRole {
    FULL_RES,   // processed frames (color shader output) — default
    TRACKER,    // processed frames, typically at lower resolution
    RAW,        // passthrough frames (no color math, bit-exact RGBA from rawFBO)
                // only delivers frames when enableRawStream: true was passed to open()
};

struct SinkConfig {
    std::string name;               // application-defined label (for logging)
    SinkRole role = SinkRole::FULL_RES; // which render path this sink receives
    int width  = 0;                 // 0 = match source (full resolution)
    int height = 0;                 // 0 = match source
    int channels = 4;              // 4=RGBA, 1=single channel
    int channelIndex = -1;          // which channel to extract when channels=1
                                    // -1=all (requires channels=4), 0=R, 1=G, 2=B, 3=A
    int ringSize = 4;              // number of pre-allocated ring buffer slots
    bool dropOnFull = true;         // true: silently drop frame
                                    // false: log warning (backpressure signal)
};

using SinkCallback = std::function<void(SinkFrame&)>;

// ---- Pipeline interface ----

class IImagePipeline {
public:
    virtual ~IImagePipeline() = default;

    /// Register a consumer sink. Returns a sink ID (>= 0).
    /// Thread-safe. Can be called before or after streaming starts.
    virtual int addSink(const SinkConfig& config, SinkCallback callback) = 0;

    /// Remove a previously registered sink. Thread-safe.
    /// Blocks until any in-flight callback for this sink completes.
    virtual void removeSink(int sinkId) = 0;

    // Pipeline lifecycle and other methods are library-internal.
    // Consumers only interact via addSink/removeSink and the SinkCallback.
};

/// Get the pipeline instance. Returns nullptr if the library hasn't initialized yet.
/// Application native code calls this to register consumers.
IImagePipeline* getPipeline();

} // namespace cam
```

### Consumer registration example (application code)

```cpp
// In the application's native library (e.g., stitcher_jni.cpp)
#include <cambrian_camera_native.h>

static int g_stitchSinkId = -1;
void registerConsumers() {
    auto* pipeline = cam::getPipeline();
    if (!pipeline) return;

    // Full-res RGBA for stitching
    pipeline->addSink({"stitcher", cam::SinkRole::FULL_RES},
                      [](const cam::SinkFrame& frame) {
        // frame.data = full-res RGBA, valid for duration of this callback
    });

    // 480p downscaled RGBA for tracking
    pipeline->addSink({"tracker", cam::SinkRole::TRACKER},
                      [](const cam::SinkFrame& frame) {
        // frame.data = 480p-height RGBA
    });

    // Raw passthrough sink (only when enableRawStream: true was passed to open())
    pipeline->addSink({"raw_writer", cam::SinkRole::RAW},
                      [](const cam::SinkFrame& frame) {
        // frame.data = passthrough RGBA from rawFBO, no shader adjustments
    });
}
```

### Linking

The application's `CMakeLists.txt` links against the camera library's shared object:

```cmake
# Application CMakeLists.txt
find_library(cambrian-camera cambrian_camera)
target_link_libraries(my_app ${cambrian-camera})
target_include_directories(my_app PRIVATE ${cambrian_camera_INCLUDE_DIR})
```

Alternative: the Dart layer calls `getNativePipelineHandle()` and passes the pointer to the app's native code via FFI, avoiding the need to link directly.

---

## Pigeon Interface Definition

```dart
// pigeons/camera_api.dart

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/messages.g.dart',
  kotlinOut: 'android/src/main/kotlin/com/cambrian/camera/Messages.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.cambrian.camera'),
))

// ---- Data classes ----

class CamSettings {
  // Mode strings: "auto" | "manual" | null (null = don't change)
  String? isoMode;
  int? iso;                      // value when isoMode == "manual"
  String? exposureMode;
  int? exposureTimeNs;           // nanoseconds when exposureMode == "manual"
  String? focusMode;
  double? focusDistanceDiopters; // when focusMode == "manual"
  String? wbMode;                // "auto" | "locked" | "manual" | null
  double? wbGainR, wbGainG, wbGainB; // when wbMode == "manual"
  double? zoomRatio;
  String? noiseReductionMode;
  String? edgeMode;
  int? evCompensation;
}

class PigeonProcessingParams {
  double blackR = 0;
  double blackG = 0;
  double blackB = 0;
  double gamma = 1.0;
  double brightness = 0;
  double saturation = 1.0;
}

class PigeonCameraCapabilities {
  // ranges, supported sizes, format info, memory estimate
}

class PigeonCameraState {
  String state;  // "closed", "opening", "streaming", "recovering", "error"
}

class PigeonCameraError {
  String code;
  String message;
  bool isFatal;
}

// ---- Host API (Dart → Kotlin) ----

@HostApi()
abstract class CameraHostApi {
  @async
  int open(String? cameraId, PigeonCameraSettings? settings);

  @async
  PigeonCameraCapabilities getCapabilities(int handle);

  void updateSettings(int handle, PigeonCameraSettings settings);

  void setProcessingParams(int handle, PigeonProcessingParams params);

  @async
  String takePicture(int handle);

  @async
  int getNativePipelineHandle(int handle);

  @async
  void close(int handle);
}

// ---- Flutter API (Kotlin → Dart) ----

@FlutterApi()
abstract class CameraFlutterApi {
  void onStateChanged(int handle, PigeonCameraState state);
  void onError(int handle, PigeonCameraError error);
}
```

---

## Auto-Recovery State Machine

Implemented in Kotlin CameraController. The library handles camera errors internally.

```
                    ┌──────────┐
                    │  CLOSED  │
                    └────┬─────┘
                         │ open()
                    ┌────▼─────┐
                    │ OPENING  │
                    └────┬─────┘
                         │ camera opened + session configured
                    ┌────▼──────┐
              ┌────►│ STREAMING │◄────────────────┐
              │     └────┬──────┘                  │
              │          │ error detected           │
              │     ┌────▼───────┐                 │
              │     │ RECOVERING │─────────────────┘
              │     └────┬───────┘  success (retry)
              │          │ max retries exceeded
              │     ┌────▼─────┐
              │     │  ERROR   │  (fatal — app must close/reopen)
              │     └──────────┘
              │
              └── close() from any state → CLOSED
```

### Recovery behavior

```
error detected → state = RECOVERING (emitted to Dart stateStream)
  → teardown camera resources
  → wait (exponential backoff: 500ms, 1s, 2s, 4s, max 8s)
  → attempt reinit (open device, configure session, rebind preview)
  → success: resume STREAMING, reset backoff counter
  → fail: increment backoff, retry
  → after 5 failures: emit fatal error to Dart, state = ERROR
```

### Auto-recover from:
- `CameraDevice.StateCallback.onError(ERROR_CAMERA_DEVICE | ERROR_CAMERA_SERVICE)`
- `CameraDevice.StateCallback.onDisconnected()` — USB cameras, system reclaim
- `CameraCaptureSession.StateCallback.onConfigureFailed()`
- `SurfaceProducer.Callback.onSurfaceAvailable()` — Flutter surface recycled (rebind capture session to new Surface)

### Do NOT auto-recover from (emit as fatal):
- `ERROR_CAMERA_DISABLED` — system policy
- Permission revoked at runtime
- `ERROR_MAX_CAMERAS_IN_USE` — another app has exclusive access

### Preview rebinding

When the `SurfaceProducer` surface is invalidated (hot restart, activity recreation):
1. Flutter calls `SurfaceProducer.Callback.onSurfaceAvailable()` with the new Surface
2. `CameraController` calls `rebindYuvPreviewSurface(newSurface)`
3. Previous capture session is closed; a new session is created with `newSurface` as the repeating request target
4. `SurfaceProducer.id` (= texture ID) is stable — Dart does not need to rebuild the `Texture` widget

---

## Settings Update Strategies

### CameraSettings (ISP-level: ISO, exposure, focus, WB, zoom)

**Latest-value-wins serializer** (NOT a time-based debounce).

Each setting change requires a Dart → Kotlin → Camera2 `setRepeatingRequest` round trip. If a new value arrives while the previous is in-flight, the old pending value is replaced. No artificial latency is added.

```dart
// Internally in the platform implementation:
class CameraSettingsSerializer {
  PigeonCameraSettings? _pending;
  bool _inFlight = false;

  void send(PigeonCameraSettings settings) {
    if (_inFlight) {
      _pending = settings;  // replace, don't queue
      return;
    }
    _inFlight = true;
    _hostApi.updateSettings(handle, settings).then((_) {
      _inFlight = false;
      if (_pending != null) {
        final next = _pending!;
        _pending = null;
        send(next);
      }
    });
  }
}
```

### ProcessingParams (C++ pipeline: brightness, gamma, saturation)

**Fire-and-forget. No serialization.**

These are applied in C++ via a mutex-protected struct copy. The next frame picks up the new values. The Dart → Kotlin → JNI → C++ `setParams()` path is a direct pass-through. One platform channel call per slider tick is negligible compared to the 30fps frame pipeline.

```dart
// In CambrianCamera:
void setProcessingParams(ProcessingParams params) {
  // Synchronous call to platform — no await, no queue
  _hostApi.setProcessingParams(_handle, params.toPigeon());
}
```

---

## GPU Pipeline Internals

### GL/EGL concepts

Two distinct constructs manage rendering and delivery:

- **FBO (GL)** — an off-screen render target that lives entirely inside the GL context. The tone-mapping shader writes into it. Never visible on screen by itself.
- **EGL window surface** — wraps an `ANativeWindow` (a `BufferQueue`) and delivers finished frames to an external consumer via `eglSwapBuffers`. Three exist: preview, encoder (optional), raw preview (optional).
- **EGL pbuffer surface** — a 1×1 dummy surface. EGL requires a surface to be current at all times; the pbuffer acts as a neutral home base between blits. Its memory is never written.

The FBO is used (rather than rendering directly into an EGL window surface) because it lets the tone-mapping shader run **once** per frame and deliver to multiple consumers cheaply via blits.

### Per-frame sequence (`GpuRenderer::drawAndReadback`)

All steps run sequentially on the single GL thread managed by `GpuPipeline.kt`'s `glHandler`. There is no inter-step concurrency.

```
Camera OES texture (SurfaceTexture, updated by camera HAL)
     │
     ▼
① Render OES → fbo_
     tone-mapping shader (black balance, brightness,
     contrast, saturation, gamma) runs once per frame.
     All subsequent steps read from this one result.
     │
     ├──② glBlit fbo_ → trackerFbo_
     │       downscale to 480p, GL_LINEAR filter
     │
     ├──③ eglMakeCurrent(eglWindowSurface_)
     │       glBlit fbo_ → default FB (= window surface)
     │       eglSwapBuffers ──────────────────────────────► Flutter Texture (preview)
     │       eglMakeCurrent(pbuffer)
     │
     ├──④ eglMakeCurrent(eglEncoderSurface_)          [only when recording]
     │       glBlit fbo_ → default FB (= encoder surface)
     │       eglSwapBuffers ──────────────────────────────► MediaCodec input queue
     │       eglMakeCurrent(pbuffer)                         → drain thread → .mp4
     │
     ├──⑤ glReadPixels(fbo_,      PBO[writeIdx])      async GPU→CPU DMA, no stall
     │    glReadPixels(trackerFbo_, PBO[writeIdx])
     │
     └──⑥ glMapBufferRange(PBO[readIdx])              previous frame's DMA complete
              fullResCb(rgba_ptr…) ───────────────────► ImagePipeline → C++ sinks
              trackerCb(rgba_ptr…) ───────────────────► ImagePipeline → C++ sinks
              glUnmapBuffer
```

Steps ③ and ④ are GPU-internal blits — the GPU reads `fbo_` in VRAM and writes to another VRAM region. No data crosses to the CPU. `eglSwapBuffers` is a **pointer swap** (not a pixel copy) that atomically hands the back buffer to the external consumer and gives GL a fresh buffer to render into next frame.

### Concurrency model

| What | Thread | Mechanism |
|------|--------|-----------|
| All GL/EGL calls | GL thread (`glHandler`) | Single-threaded; no GL locks needed |
| Shader uniform updates | Any thread | `uniformMu_` mutex; snapshotted at start of step ① |
| `setEncoderSurface()` | Posted to GL thread | Queued behind in-flight `drawAndReadback` |
| C++ sink callbacks (step ⑥) | GL thread | Called synchronously; must return quickly |
| MediaCodec drain | Separate `HandlerThread` | Reads from codec output queue independently |

### Double-buffered PBO readback (steps ⑤ and ⑥)

Two PBOs alternate each frame to hide GPU→CPU transfer latency:

```
Frame N:   write PBO[0]  (glReadPixels enqueues DMA)
Frame N+1: write PBO[1]  AND  map PBO[0]  (DMA from frame N is done)
Frame N+2: write PBO[0]  AND  map PBO[1]
…
```

C++ sinks therefore receive frames with **one frame of latency** relative to what is displayed. The RGBA pointer passed to callbacks is valid only for the duration of the callback — consumers must copy if they need to retain data.

### Dual-path rendering (processed + raw)

When `enableRawStream` is active, a second pass runs after step ⑦ (index advance):

```
Camera OES texture
     │
     ├── [tone-mapping shader] → fbo_     (always active, steps ①–⑥ above)
     │
     └── [passthrough shader]  → rawFbo_  (only when rawW_ > 0)
              │
              ├── glBlit → eglRawSurface_ ──────────────────► Flutter raw Texture
              ├── PBO readback → rawCb() ──────────────────► RAW C++ sinks
              └── (no encoder path on raw stream)
```

The passthrough shader applies no colour adjustments — output is the camera image as RGBA with no modifications. Useful for comparing processed vs unprocessed in the UI.

### Memory budget (GPU)

| Resource | Size | Notes |
|----------|------|-------|
| `fbo_` texture | W × H × 4 bytes | ~32 MB at 4K |
| `trackerFbo_` texture | 480p × 4 bytes | ~4 MB |
| `fullResPbo_[2]` | W × H × 4 × 2 | ~64 MB at 4K |
| `trackerPbo_[2]` | 480p × 4 × 2 | ~8 MB |
| `eglWindowSurface_` (double-buffered) | W × H × 4 × 2 | ~64 MB at 4K |
| `eglEncoderSurface_` (double-buffered) | W × H × 4 × 2 | ~64 MB at 4K, only when recording |
| `rawFbo_` + `rawPbo_[2]` + `rawEGLSurface_` | rawW × rawH × 4 × 5 | e.g., ~40 MB at 1080p |

---

## JNI Metadata Layout

Flat arrays for zero-allocation metadata transfer. Layout defined in shared constant files.

### MetadataLayout.kt / MetadataLayout.h

Single source of truth for array indices:

```kotlin
// MetadataLayout.kt
object MetadataLayout {
    const val FLOAT_COUNT = 26
    const val FLOAT_FOCUS_DISTANCE = 0
    const val FLOAT_DOF_NEAR = 1
    const val FLOAT_DOF_FAR = 2
    const val FLOAT_FOCAL_LENGTH = 3
    // ... all indices
    const val LONG_COUNT = 5
    const val INT_COUNT = 23
}
```

```cpp
// MetadataLayout.h
namespace cam::meta {
    constexpr int FLOAT_COUNT = 26;
    constexpr int FLOAT_FOCUS_DISTANCE = 0;
    constexpr int FLOAT_DOF_NEAR = 1;
    // ... mirrors Kotlin exactly
}
static_assert(cam::meta::FLOAT_COUNT == 26, "Layout mismatch");
```

### Future optimization (Phase 6)

Replace flat arrays with a packed struct in a shared DirectByteBuffer:

```cpp
struct __attribute__((packed)) PackedMetadata {
    int64_t frameNumber;
    int64_t sensorTimestampNs;
    // ... all fields in fixed order
};
static_assert(sizeof(PackedMetadata) == EXPECTED_SIZE);
```

Kotlin writes via `ByteBuffer.putLong/putFloat/putInt`. C++ casts `GetDirectBufferAddress` to `PackedMetadata*`. Zero deserialization.

---

## Plugin File Structure

```
packages/cambrian_camera/
├── pubspec.yaml
├── pigeons/
│   └── camera_api.dart                  # Pigeon interface definition
├── lib/
│   ├── cambrian_camera.dart             # barrel export
│   └── src/
│       ├── cambrian_camera_controller.dart   # CambrianCamera class
│       ├── cambrian_camera_preview.dart      # buildPreview() widget
│       ├── camera_settings.dart              # CameraSettings, ProcessingParams
│       ├── camera_state.dart                 # CameraState, CameraCapabilities, CameraError
│       ├── camera_settings_serializer.dart   # Latest-value-wins for CameraSettings
│       └── messages.g.dart                   # Generated by Pigeon
├── android/
│   ├── build.gradle.kts
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── kotlin/com/cambrian/camera/
│       │   ├── CambrianCameraPlugin.kt       # FlutterPlugin + ActivityAware + Pigeon host
│       │   ├── CameraController.kt           # Camera2 lifecycle + auto-recovery
│       │   ├── MetadataLayout.kt             # Shared metadata array constants
│       │   └── Messages.g.kt                 # Generated by Pigeon
│       └── cpp/
│           ├── CMakeLists.txt
│           ├── include/
│           │   ├── cambrian_camera_native.h   # Public consumer API (NO OpenCV)
│           │   └── MetadataLayout.h           # Shared metadata constants
│           └── src/
│               ├── CameraBridge.cpp           # JNI glue
│               ├── ImagePipeline.cpp          # Processing + generic fan-out
│               └── ImagePipelineInternal.h    # Internal header (may use OpenCV)
├── ios/                                       # Stub for future
│   ├── Classes/CambrianCameraPlugin.swift     # PlatformException("PLATFORM_NOT_SUPPORTED")
│   └── cambrian_camera.podspec
└── test/
    ├── cambrian_camera_test.dart
    └── camera_settings_serializer_test.dart
```

Key structural changes from v1:
- `pigeons/` directory for Pigeon definitions
- `messages.g.dart` / `Messages.g.kt` generated files
- `cambrian_camera_native.h` replaces `CameraPlugin.h` (no OpenCV in public header)
- `ImagePipelineInternal.h` for OpenCV usage (library-internal only)
- `camera_settings_serializer.dart` replaces `camera_settings_queue.dart`
- `cambrian_camera_preview.dart` for the preview widget

---

## Implementation Phases

### Phase 1 — Plugin skeleton + Dart API (no native code)

- Create package structure, pubspec.yaml
- Write Pigeon interface definition, run code generation
- Dart API classes: CambrianCamera, CameraSettings, ProcessingParams, CameraState, CameraError, CameraCapabilities
- CameraSettingsSerializer (latest-value-wins)
- CambrianCameraPreview widget (shows placeholder until textureId available)
- Unit tests for serializer logic, settings serialization round-trips

### Phase 2 — Kotlin plugin shell (no C++, no camera)

- CambrianCameraPlugin.kt with FlutterPlugin + ActivityAware
- Implement Pigeon CameraHostApi with stub responses
- TextureRegistry integration: return texture ID to Dart
- CameraFlutterApi wiring: emit state changes to Dart
- Verify: `flutter run` — Texture widget appears (blank), state stream works

### Phase 3 — CameraController + minimal C++ passthrough

- CameraController.kt: Camera2 lifecycle, YUV_420_888 ImageReader (largest 4:3 size)
- Auto-recovery state machine (retry with exponential backoff)
- Per-request ISP settings via `setRepeatingRequest`
- Pre-allocate JPEG ImageReader at session config time, thread-safe takePic()
- Minimal C++ pipeline: accept RGBA input → identity (no processing) → ANativeWindow preview
- JNI bridge with MetadataLayout constants + static assertions
- **Verify: `flutter run` — live camera preview visible, settings sliders change capture params**

This phase validates the entire frame pipeline end-to-end before adding processing complexity.

### Phase 4 — C++ post-processing + consumer fan-out (OpenCV)

- Full processing pipeline: black balance → WB gains → gamma/histogram/brightness LUT → RGB saturation
- Generic consumer sink registry: `addSink()` / `removeSink()`
- Per-sink downscaling and channel extraction
- Ring buffers with shared_ptr safety
- `cambrian_camera_native.h` public header (no OpenCV)
- CMakeLists.txt linking OpenCV + android + log
- C++ unit tests: ring buffer correctness, processing pipeline against golden images
- **Verify: processing controls work in preview, consumers receive frames**

### Phase 5 — Integration + demo app wiring

- Replace black Container with `CambrianCamera.buildPreview()`
- Wire UI callbacks through CameraSettingsSerializer → CambrianCamera
- Populate CameraRanges from CameraCapabilities
- Wire error/state streams to UI (show recovering state)
- Test auto-recovery: revoke permission during streaming, disconnect/reconnect
- **Verify: full end-to-end — all UI controls functional, takePicture works, error recovery works**

### Phase 6 — Performance optimization

- Replace OpenCV post-processing with Halide fused pipeline
  - Single scheduled pass: black balance → WB gains → gamma LUT → histogram → brightness → saturation
  - Auto-vectorized NEON, optimal tiling for L1/L2 cache
- Replace OpenCV YUV fallback with libyuv
- Replace OpenCV resize (consumer downscale) with libyuv::ARGBScale or Halide
- SIMD intrinsics for remaining hot-path ops (green channel extraction)
- Replace flat metadata arrays with packed struct in DirectByteBuffer
- Eliminate per-frame copy: pipeline reads directly from DirectByteBuffer ring slots
- Remove OpenCV dependency from library entirely
- **Verify: benchmark frame processing time before/after, verify identical visual output**

---

## Testing Strategy

### Dart unit tests
- `CameraSettingsSerializer`: latest-value-wins semantics, in-flight replacement
- `CameraSettings` / `ProcessingParams` Pigeon serialization round-trips
- `CambrianCamera` state machine transitions using mock platform interface
- `CambrianCameraPreview` widget: placeholder when no texture, correct aspect ratio

### C++ unit tests (Google Test)
- `SlotRing` acquire/release correctness, full-ring behavior, concurrent access
- Post-processing pipeline: feed known input image, verify output matches golden reference
- `FrameMetadata` deserialization from flat arrays matches expected values
- Per-sink transforms: downscale correctness, channel extraction correctness

### Kotlin integration tests
- CameraController state machine transitions (mock CameraDevice if possible)
- Auto-recovery: simulate error → verify state transitions → verify stream resumes
- Per-request settings correctly applied to CaptureRequest

### On-device integration tests
- End-to-end: camera → pipeline → preview visible → consumer receives frames
- Error recovery: revoke camera permission, verify recovery or fatal error
- Preview rebinding: simulate activity recreation, verify preview resumes
- Memory stability: run at 30fps for 5 minutes, verify no memory growth
- ProcessingParams responsiveness: change params, measure latency to preview update
