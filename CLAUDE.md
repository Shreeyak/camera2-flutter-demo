# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Quick Start

```bash
flutter pub get              # Install dependencies
flutter run                 # Run app (will prompt for device selection)
flutter run -d <device_id>  # Run on specific device/emulator
```

## Building & Running

**Development:**
```bash
flutter run                    # Debug mode (default)
flutter run -d chrome         # Run on web (requires web support)
flutter run --release        # Release mode
```

**Android:**
```bash
flutter build apk            # Build APK
flutter build appbundle      # Build App Bundle for Play Store
```

**iOS:**
```bash
flutter build ios            # Build iOS app
flutter build ipa            # Build IPA for App Store
```

## Testing & Linting

```bash
flutter test                 # Run all tests in test/ directory
flutter analyze              # Run Dart analyzer (uses flutter_lints rules)
dart format lib/            # Format code to match Flutter conventions
```

## Project Structure

- **`lib/`** — Dart source code (entry point: `main.dart`)
- **`android/`** — Android native code (gradle build config)
- **`ios/`** — iOS native code and Xcode project
- **`pubspec.yaml`** — Flutter dependencies and project metadata
- **`analysis_options.yaml`** — Linting rules (extends `package:flutter_lints`)

## Reference Documentation
  Camera2 API reference is at:
  ~/work/cambrian/eva-ref/camera2-docs-scrape/output/

  - API classes: output/api-reference/camera2/ClassName.md
  - Params: output/api-reference/camera2-params/ClassName.md
  - Architecture guides: output/guides/camera/
  - Search index: output/MANIFEST.json

## Important Notes

- This is a Flutter demo project for the camera2 library
- Platform-specific implementations belong in `android/` and `ios/` directories
- Follow Flutter style conventions enforced by `flutter_lints`
- Do not use wildcard imports; always import explicit symbols
  - **Dart:** use `show`/`hide` (e.g. `import 'package:foo/bar.dart' show MyClass;`)
  - **Kotlin/Java:** no wildcard imports (e.g. avoid `import x.y.*`)
- Use `flutter pub get` after modifying `pubspec.yaml`

## OpenCV (Android)

The native pipeline uses OpenCV. The SDK is **not** checked in; it is symlinked from a host build:

```bash
ln -s <OPENCV_ANDROID_SDK_PATH> \
      packages/cambrian_camera/android/opencv
```

Replace `<OPENCV_ANDROID_SDK_PATH>` with the absolute path to your OpenCV Android SDK (e.g. `$HOME/software/opencv-build-android/opencv-android-sdk`).

Run this once per worktree clone. The symlink is git-ignored. Without it, the NDK build will fail with a missing `OpenCV_DIR` error.

## Useful Flutter Commands

- `flutter doctor` — Verify Flutter setup
- `flutter devices` — List available devices/emulators
- `flutter pub upgrade` — Update dependencies to latest versions
