# Test Infrastructure for Autonomous UI Testing

**Date:** 2026-04-07
**Status:** Approved

## Problem

The app has no test infrastructure for automated UI testing. Flutter Driver times out during recording (continuous frame callbacks prevent idle state). All 21 interactive widgets lack stable keys, making finder-based testing fragile. No programmatic way to query camera state — verification requires grepping logcat.

## Changes Since PR #16 That Need Testing

| PR | Feature |
|----|---------|
| #17 | Hardened diagnostic logging |
| #18 | Self-healing camera pipeline |
| #19 | PAUSED state + pause()/resume() API |
| #20 | Lightweight pause/resume + frame stall watchdog |
| #21 | Strip CPU pipeline, add ProcessingStage hook |
| #22 | PBO sync with GL fences and timing queries |
| #23 | Lifecycle hotfix (availability callback, background suspend, thread-safe close) |
| #24 | Restrict LogLevelReceiver to debug builds |
| #25 | FPS degradation detection outside verboseDiagnostics gate |
| #26 | GpuRenderer diagnostic logging and GL extension safety |
| #27 | Log lifecycle observer failures |
| #28 | nativeInit try/catch for JNI safety |
| #29 | Pause/recording safety and KDoc accuracy |
| #30 | Stall watchdog fires on zero-frame sessions |
| — | Settings persistence across sessions (SettingsStore) |

## Design

### 1. Self-Registering Widget Registry

A central `WidgetRegistry` singleton where every interactive widget registers itself. Registration is the **only** way to obtain a `ValueKey` — this makes drift impossible.

**File:** `lib/testing/widget_registry.dart`

```dart
class WidgetEntry {
  final String id;          // e.g. 'bar.settings'
  final String label;       // semantics label
  final String description; // for docs/tests
  late final ValueKey<String> key = ValueKey(id);

  const WidgetEntry({required this.id, required this.label, required this.description});
}

class WidgetRegistry {
  static final instance = WidgetRegistry._();
  WidgetRegistry._();

  final Map<String, WidgetEntry> _entries = {};

  WidgetEntry register({
    required String id,
    required String label,
    required String description,
  }) {
    assert(!_entries.containsKey(id), 'Duplicate widget id: $id');
    final entry = WidgetEntry(id: id, label: label, description: description);
    _entries[id] = entry;
    return entry;
  }

  Map<String, WidgetEntry> get all => Map.unmodifiable(_entries);
}
```

**ID naming convention:** dot-separated hierarchy `{area}.{widget}[.{sub}]`

### 2. Testable Wrapper Widget

Applies both `ValueKey` and `Semantics` from a registry entry. Supports a `slider` flag for slider-type widgets to expose proper accessibility semantics.

**File:** `lib/testing/testable.dart`

```dart
class Testable extends StatelessWidget {
  final WidgetEntry entry;
  final Widget child;
  final bool slider;
  final String? value;

  const Testable({
    required this.entry,
    required this.child,
    this.slider = false,
    this.value,
  }) : super(key: entry.key);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: entry.label,
      slider: slider,
      value: value,
      child: child,
    );
  }
}
```

For slider widgets, use `slider: true` and pass the current value string so ADB accessibility tools can also read the state:

```dart
Testable(
  entry: kGpuBrightness,
  slider: true,
  value: '${brightness.toStringAsFixed(2)}',
  child: Slider(...),
)
```

### 3. Complete Widget Key Map

All 21 interactive widgets registered at their definition sites:

| ID | Widget | File |
|----|--------|------|
| `bar.settings` | SETTINGS button | bottom_bar.dart |
| `bar.calibrate` | CALIBRATE COLOR button | bottom_bar.dart |
| `bar.record` | RECORD/STOP button | bottom_bar.dart |
| `bar.close` | CLOSE button | camera_settings_bar.dart |
| `chip.iso` | ISO chip | camera_settings_bar.dart |
| `chip.shutter` | SHUTTER chip | camera_settings_bar.dart |
| `chip.focus` | FOCUS chip | camera_settings_bar.dart |
| `chip.wb` | WB chip | camera_settings_bar.dart |
| `chip.zoom` | ZOOM chip | camera_settings_bar.dart |
| `dial.auto_toggle` | Auto/Manual toggle | main.dart |
| `dial.wb_segment` | WB auto/lock segmented button | camera_control_overlay.dart |
| `gpu.brightness` | Brightness slider | gpu_controls_sidebar.dart |
| `gpu.contrast` | Contrast slider | gpu_controls_sidebar.dart |
| `gpu.saturation` | Saturation slider | gpu_controls_sidebar.dart |
| `gpu.gamma` | Gamma slider | gpu_controls_sidebar.dart |
| `gpu.black.r` | Black R slider | gpu_controls_sidebar.dart |
| `gpu.black.g` | Black G slider | gpu_controls_sidebar.dart |
| `gpu.black.b` | Black B slider | gpu_controls_sidebar.dart |
| `gpu.reset_all` | Reset all button | gpu_controls_sidebar.dart |
| `hud.recording` | Recording HUD | recording_hud.dart |

