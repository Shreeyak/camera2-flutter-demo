# Camera2 Flutter Plugin Architecture

## Context

We're designing a unified Flutter plugin (`cambrian_camera`) for a whole-slide imaging scanner. The camera sweeps across a specimen capturing overlapping 4K frames that get post-processed and fanned out to three consumers: preview display, stitcher (full-res RGBA), and tracker (480p green channel). Only Android (Camera2) will be implemented initially, but the Dart API must be platform-agnostic for future iOS support.

A reference architecture exists in `tmp_files/cam2-plugin-1flow/` with Kotlin CameraController, C++ ImagePipeline, JNI bridge, and a shared header. This analysis identifies gaps and proposes improvements.

---

## Architecture Overview (6 Layers)

```
┌─────────────────────────────────────────────────────────────┐
│  L1: Dart Public API          (packages/cambrian_camera/lib)│
│  CambrianCamera, CameraSettings, ProcessingParams, streams  │
└──────────────────────────┬──────────────────────────────────┘
                           │ abstract platform interface
┌──────────────────────────┴──────────────────────────────────┐
│  L2: Platform Interface   (platform_interface.dart)          │
│  CambrianCameraPlatform → MethodChannelCambrianCamera        │
└──────────────────────────┬──────────────────────────────────┘
                           │ MethodChannel + EventChannel
┌──────────────────────────┴──────────────────────────────────┐
│  L3: Kotlin FlutterPlugin (CambrianCameraPlugin.kt)          │
│  FlutterPlugin + ActivityAware, TextureRegistry, channels    │
└──────────────────────────┬──────────────────────────────────┘
                           │ direct Kotlin calls
┌──────────────────────────┴──────────────────────────────────┐
│  L4: Kotlin CameraController                                 │
│  Camera2 lifecycle, ImageReader, per-request ISP settings    │
└──────────────────────────┬──────────────────────────────────┘
                           │ JNI (DirectByteBuffer + flat arrays)
┌──────────────────────────┴──────────────────────────────────┐
│  L5: C++ JNI Bridge  (CameraBridge.cpp)                      │
│  Deserialize metadata, wrap buffers, call pipeline           │
└──────────────────────────┬──────────────────────────────────┘
                           │ C++ calls
┌──────────────────────────┴──────────────────────────────────┐
│  L6: C++ ImagePipeline                                       │
│  YUV→RGBA, post-processing, fan-out to 3 sinks              │
└─────────────────────────────────────────────────────────────┘
```

---

## What the Reference Architecture Gets Right

- **Clean separation**: Kotlin owns Camera2, C++ owns processing — good boundary
- **Per-request ISP settings**: All CameraOptions map to CaptureRequest keys, no session reconfig needed for parameter changes
- **Pre-allocated ring buffers**: Avoids per-frame allocation for all three output paths
- **DirectByteBuffer input ring**: Kotlin copies into pre-allocated direct buffers, C++ reads via GetDirectBufferAddress
- **ANativeWindow for preview**: Zero JNI per frame after init; direct pixel write to display buffer
- **Comprehensive FrameMetadata**: Captures everything needed for scientific imaging (intrinsics, WB gains, exposure, crop region, etc.)
- **Dedicated pipeline thread**: Processing doesn't block the ImageReader thread

---

## Critical Gaps in the Reference

### Gap 1: No Flutter Integration Layer

The reference is a standalone Android native library. It has no Dart API, no MethodChannel, no FlutterPlugin registration, no TextureRegistry integration. It cannot function as a Flutter plugin.

**Fix**: Add layers 1-3 (Dart API, platform interface, Kotlin FlutterPlugin).

### Gap 0: YUV_420_888 When RGBA_8888 Is Available

The reference chooses YUV_420_888 and converts in C++. On API 29+ devices that support it, requesting `PixelFormat.RGBA_8888` from the ImageReader lets the ISP handle conversion at no extra cost, eliminating the most expensive pipeline stage. The C++ pipeline receives RGBA directly. YUV_420_888 remains as a fallback for devices that don't advertise RGBA_8888 output.

### Gap 2: Preview Surface Origin Undefined

ANativeWindow is the right approach, but the reference never explains where the Surface comes from. In Flutter, it must come from `TextureRegistry`:

```
Flutter Texture widget
    ↓ (textureId)
TextureRegistry.SurfaceTextureEntry
    ↓ (SurfaceTexture → Surface)
ANativeWindow_fromSurface(env, surface)
    ↓
C++ ANativeWindow_lock → memcpy RGBA → unlockAndPost
    ↓ (automatic)
SurfaceTexture updates → Flutter compositor re-renders
```

This is fully compatible with the reference's ANativeWindow approach — only the Surface origin changes.

### Gap 3: No Cross-Platform Abstraction

Even though only Android is implemented now, the Dart API should use a platform interface pattern so iOS can be added later by swapping the implementation without touching app code.

### Gap 4: Wrong Lifecycle Model

