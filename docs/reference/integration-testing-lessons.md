# Integration Testing: Lessons Learned

<!-- LLM SUMMARY
This document covers the integration test infrastructure for camera2_flutter_demo, a Flutter app that drives Android Camera2 hardware directly. It is useful when: adding new tests, debugging test failures, understanding why certain tools/approaches are forbidden, or troubleshooting permission or connectivity issues.

Topics covered:
- Why integration_test was chosen over flutter_driver and flutter_drive
- How WidgetRegistry, Testable, and keys/ files work together
- The two-part permission solution (adb install -r -g + RUNNING_TESTS dart-define)
- Why flutter test over WiFi ADB loops; how mcp__dart__run_tests fixes it
- run_tests.sh as the canonical test runner and its required step order
- Common pitfalls with concrete fixes
- Pump timing patterns for animations and recording
-->

---

## Table of Contents

1. [What We're Building and Why](#what-were-building-and-why)
2. [Architecture Overview](#architecture-overview)
3. [What We Tried and What Failed](#what-we-tried-and-what-failed)
4. [The Permission Problem](#the-permission-problem)
5. [Widget Keys and the Registry](#widget-keys-and-the-registry)
6. [Running Tests Over WiFi ADB](#running-tests-over-wifi-adb)
7. [Common Pitfalls](#common-pitfalls)
8. [Ideal Patterns](#ideal-patterns)

---

## What We're Building and Why

camera2_flutter_demo is a real-time camera control app built on a custom `cambrian_camera` plugin that drives Camera2 directly from Kotlin and a C++ GPU pipeline. The UI exposes ISO, shutter, focus, white balance, zoom, and GPU processing controls over a live viewfinder.

Bugs in this stack tend to be silent — the camera stops opening, recording silently fails, or state is left dirty between tests. Regressions are only caught when a human notices. The integration test suite is designed to automate the user-facing paths: open settings, tap chips, start/stop recording, and assert the app responds correctly at each step.

We chose on-device integration tests (not unit tests) because the interesting failures happen at the Flutter/native boundary — and those only activate with real Camera2 hardware.

---

## Architecture Overview

### How it fits together

```
integration_test/
  app_test.dart                  # test entry point
  helpers/camera_test_helpers.dart  # tapEntry, openSettings, startRecording, …

lib/testing/
  widget_registry.dart           # WidgetRegistry singleton + WidgetEntry
  testable.dart                  # Testable widget wrapper (key + semantics)
  test_channel.dart              # ext.test.cameraState service extension (debug only)
  keys/
    bottom_bar_keys.dart
    camera_settings_bar_keys.dart
    camera_control_keys.dart
    gpu_controls_sidebar_keys.dart

scripts/
  run_tests.sh                   # canonical test runner — always use this
  wake_and_launch.sh             # device wake/unlock (called by run_tests.sh)
```

`lib/testing/` is separated from `lib/widgets/` so test infrastructure doesn't pollute widget code. The `keys/` subdirectory groups key registrations by area.

### Key components

| Component | Role |
|-----------|------|
| `WidgetRegistry` | Singleton; creates and stores all `WidgetEntry` instances; enforces unique IDs via `assert` |
| `WidgetEntry` | Holds an ID, `ValueKey`, label, and description for one testable widget |
| `Testable` | Widget wrapper; applies the `ValueKey` and a `Semantics` node from the registry entry |
| `keys/*_keys.dart` | Top-level `final` variables that call `WidgetRegistry.register()`; one file per widget group |
| `run_tests.sh` | Builds with `RUNNING_TESTS=true`, installs with `-g`, then runs tests |

### The test runner workflow

`run_tests.sh` runs these steps in order — skipping any step breaks something:

| Step | Command | Why it matters |
|------|---------|----------------|
| Wake device | `wake_and_launch.sh` | Tests fail on a locked screen |
| Build APK | `flutter build apk --debug --dart-define=RUNNING_TESTS=true` | Compiles the no-dialog permission guard into the app |
| Grant permissions | `adb install -r -g` | Pre-grants CAMERA before the app ever runs |
| Run tests | `flutter test ... --dart-define=RUNNING_TESTS=true` | Passes the flag to the test shim as well |

---

## What We Tried and What Failed

We went through several frameworks and approaches before landing on the current setup. Here's the full history.

### Framework choices

| Approach | What happened | Root cause | Decision |
|----------|-------------|------------|----------|
| `flutter_driver` | Times out during recording | Camera2 frame callbacks prevent the engine from ever going idle; driver's wait-for-idle hangs | Abandoned; removed from project |
| `flutter drive --use-application-binary` | Times out immediately | `flutter drive` requires `enableFlutterDriverExtension()`; our tests use the `integration_test` binding — incompatible protocols | Abandoned |
| `integration_test` (in-process) | Works | Tests call `app.main()` inside `testWidgets`; direct widget access, no IPC; uses `pump(duration)` instead of wait-for-idle | **Current approach** |

### Permission granting

| Approach | What happened | Root cause | Decision |
|----------|-------------|------------|----------|
| `adb shell pm grant` | `SecurityException` | Android 16 blocks `pm grant` for dangerous permissions without root | Abandoned |
| Rely on `flutter test` to preserve permissions | Dialog appears; camera doesn't open | `flutter test` reinstalls without `-g`, resetting permissions on every run | Abandoned |
| `adb install -r -g` + `RUNNING_TESTS=true` dart-define | No dialog; camera opens | OS-level grant + compile-time flag that suppresses `request()` call in app code | **Current approach** |

### Test runner connectivity

| Approach | What happened | Root cause | Decision |
|----------|-------------|------------|----------|
| `flutter test ... -d 192.168.1.x` over WiFi | "test starting…" loop, never runs | VM service port forwarding is unreliable over TCP-based WiFi ADB | Avoid for interactive use |
| `mcp__dart__run_tests` MCP tool | Connects reliably | MCP tool manages the VM service connection differently | **Use for interactive iteration** |

### Small bugs found along the way

| Bug | Symptom | Fix |
|-----|---------|-----|
| `--use-application-binary` in `flutter test` | "unknown flag" error | Flag only exists in `flutter drive`, not `flutter test` |
| Concurrent `Permission.camera.request()` calls | `PlatformException("request already running")` | Catch exception, wait 500ms, re-check status |
| Lockscreen grep capturing wrong value | Script misread lock state | Changed to `-oE 'mDreamingLockscreen=(true|false)'` |
| `debugPrint` in test file | Compile error | Use `print()` or import `foundation.dart` explicitly |

---

## The Permission Problem

This was the hardest problem. The app needs camera permission to do anything useful in tests, but Android 16 makes it difficult to grant permissions programmatically.

### The failure chain

`flutter test` installs a fresh APK without `-g` → permissions reset → app calls `Permission.camera.request()` → system dialog appears → no one accepts it → camera never opens → tests pass but test nothing meaningful.

### The two-part solution

**Part 1 (OS level):** `adb install -r -g` grants all runtime permissions at install time. Works on Android 6+ including Android 16 without root. This is the only supported mechanism.

**Part 2 (app level):** Build with `--dart-define=RUNNING_TESTS=true`. The app checks this compile-time constant in `_openCamera()` and, when true, skips `Permission.camera.request()` entirely — only calling `Permission.camera.status`. If status isn't granted, it logs a clear message and returns rather than blocking on a dialog.

```dart
const bool runningTests = bool.fromEnvironment('RUNNING_TESTS');
if (runningTests) {
  status = await Permission.camera.status;
  if (!status.isGranted) {
    debugPrint('TEST MODE: camera not granted — use run_tests.sh');
    return;
  }
} else {
  // normal app: request permission if needed
}
```

**Why both parts are required:**

| Scenario | Result |
|----------|--------|
| Part 1 only (`-g` install, no dart-define) | Safe only if `run_tests.sh` installs. Any other tool reinstalls without `-g` and the dialog returns. |
| Part 2 only (dart-define, no `-g` install) | `status` is `denied`; camera never opens; tests fail. |
| Both together | OS says granted; app never asks the user. Solid. |

`bool.fromEnvironment` is **compile-time**, not runtime. A production build without the flag always has `runningTests == false`. There is no risk of accidentally suppressing permission dialogs in production.

---

## Widget Keys and the Registry

Plain `const ValueKey` constants work for finding widgets but carry no metadata, don't enforce uniqueness, and can't be enumerated. `WidgetRegistry` fixes all three.

### Why a registry

| Problem with plain constants | How registry solves it |
|-----------------------------|----------------------|
| No shared label for accessibility | `register()` takes a `label` used by both `Semantics` and test assertions |
| No guard against duplicate keys | `assert(!_entries.containsKey(id))` crashes immediately on duplicate |
| No way to enumerate testable widgets | `WidgetRegistry.instance.all` returns every registered entry |
| Key and semantics applied in two places | `Testable` is the single place that applies both |

### Lazy initialization behavior

Dart top-level `final` variables initialize on first access. Keys only register when their containing widget renders. Widgets behind conditional UI (GPU sidebar, WB segment, auto-toggle dial) won't appear in `WidgetRegistry.instance.all` until that UI is opened. Always use `greaterThanOrEqualTo` for count assertions, never an exact number.

### Key naming convention

`{area}.{widget}[.{sub}]` — for example: `chip.iso`, `gpu.black.r`, `bar.settings`, `hud.recording`. The area prefix groups related widgets for easy scanning.

---

## Running Tests Over WiFi ADB

| Method | Use case | Permission behavior |
|--------|----------|---------------------|
| `./scripts/run_tests.sh` | Clean runs, CI, any time you want guaranteed permission state | Builds + installs with `-g` + runs — fully self-contained |
| `mcp__dart__run_tests` MCP tool | Interactive iteration — reliable VM service over WiFi | Installs without `-g`; relies on a prior `run_tests.sh` install to have left permissions intact |

If the MCP tool is used after a fresh install (e.g., by Android Studio or another tool), run `run_tests.sh` first to restore the permission grant, then use MCP for subsequent iterations.

---

## Common Pitfalls

| Pitfall | What happens | Fix |
|---------|-------------|-----|
| Running `flutter test` directly | APK reinstalled without `-g` and without `RUNNING_TESTS=true`; permission dialog blocks tests | Always use `run_tests.sh` |
| Using `pumpAndSettle()` during recording | Hangs forever — frame callbacks prevent idle | Use `pump(duration)` |
| Exact registry count assertion | Flaky — count changes as conditional UI opens | Use `greaterThanOrEqualTo(N)` |
| Using `flutter drive` with `integration_test` tests | Times out — incompatible protocols | Only use `flutter test` |
| `debugPrint` in test files | Compile error | Use `print()`, or import explicitly |
| `pm grant` on Android 16 | `SecurityException` | Use `adb install -r -g` |
| Registering the same widget key twice | `assert` fires at startup | Check `lib/testing/keys/` for existing IDs |
| Omitting `--dart-define` from build step | `runningTests` compiles to `false`; dialog appears despite `-g` | Pass flag to both `flutter build apk` and `flutter test` |
| MCP tool run after a non-`run_tests.sh` install | Camera permission lost; camera doesn't open | Run `run_tests.sh` to restore grant |

---

## Ideal Patterns

### Pump timing

```dart
// Opening animated panels — settle, then extra time for IgnorePointer to clear
await tapEntry(tester, kBarSettings);
await tester.pumpAndSettle();
await tester.pump(const Duration(milliseconds: 500));

// During recording — explicit duration only, never pumpAndSettle
await tester.pump(const Duration(seconds: 1));
```

The 500ms after `pumpAndSettle()` matters: `IgnorePointer` widgets covering animated panels don't release until the animation fully completes, and `pumpAndSettle()` can declare victory slightly early.

### Recording tests

```dart
await startRecording(tester);                         // pump(1s) internally
expect(find.byKey(kHudRecording.key), findsOneWidget);
await tester.pump(const Duration(seconds: 3));        // let recording run
await stopRecording(tester);                          // pump(3s) for encoder flush
```

The 3-second wait in `stopRecording` covers the MediaRecorder encoder flush. Asserting on output before the flush completes gives inconsistent results.

### Setting dial values programmatically

```dart
final dialState = tester.state<CameraRulerDialState>(find.byKey(kDialIso.key));
dialState.setValue(800.0);
await tester.pump();
```

`CameraRulerDialState` is public and `@visibleForTesting` for this purpose. Simulating drag gestures on the dial is fragile due to velocity sensitivity; `setValue` is the reliable path.

### Verifying semantics during development

```dart
runApp(SemanticsDebugger(child: CameraApp()));
```

`SemanticsDebugger` renders the `Semantics` labels from `Testable` wrappers as on-screen overlays — useful for verifying every widget has the right label before writing assertions against them.