### 4. Integration Test Framework

Replace `flutter_driver` (out-of-process, times out during recording) with `integration_test` (in-process, direct widget access).

**Dependencies:**

```yaml
# pubspec.yaml
dev_dependencies:
  integration_test:
    sdk: flutter
  flutter_test:
    sdk: flutter
```

**Structure:**

```
integration_test/
  app_test.dart                    # Main test entry point
  helpers/
    test_app.dart                  # App launcher with test bindings + ensureSemantics
    camera_test_helpers.dart       # Reusable actions (openSettings, tapChip, etc.)
```

**Force semantics on in test builds** to ensure the Semantics tree is populated (enables both integration_test and fallback ADB/uiautomator testing):

```dart
// integration_test/helpers/test_app.dart
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  // Force semantics tree so widgets are exposed to Android accessibility
  binding.ensureSemantics();
  // ... tests
}
```

**Key pattern:** Use `tester.pump(duration)` instead of `pumpAndSettle()` when recording is active, since continuous frame callbacks prevent settle.

**Test helper examples:**

```dart
Future<void> openSettings(WidgetTester tester) async {
  await tester.tap(find.byKey(kBarSettings.key));
  await tester.pumpAndSettle();
}

Future<void> startRecording(WidgetTester tester) async {
  await tester.tap(find.byKey(kBarRecord.key));
  await tester.pump(const Duration(seconds: 1));
}

Future<void> stopRecording(WidgetTester tester) async {
  await tester.tap(find.byKey(kBarRecord.key));
  await tester.pump(const Duration(seconds: 3)); // wait for encoder flush
}
```

**Run on device:** `flutter test integration_test/ -d <device-id>`

**SemanticsDebugger for development:** During development, temporarily wrap the app to visualize what's exposed to accessibility/ADB:

```dart
// Temporary — remove before committing
SemanticsDebugger(child: CameraApp())
```

The mental model: if `SemanticsDebugger` highlights it, `find.bySemanticsLabel()` can find it, and `adb shell uiautomator dump` can see it.

### 5. Camera State Test Channel

Debug-only service extension for programmatic state queries:

**File:** `lib/testing/test_channel.dart`

```dart
class TestChannel {
  static void register(_CameraScreenState state) {
    developer.registerExtension('ext.test.cameraState', (method, params) async {
      return ServiceExtensionResponse.result(jsonEncode({
        'isStreaming': state._camera != null,
        'isRecording': state._isRecording,
        'iso': state._values.isoValue,
        'exposureTimeNs': state._values.exposureTimeNs,
        'aeSeeded': state._aeSeeded,
      }));
    });
  }
}
```

### 6. CameraRulerDial Programmatic Value Setting

Add a `setValue(double)` method to `CameraRulerDialState` for tests:

```dart
void setValue(double value) {
  final clampedTick = ((value - widget.minValue) / widget.tickSpacing).round();
  _scrollToTick(clampedTick, animate: false);
  widget.onChanged?.call(_tickToValue(clampedTick));
}
```

Tests access it via: `tester.state<CameraRulerDialState>(find.byKey(...)).setValue(800)`

### 7. CLAUDE.md Updates

Add a new `## Testing` section to CLAUDE.md covering:
- Widget registry location (`lib/testing/widget_registry.dart`) and naming convention
- Complete widget map table (generated from registry)
- How to run integration tests (`flutter test integration_test/ -d <device-id>`)
- Pattern: `pump()` vs `pumpAndSettle()` during recording
- How to register new widgets (for future development)
- How to verify semantics with `SemanticsDebugger`
- Note: `integration_test` is in-process, `flutter_driver` is deprecated in this project

Add a new `## Widget Map` section to `docs/usage-guide.md` with the full registry table so it stays alongside the public API docs.

### 8. Cleanup

- Remove `lib/driver_main.dart`
- Remove `flutter_driver` dependency from `pubspec.yaml`
- Replace with `integration_test` dependency

## Test Scenarios

1. **Basic launch** — camera opens, both textures render
2. **Settings controls** — each chip opens its dial
3. **Settings persistence** — change setting, kill app, verify on relaunch
4. **Recording** — start, verify HUD, stop, verify file exists
5. **Pause/Resume** — background app, foreground, camera recovers
6. **Self-healing stress** — rapid lifecycle cycles
7. **Stall watchdog** — verify via test channel that FPS stays healthy
8. **GPU controls** — open sidebar, adjust sliders, verify params