The reference `CameraController` extends `DefaultLifecycleObserver` using `onResume`/`onPause`. In Flutter, the Activity lifecycle and Flutter engine lifecycle are decoupled. The plugin must manage camera lifecycle via `FlutterPlugin.onAttachedToEngine`/`onDetachedFromEngine` and `ActivityAware` callbacks.

### Gap 5: No Error Propagation to Dart

`nativeOnState()` in C++ is a no-op. Camera2 errors (`onError`, `onConfigureFailed`), pipeline errors (ring full, window lock failure), and JNI errors all silently disappear. Need an EventChannel error stream.

---

## Improvements to the C++ Pipeline

### Improvement 1: RGBA_8888 Output Format (Eliminate YUV Conversion)

**Key change from reference**: Configure Camera2 to output `RGBA_8888` instead of `YUV_420_888`. The ISP already performs YUV→RGB conversion internally, so this moves the conversion off our pipeline with no added cost. This eliminates Stage 1 (YUV→RGBA cvtColor) entirely.

- `ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, bufferCount)` (API 29+)
- Check `StreamConfigurationMap.getOutputSizes(PixelFormat.RGBA_8888)` at init
- Fallback to YUV_420_888 + OpenCV conversion on devices that don't support it
- The `YuvFrame` struct becomes `RgbaFrame` for the primary path; YUV path kept as fallback

### Improvement 2: Start with OpenCV, Migrate to Halide Later

Start with OpenCV for post-processing (Phase 4). In Phase 6, replace with an optimized stack:

| Library | Role |
|---|---|
| **Halide** | Fused pipeline: black balance → WB gains → gamma LUT → histogram → brightness → saturation in one scheduled pass with auto-vectorized NEON, optimal tiling |
| **libyuv** | YUV→RGBA fallback path (for devices without RGBA_8888 support) |
| **SIMD intrinsics** | Any hot-path operations not covered by Halide (e.g., green channel extraction for tracker) |

Halide is ideal here because our pipeline is exactly the use case it was designed for: multiple fused pointwise operations with a LUT, where the algorithm definition is simple but the scheduling (tiling, vectorization, parallelism) determines performance.

### Improvement 2b: Fuse Per-Pixel Operations into Single Pass (Phase 6)

Currently 3 separate passes over 33MB of 4K RGBA data (black balance, LUT, saturation). Fuse into one:

```
For each pixel:
  1. Subtract black levels (R, G, B)
  2. Apply WB gains (multiply by wbGains[R,G,B])
  3. Look up LUT (gamma + histogram + brightness)
  4. Apply saturation: lum = 0.299R + 0.587G + 0.114B
     R = clamp(lum + sat*(R-lum)), same for G,B
  5. Write output
```

One read + one write per pixel. ~3x throughput improvement for post-processing.

### Improvement 3: Replace HSV Saturation with RGB Luminance-Deviation

Reference does RGBA→BGR→HSV→scale S→HSV→BGR→RGBA (4 color space conversions at 4K). Replace with direct RGB saturation (3 multiplies + 3 adds per pixel, fused into the main loop). Preserves luminance, which is more correct for scientific imaging. In Phase 4 (OpenCV), implement as direct pixel loop. In Phase 6, this fuses naturally into the Halide pipeline as a pointwise operation.

### Improvement 4: Implement Missing WB Gains (Stage 3)

The architecture doc describes white balance gain application but the C++ code skips it. For scientific imaging, this is a necessary manual correction layer on top of ISP AWB.

### Improvement 5: Reduce Frame Copy Overhead

`process()` copies the full frame into a `WorkItem` vector, defeating zero-copy claims. With RGBA_8888 this is ~33MB per frame. Alternative: pass ring slot index to pipeline thread, pipeline reads directly from DirectByteBuffer, signals completion before Kotlin reuses slot. This is a coordination change, not a data copy. (Can defer this optimization to Phase 6 alongside Halide migration.)

### Improvement 6: Pre-allocate JPEG ImageReader

First `takePic()` creates JPEG ImageReader and forces session reconfig (~200-500ms interruption). Instead, always create JPEG ImageReader at session configuration time. JPEG buffers are small (compressed), low cost.

### Improvement 7: Thread-Safe takePic()

`takePic()` accesses `session`/`device` directly, racing with `teardown()` on cameraHandler. Fix: wrap entire body in `cameraHandler.post { ... }`.

---

## Dart Public API

```dart
class CambrianCamera {
  static Future<CambrianCamera> create({String? cameraId});
  Future<CameraCapabilities> initialize({CameraSettings? settings});
  Future<void> dispose();

  int? get textureId;                      // for Texture widget
  Stream<CameraState> get stateStream;
  Stream<CameraError> get errorStream;
  Stream<FrameMetadata> get metadataStream;

  Future<void> updateSettings(CameraSettings settings);
  Future<void> setProcessingParams(ProcessingParams params);
  Future<void> takePicture();
}
```

