# Phase 1: Plugin Skeleton + Dart API — Complete

## What was built

Plugin package at `packages/cambrian_camera/` with full Dart API layer (no native code).

## Files created

| File | Purpose |
|------|---------|
| `pubspec.yaml` | Plugin metadata, pigeon + flutter_plugin_android_lifecycle deps |
| `pigeons/camera_api.dart` | Pigeon interface definition (source of truth for Dart↔Kotlin messages) |
| `lib/src/messages.g.dart` | Pigeon-generated type-safe channel bindings |
| `lib/src/camera_settings.dart` | `CameraSettings`, `ProcessingParams` — public data classes with `toCam()` converters |
| `lib/src/camera_state.dart` | `CameraState`, `CameraError`, `CameraErrorCode`, `CameraCapabilities`, `CameraSize` |
| `lib/src/camera_settings_serializer.dart` | Latest-value-wins serializer for ISP settings updates |
| `lib/src/cambrian_camera_controller.dart` | `CambrianCamera` — main public API class |
| `lib/src/cambrian_camera_preview.dart` | `CambrianCameraPreview` — preview widget wrapping Flutter Texture |
| `lib/cambrian_camera.dart` | Barrel export |
| `android/build.gradle.kts` | Plugin build config (NDK 25.1.8937393, minSdk 21, API 35) |
| `android/src/main/AndroidManifest.xml` | Camera permission + features declaration |
| `android/src/main/kotlin/.../CambrianCameraPlugin.kt` | Kotlin stub (Phase 2 will implement) |
| `ios/Classes/CambrianCameraPlugin.swift` | iOS stub (not supported yet) |
| `ios/cambrian_camera.podspec` | iOS podspec |
| `test/camera_settings_serializer_test.dart` | 14 unit tests |

## Key design decisions

- **Pigeon** for type-safe Dart↔Kotlin communication (no raw MethodChannel string dispatch)
- **Handle = textureId**: `CambrianCamera.open()` returns a handle that doubles as the Flutter Texture widget ID
- **FlutterApi dispatcher**: single global `_FlutterApiDispatcher` routes Kotlin→Dart callbacks to the correct camera instance via a handle→instance map
- **Two update strategies**: `CameraSettings` uses latest-value-wins serializer; `ProcessingParams` is fire-and-forget

## Test results

```
14 tests passed, 0 failed
No analyzer issues
```

## Next: Phase 2 — Kotlin plugin shell

Implement `CambrianCameraPlugin.kt` with FlutterPlugin + ActivityAware + Pigeon host, TextureRegistry integration, and stub Pigeon responses. Verify Texture widget renders in the app.
