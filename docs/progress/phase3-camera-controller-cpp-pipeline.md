# Phase 3: CameraController + Minimal C++ Passthrough — Complete

## What was built

Real Camera2 lifecycle in Kotlin (`CameraController.kt`) plus a minimal C++ JNI bridge
(`CameraBridge.cpp` / `ImagePipeline.cpp`) that receives RGBA frames and copies them to an
`ANativeWindow` for Flutter preview display.

## Files created / modified

| File | Change |
|------|--------|
| `android/src/main/kotlin/.../CameraController.kt` | Full Camera2 lifecycle: open/close, ImageReader, auto-recovery, per-request ISP settings, JPEG capture, JNI bridge |
| `android/src/main/kotlin/.../CambrianCameraPlugin.kt` | Refactored to use `SurfaceProducer`, delegate all API calls to `CameraController` |
| `android/src/main/kotlin/.../MetadataLayout.kt` | Kotlin constants mirroring `MetadataLayout.h` for flat-array JNI metadata transfer |
| `android/src/main/cpp/CMakeLists.txt` | Builds `libcambrian_camera.so`; C++17, links `android` + `log` |
| `android/src/main/cpp/include/cambrian_camera_native.h` | Public consumer API stub (Phase 4 will add `addSink`/`removeSink`) |
| `android/src/main/cpp/include/MetadataLayout.h` | C++ metadata layout constants with `static_assert` guards |
| `android/src/main/cpp/src/ImagePipeline.h` | Internal header for Phase 3 identity pipeline |
| `android/src/main/cpp/src/ImagePipeline.cpp` | Identity blit: `ANativeWindow_lock → memcpy rows → unlockAndPost` |
| `android/src/main/cpp/src/CameraBridge.cpp` | JNI glue: `nativeInit`, `nativeDeliverFrame`, `nativeRelease`, `nativeSetPreviewWindow` |
| `android/build.gradle.kts` | Uncommented `externalNativeBuild` CMake block |
| `lib/main.dart` | `_openCamera` wrapped in try-catch for graceful error handling |
| `docs/progress/phase3-camera-controller-cpp-pipeline.md` | This file |

## Key design decisions

### SurfaceProducer (replaces SurfaceTextureEntry)
Phase 3 migrates from the deprecated `createSurfaceTexture()` to `createSurfaceProducer()`.
`SurfaceProducer.getSurface()` provides a `Surface` directly (no SurfaceTexture wrapping needed),
and the lifecycle callbacks (`onSurfaceCreated`, `onSurfaceDestroyed`) map cleanly to the
auto-recovery state machine's preview rebinding path.

### Frame format: RGBA_8888 preferred, YUV_420_888 fallback
`resolveStreamFormat()` queries `StreamConfigurationMap.getOutputSizes(PixelFormat.RGBA_8888)`.
If supported, frames are delivered to C++ via `nativeDeliverFrame` (direct buffer, no conversion).
If not, falls back to `ImageFormat.YUV_420_888`: frames are drained, and the SurfaceProducer is
added as a direct Camera2 output so the preview still works. Phase 4 will add YUV→RGBA conversion.

On OPD2403 (Android 16/API 36) the device fell back to YUV_420_888 at 1920×1080. The preview
runs via Camera2 → SurfaceProducer directly; the C++ pipeline is initialised but not yet in the
frame path on this device.

### Main-thread dispatching
All Pigeon callbacks (`CameraFlutterApi.onStateChanged`, `CameraFlutterApi.onError`) and Dart
result callbacks require the Android main thread. `CameraController` uses a `mainHandler`
(`Handler(Looper.getMainLooper())`) to marshal these back from the `CameraBackground` HandlerThread.

### Auto-recovery
States: `CLOSED → OPENING → STREAMING → RECOVERING → ERROR`.
Non-fatal errors (disconnect, configure failed, device error, service error) enter the recovery
loop with exponential backoff: 500 ms, 1 s, 2 s, 4 s, 8 s (max 5 retries).
Fatal errors (CAMERA_DISABLED, MAX_CAMERAS_IN_USE, permission denied) skip recovery and emit
`error` immediately.

### MetadataLayout constants
`MetadataLayout.kt` and `MetadataLayout.h` share the same flat-array index constants. C++ has
`static_assert` guards so a mismatch between the two files fails at NDK compile time.

## Bugs fixed during implementation

| Bug | Root cause | Fix |
|-----|-----------|-----|
| `@UiThread` crash | Pigeon callbacks called from `CameraBackground` HandlerThread | Dispatch all Pigeon callbacks via `mainHandler.post {}` |
| `configure_failed` loop | RGBA_8888 ImageReader created at JPEG resolution (potentially 4K); device may not support RGBA at that size | Query `getOutputSizes(PixelFormat.RGBA_8888)` and fall back to YUV; use ≤1920×1080 |
| `Unresolved reference ERROR_CAMERA_DISABLED` | Constants are on `CameraDevice.StateCallback`, not `CameraDevice` | Changed to `CameraDevice.StateCallback.ERROR_CAMERA_*` |
| Unhandled Dart exception | `_openCamera()` had no try-catch | Wrapped in try-catch with `debugPrint` fallback |

## Test results

```
flutter analyze        — No issues found
flutter test           — 14 tests passed, 0 failed
flutter build apk      — Build succeeded (NDK 25.1.8937393 + C++17)
flutter run OPD2403    — App launched:
  D/CambrianCamera: ImagePipeline created, window=0xb400007a2157d210
  D/CambrianCamera: nativeInit: pipeline created at 0xb400007ad55f3000
  Camera service connected to ImageReaders; no teardown or crash
  Live camera preview visible (Camera2 → SurfaceProducer path)
```

## Next: Phase 4 — C++ post-processing + consumer fan-out

- Full processing pipeline: black balance → WB gains → LUT (gamma / histogram / brightness) → RGB saturation
- Generic `addSink()` / `removeSink()` consumer registry
- Per-sink downscaling and channel extraction
- Ring buffers with `shared_ptr` safety
- `cambrian_camera_native.h` expanded with full `IImagePipeline` interface
- OpenCV integration (copy from `/Users/shrek/work/cambrian/eva_empty_demo/android/opencv`)
- RGBA_8888 delivery to C++ on devices that support it; YUV→RGBA conversion fallback