`CameraSettings` maps to per-request CaptureRequest keys (ISO, exposure, focus, WB, zoom, NR mode, edge mode). `ProcessingParams` maps to C++ pipeline controls (black balance, gamma, histogram, brightness, saturation).

---

## Plugin File Structure

```
packages/cambrian_camera/
├── pubspec.yaml
├── lib/
│   ├── cambrian_camera.dart                 # barrel export
│   └── src/
│       ├── cambrian_camera_controller.dart   # CambrianCamera class
│       ├── camera_settings.dart              # CameraSettings, ProcessingParams
│       ├── camera_state.dart                 # CameraState, CameraCapabilities, CameraError
│       ├── frame_metadata.dart               # FrameMetadata (Dart mirror)
│       ├── camera_settings_queue.dart        # Debounce queue
│       ├── platform_interface.dart           # Abstract platform class
│       └── method_channel_camera.dart        # MethodChannel impl
├── android/
│   ├── build.gradle.kts
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── kotlin/com/cambrian/camera/
│       │   ├── CambrianCameraPlugin.kt       # FlutterPlugin + ActivityAware
│       │   ├── CameraController.kt           # Camera2 lifecycle + JNI dispatch
│       │   └── MetadataLayout.kt             # Shared metadata struct constants
│       └── cpp/
│           ├── CMakeLists.txt
│           ├── include/
│           │   ├── CameraPlugin.h             # Types, interfaces (NO opencv)
│           │   └── MetadataLayout.h           # Shared struct (mirrors .kt)
│           └── src/
│               ├── CameraBridge.cpp           # JNI glue
│               └── ImagePipeline.cpp          # Processing + fan-out
├── ios/                                       # Stub for future
│   ├── Classes/CambrianCameraPlugin.swift     # Returns notImplemented
│   └── cambrian_camera.podspec
└── test/
```

---

## Implementation Phases

**Phase 1 — Plugin skeleton + Dart API** (no native code)
- Create package structure, pubspec.yaml
- Dart API classes, platform interface, method channel impl
- CameraSettingsQueue debounce layer

**Phase 2 — Kotlin plugin shell** (no C++, no camera)
- CambrianCameraPlugin.kt with FlutterPlugin + ActivityAware
- MethodChannel/EventChannel wiring with stub responses
- TextureRegistry integration: return texture ID to Dart
- Verify Texture widget renders in demo app

**Phase 3 — CameraController** (Camera2, no C++)
- Port CameraController.kt from reference, fix lifecycle model
- Configure ImageReader with `PixelFormat.RGBA_8888` (fallback to YUV_420_888)
- Pre-allocate JPEG ImageReader at session config time, thread-safe takePic()
- Wire Surface from TextureRegistry to CameraController
- Implement per-request settings via loadConfig()
- Frame delivery to JNI (initially log frame count)

**Phase 4 — C++ pipeline** (OpenCV for post-processing)
- CameraPlugin.h with OpenCV (temporary, replaced in Phase 6)
- CameraBridge.cpp with packed-struct ByteBuffer metadata
- ImagePipeline.cpp: accept RGBA input directly (no YUV conversion needed on RGBA path), OpenCV for post-processing stages (black balance, WB gains, gamma, histogram, brightness, saturation)
- ANativeWindow preview, stitcher ring buffer, tracker ring buffer fan-out
- CMakeLists.txt linking OpenCV + android + log

**Phase 5 — Integration + demo app wiring**
- Replace black Container with Texture widget
- Wire UI callbacks through CameraSettingsQueue → CambrianCamera
- Populate CameraRanges from CameraCapabilities
- Wire error/state streams to UI

**Phase 6 — Performance optimization** (replace OpenCV with Halide + libyuv + SIMD)
- Replace OpenCV post-processing with Halide fused pipeline
  - Define Halide generator: black balance → WB gains → gamma LUT → histogram → brightness → saturation as one fused schedule
  - Auto-vectorized NEON, optimal tiling for L1/L2 cache
- Replace OpenCV YUV fallback path with libyuv
- Replace OpenCV resize (tracker downscale) with libyuv::ARGBScale or Halide downscale
- SIMD intrinsics for any remaining hot-path ops (green channel extraction)
- Eliminate per-frame copy: pipeline reads directly from DirectByteBuffer ring slots
- Remove OpenCV dependency from pipeline entirely (consumers link independently)

---

## Verification

- Phase 2: `flutter run` on Android — Texture widget appears (blank)
- Phase 3: `flutter run` — camera preview visible via RGBA_8888 ImageReader, settings sliders change capture params, logcat shows frame delivery
- Phase 4: `flutter run` — processed preview (gamma/brightness/saturation controls work), ring buffer callbacks fire
- Phase 5: Full end-to-end — all UI controls functional, takePicture works, error handling works
- Phase 6: Benchmark comparison — measure frame processing time before/after Halide migration, verify identical visual output
