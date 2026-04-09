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

- **Always read error logs first.** When debugging frame delivery, GPU, or Camera2 failures, request and read logcat output IMMEDIATELY before proposing hypotheses. Logs are the primary diagnostic tool — they pinpoint the exact component failure. Do not skip this even for "obvious" issues.
- **Never leave TODOs for required behavior.** If a plan says to call an API and you can't find it, search broadly (`grep -r` across `packages/cambrian_camera/`). Only report NEEDS_CONTEXT after exhaustive search. Do not comment out calls or stub them.
- **Match surrounding patterns.** Find 2-3 similar functions and match their threading, error handling, and state notification patterns. Code samples in plans are sketches — the codebase is the source of truth for HOW to implement.
- **State notifications are mandatory.** Any path that changes camera, recording, or error state MUST notify Dart via `flutterApi.*` posted on `mainHandler`.
- **Verify before claiming "doesn't exist."** Fields may be far from your edit site in a large file.
- **Comment magic numbers and non-obvious scaling.** Any constant multiplier, threshold, or range remapping MUST have an inline comment explaining WHY it exists. Bare `* 0.5` or `+ 0.1` without context is unacceptable — future readers cannot reverse-engineer the intent.
