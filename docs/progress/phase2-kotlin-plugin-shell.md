# Phase 2: Kotlin Plugin Shell — Complete

## What was built

Kotlin stub implementation of `CambrianCameraPlugin` and wiring of `CambrianCameraPreview`
into the demo app. No real camera hardware is opened; all responses are hard-coded stubs.

## Files created / modified

| File | Change |
|------|--------|
| `packages/cambrian_camera/android/src/main/kotlin/.../CambrianCameraPlugin.kt` | Kotlin stub: FlutterPlugin + ActivityAware + CameraHostApi with TextureRegistry |
| `lib/main.dart` | Wired `CambrianCamera.open()` and `CambrianCameraPreview` into the demo screen |
| `docs/progress/phase2-kotlin-plugin-shell.md` | This file |

## Key design decisions

- **`CameraSession`** — simple data class holding the `SurfaceTextureEntry`; its `id()` is
  the camera handle returned to Dart (handle == textureId, no extra lookup needed).
- **Stub state flow** — emits `opening → streaming` synchronously inside `open()` to let
  the preview widget transition to the live texture pane immediately.
- **`compileOnly` for lifecycle** — `androidx.lifecycle:lifecycle-common` is added as
  `compileOnly` because the Flutter plugin-loader already injects the real dependency;
  avoids duplicate resolution at link time.

## Phase 3 note: SurfaceProducer migration

The runtime emits:
> Flutter recommends migrating plugins that create and register surface textures to the new
> surface producer API.

Phase 3 should replace `TextureRegistry.createSurfaceTexture()` / `SurfaceTextureEntry` with
`TextureRegistry.createSurfaceProducer()` / `SurfaceProducer` to avoid the deprecation. The
`SurfaceProducer` API is available from Flutter 3.22 and provides a unified surface that works
across both GL and Vulkan (Impeller) renderers.

## Test results

```
flutter analyze — No issues found
flutter build apk --debug — Build succeeded
flutter run -d OPD2403 — App launched on Android 16/API 36
  No Flutter-level errors (E/flutter)
  Pigeon channels registered at attach
  CambrianCamera.open() completed; Texture widget rendered (blank, expected for stub)
  State transitions: opening → streaming emitted correctly
```

## Next: Phase 3 — CameraController + minimal C++ passthrough

- Replace `SurfaceTextureEntry` with `SurfaceProducer`
- `CameraController.kt`: real Camera2 lifecycle (CameraManager → CameraDevice →
  CaptureSession → repeating CaptureRequest)
- `ImageReader` in `RGBA_8888` format; JPEG `ImageReader` pre-allocated for still capture
- Auto-recovery state machine (exponential backoff: 500ms→1s→2s→4s→8s, max 5 retries)
- Per-request ISP settings applied via `CaptureRequest.Builder`
- Minimal C++ JNI passthrough (identity processing → ANativeWindow preview)
- NDK configuration in `build.gradle.kts` (`externalNativeBuild` uncommented)
- Verify live camera preview visible on device
