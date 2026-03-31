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

## Important Notes

- This is a Flutter demo project for the camera2 library
- Platform-specific implementations belong in `android/` and `ios/` directories
- Follow Flutter style conventions enforced by `flutter_lints`
- Do not use wildcard imports; always import explicit symbols
  - **Dart:** use `show`/`hide` (e.g. `import 'package:foo/bar.dart' show MyClass;`)
  - **Kotlin/Java:** no wildcard imports (e.g. avoid `import x.y.*`)
- Use `flutter pub get` after modifying `pubspec.yaml`

## Useful Flutter Commands

- `flutter doctor` — Verify Flutter setup
- `flutter devices` — List available devices/emulators
- `flutter pub upgrade` — Update dependencies to latest versions
