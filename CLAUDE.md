# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Quick Start

```bash
flutter pub get              # Install dependencies
flutter run                 # Run app (will prompt for device selection)
flutter build apk --debug   # Build debug APK (verification)
flutter test                # Run all tests
flutter analyze             # Run Dart analyzer
```

**Never use `--release`** for builds or `flutter run`. Debug builds are sufficient for verification and avoid release-signing complications.

## Project Structure

- **`lib/`** — Dart source code (entry point: `main.dart`)
- **`android/`** — Android native code (gradle build config)
- **`ios/`** — iOS native code and Xcode project
- **`pubspec.yaml`** — Flutter dependencies and project metadata
- **`analysis_options.yaml`** — Linting rules (extends `package:flutter_lints`)

## Reference Documentation

Use the `camera2-docs` skill when looking up Camera2 API details while coding.

  Camera2 API reference is at:
  ~/work/cambrian/eva-ref/camera2-docs-scrape/output/

  - API classes: output/api-reference/camera2/ClassName.md
  - Params: output/api-reference/camera2-params/ClassName.md
  - Architecture guides: output/guides/camera/
  - Search index: output/MANIFEST.json

## Living Documents

Read these before making changes to the plugin internals:

- **`docs/architecture.md`** — plugin architecture, data flow, component relationships. **Read before modifying any Kotlin or C++ file.**
- **`docs/usage-guide.md`** — public API and usage patterns. **Read before modifying Dart-facing APIs.**

Keep both files up to date whenever the architecture or public API changes.

## Important Notes

- This is a Flutter demo project for the camera2 library
- Platform-specific implementations belong in `android/` and `ios/` directories
- Follow Flutter style conventions enforced by `flutter_lints`
- Do not use wildcard imports; always import explicit symbols
  - **Dart:** use `show`/`hide` (e.g. `import 'package:foo/bar.dart' show MyClass;`)
  - **Kotlin/Java:** no wildcard imports (e.g. avoid `import x.y.*`)
- Use `flutter pub get` after modifying `pubspec.yaml`
- Always create a todo list to track progress and remain on track

## Pigeon Codegen

Pigeon (Flutter's platform channel code generator) has a known bug in all versions
through v26.3.3 that generates incorrect type casts in callback error parsing.
**Never run `dart run pigeon` directly.** Always use:

    scripts/regenerate_pigeon.sh

This script runs Pigeon and patches the generated output. See
`docs/plans/04-06-2026-fix-pigeon-codegen-type-casts.md` for full context.

## OpenCV (Android)

The native pipeline uses OpenCV. The SDK is **not** checked in; it is symlinked from a host build:

```bash
ln -s <OPENCV_ANDROID_SDK_PATH> \
      packages/cambrian_camera/android/opencv
```

Replace `<OPENCV_ANDROID_SDK_PATH>` with the absolute path to your OpenCV Android SDK (e.g. `$HOME/software/opencv-build-android/opencv-android-sdk`).

Run this once per worktree clone. The symlink is git-ignored. Without it, the NDK build will fail with a missing `OpenCV_DIR` error.

## CameraController Threading Model

`CameraController.kt` uses two `Handler` threads with strict rules:

- **`backgroundHandler`** — All Camera2 operations (open, configure, capture, teardown). The capture callback, stall watchdog, and recovery logic all run here. Any new method that touches Camera2 state (`captureSession`, `cameraDevice`, surfaces, `state` enum) must wrap its body in `backgroundHandler.post { ... }`.
- **`mainHandler`** — All Dart/Flutter callbacks (`flutterApi.*`, `emitState()`, Pigeon callbacks). Never call Pigeon APIs from `backgroundHandler` directly.

**Pattern for new public methods:**
```kotlin
fun myMethod(callback: (Result<Unit>) -> Unit) {
    backgroundHandler.post {
        // ... Camera2 work ...
        mainHandler.post { callback(Result.success(Unit)) }
    }
}
```

Reference: `backgroundSuspend()`, `backgroundResume()`, `close()`. Never call `teardown()` directly from the main thread.

## Key Internal State (CameraController.kt)

| Field | Type | Purpose |
|-------|------|---------|
| `state` | `State` enum | Lifecycle: CLOSED, OPENING, STREAMING, RECOVERING |
| `gpuPipeline` | `GpuPipeline?` | GPU processing pipeline; manages OpenGL surfaces |
| `videoRecorder` | `VideoRecorder?` | MediaRecorder wrapper for video capture |
| `isRecording` | `Boolean` | Guards recording teardown in `pause()` and `teardown()` |
| `lastCaptureResultMs` | `Long` | Monotonic timestamp for stall detection |

## Rules for AI Agents

- **Never leave TODOs for required behavior.** If a plan says to call an API and you can't find it, search broadly (`grep -r` across `packages/cambrian_camera/`). Only report NEEDS_CONTEXT after exhaustive search. Do not comment out calls or stub them.
- **Match surrounding patterns.** Find 2-3 similar functions and match their threading, error handling, and state notification patterns. Code samples in plans are sketches — the codebase is the source of truth for HOW to implement.
- **State notifications are mandatory.** Any path that changes camera, recording, or error state MUST notify Dart via `flutterApi.*` posted on `mainHandler`.
- **Verify before claiming "doesn't exist."** Fields may be far from your edit site in a large file.

## Testing

### Running Integration Tests

```bash
flutter test integration_test/ -d <device-id>   # Run all on-device tests
flutter test integration_test/app_test.dart -d <device-id>  # Run specific test file
```

Tests use `integration_test` (in-process, direct widget access). Do NOT use `flutter_driver` — it was removed from this project because it times out during recording due to continuous frame callbacks.

### Widget Registry

All interactive widgets are registered in `lib/testing/widget_registry.dart`. The registry is the **only** way to create `ValueKey`s for testable widgets. This prevents drift between keys and metadata.

**Key files:**
- `lib/testing/widget_registry.dart` — `WidgetRegistry` singleton and `WidgetEntry` class
- `lib/testing/testable.dart` — `Testable` wrapper (applies key + semantics)
- `lib/testing/test_channel.dart` — Debug-only camera state service extension
- `lib/widgets/*_keys.dart` — Per-widget-file key registrations

**Naming convention:** dot-separated hierarchy `{area}.{widget}[.{sub}]`

### Widget Map

| ID | Widget | File |
|----|--------|------|
| `bar.settings` | Settings button | bottom_bar.dart |
| `bar.calibrate` | Calibrate color button | bottom_bar.dart |
| `bar.record` | Record/Stop button | bottom_bar.dart |
| `bar.close` | Close settings button | camera_settings_bar.dart |
| `chip.iso` | ISO chip | camera_settings_bar.dart |
| `chip.shutter` | Shutter chip | camera_settings_bar.dart |
| `chip.focus` | Focus chip | camera_settings_bar.dart |
| `chip.wb` | White balance chip | camera_settings_bar.dart |
| `chip.zoom` | Zoom chip | camera_settings_bar.dart |
| `dial.auto_toggle` | Auto/manual toggle | main.dart |
| `dial.wb_segment` | WB auto/lock segment | camera_control_overlay.dart |
| `gpu.brightness` | Brightness slider | gpu_controls_sidebar.dart |
| `gpu.contrast` | Contrast slider | gpu_controls_sidebar.dart |
| `gpu.saturation` | Saturation slider | gpu_controls_sidebar.dart |
| `gpu.gamma` | Gamma slider | gpu_controls_sidebar.dart |
| `gpu.black.r` | Black balance red | gpu_controls_sidebar.dart |
| `gpu.black.g` | Black balance green | gpu_controls_sidebar.dart |
| `gpu.black.b` | Black balance blue | gpu_controls_sidebar.dart |
| `gpu.reset_all` | Reset all button | gpu_controls_sidebar.dart |
| `hud.recording` | Recording HUD | recording_hud.dart |

### Adding New Testable Widgets

1. Register with the registry in a `*_keys.dart` file next to the widget:
   ```dart
   final kMyWidget = WidgetRegistry.instance.register(
     id: 'area.name',
     label: 'Accessible label',
     description: 'What it does',
   );
   ```
2. Wrap the widget with `Testable(entry: kMyWidget, child: ...)` in the build method
3. For sliders: pass `slider: true` and `value: currentValue` to `Testable`

### Testing Patterns

- **During recording:** Use `tester.pump(duration)` instead of `pumpAndSettle()` — continuous frame callbacks prevent settling
- **Dial values:** Use `tester.state<CameraRulerDialState>(find.byKey(key)).setValue(800)` to set dial values programmatically
- **Camera state:** Query via `ext.test.cameraState` service extension in debug builds
- **Semantics verification:** Wrap app with `SemanticsDebugger(child: CameraApp())` during development to visualize what's exposed to accessibility tools and ADB
