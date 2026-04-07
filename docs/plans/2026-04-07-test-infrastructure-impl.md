# Test Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add self-registering widget keys, semantics, integration_test framework, camera state test channel, and dial programmatic API so that all 21 interactive widgets are testable autonomously.

**Architecture:** A `WidgetRegistry` singleton provides the only way to create `ValueKey`s for interactive widgets, enforcing zero-drift between key definitions and metadata. A `Testable` wrapper applies both key and semantics from a registry entry. `integration_test` replaces `flutter_driver` for in-process on-device testing.

**Tech Stack:** Flutter `integration_test`, `Semantics` API, `dart:developer` service extensions

---

### Task 1: Create Widget Registry

**Files:**
- Create: `lib/testing/widget_registry.dart`

- [ ] **Step 1: Create the registry file**

```dart
// lib/testing/widget_registry.dart
import 'package:flutter/foundation.dart' show ValueKey;

/// Metadata for a registered interactive widget.
///
/// Every interactive widget in the app must register via [WidgetRegistry] to
/// obtain a [ValueKey]. This enforces a 1:1 mapping between keys and metadata,
/// preventing drift between code and documentation.
class WidgetEntry {
  /// Dot-separated hierarchy, e.g. `bar.settings`, `chip.iso`.
  final String id;

  /// Accessibility / semantics label, e.g. `Settings`.
  final String label;

  /// Human-readable purpose, used in generated docs.
  final String description;

  /// The stable [ValueKey] derived from [id].
  late final ValueKey<String> key = ValueKey<String>(id);

  WidgetEntry({
    required this.id,
    required this.label,
    required this.description,
  });
}

/// Singleton registry of all interactive widgets.
///
/// Usage at widget definition site:
/// ```dart
/// final kBarSettings = WidgetRegistry.instance.register(
///   id: 'bar.settings',
///   label: 'Settings',
///   description: 'Opens camera settings panel',
/// );
/// ```
class WidgetRegistry {
  WidgetRegistry._();

  /// The singleton instance.
  static final instance = WidgetRegistry._();

  final Map<String, WidgetEntry> _entries = {};

  /// Register a widget and return its [WidgetEntry].
  ///
  /// Asserts that [id] is unique — duplicate IDs are a programming error.
  WidgetEntry register({
    required String id,
    required String label,
    required String description,
  }) {
    assert(
      !_entries.containsKey(id),
      'Duplicate widget id: $id',
    );
    final entry = WidgetEntry(id: id, label: label, description: description);
    _entries[id] = entry;
    return entry;
  }

  /// All registered entries, keyed by id. Unmodifiable.
  Map<String, WidgetEntry> get all => Map.unmodifiable(_entries);
}
```

- [ ] **Step 2: Verify it compiles**

Run: `flutter analyze lib/testing/widget_registry.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add lib/testing/widget_registry.dart
git commit -m "feat: add WidgetRegistry for self-registering widget keys"
```

---

### Task 2: Create Testable Wrapper Widget

**Files:**
- Create: `lib/testing/testable.dart`

- [ ] **Step 1: Create the Testable widget**

```dart
// lib/testing/testable.dart
import 'package:flutter/material.dart' show Semantics, StatelessWidget, Widget, BuildContext;

import 'widget_registry.dart' show WidgetEntry;

/// Wraps a child widget with both a [ValueKey] (from the registry entry)
/// and a [Semantics] node.
///
/// For slider-type widgets, set [slider] to `true` and pass the current
/// [value] string so accessibility tools can read the slider state.
///
/// ```dart
/// Testable(
///   entry: kGpuBrightness,
///   slider: true,
///   value: brightness.toStringAsFixed(2),
///   child: Slider(...),
/// )
/// ```
class Testable extends StatelessWidget {
  final WidgetEntry entry;
  final Widget child;

  /// Whether this wraps a slider-type widget.
  final bool slider;

  /// Current value string exposed to accessibility (e.g. `"0.42"`).
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

- [ ] **Step 2: Verify it compiles**

Run: `flutter analyze lib/testing/testable.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add lib/testing/testable.dart
git commit -m "feat: add Testable wrapper for key + semantics"
```

---

### Task 3: Register Bottom Bar Buttons

**Files:**
- Modify: `lib/widgets/bottom_bar.dart:115-135`
- Create: `lib/widgets/bottom_bar_keys.dart`

- [ ] **Step 1: Create key registrations**

```dart
// lib/widgets/bottom_bar_keys.dart
import '../testing/widget_registry.dart' show WidgetRegistry;

final kBarSettings = WidgetRegistry.instance.register(
  id: 'bar.settings',
  label: 'Settings',
  description: 'Opens camera settings panel',
);

final kBarCalibrate = WidgetRegistry.instance.register(
  id: 'bar.calibrate',
  label: 'Calibrate color',
  description: 'Toggles GPU post-processing sidebar',
);

final kBarRecord = WidgetRegistry.instance.register(
  id: 'bar.record',
  label: 'Record video',
  description: 'Starts or stops video recording',
);
```

- [ ] **Step 2: Wrap buttons in Testable in bottom_bar.dart**

Add import at top of `lib/widgets/bottom_bar.dart`:

```dart
import '../testing/testable.dart' show Testable;
import 'bottom_bar_keys.dart' show kBarSettings, kBarCalibrate, kBarRecord;
```

Replace the three `BottomBarActionButton` instantiations in `_MainActionBar.build()` (lines 115–135). The `Row` children become:

```dart
              children: [
                Testable(
                  entry: kBarSettings,
                  child: BottomBarActionButton(
                    icon: Icons.tune,
                    label: 'SETTINGS',
                    isDisabled: !isSettingsEnabled,
                    onTap: onToggleSettings,
                  ),
                ),
                const SizedBox(width: 16),
                Testable(
                  entry: kBarCalibrate,
                  child: BottomBarActionButton(
                    icon: Icons.palette,
                    label: 'CALIBRATE COLOR',
                    isDisabled: false,
                    onTap: onToggleGpuControls,
                  ),
                ),
                const SizedBox(width: 16),
                Testable(
                  entry: kBarRecord,
                  child: BottomBarActionButton(
                    icon: isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
                    label: isRecording ? 'STOP' : 'RECORD',
                    isActive: isRecording,
                    isDisabled: false,
                    onTap: onToggleRecording,
                  ),
                ),
              ],
```

- [ ] **Step 3: Verify it compiles**

Run: `flutter analyze lib/widgets/bottom_bar.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/bottom_bar_keys.dart lib/widgets/bottom_bar.dart
git commit -m "feat: register bottom bar buttons with WidgetRegistry"
```

---

### Task 4: Register Settings Bar Widgets (CLOSE + 5 Chips)

**Files:**
- Modify: `lib/widgets/camera_settings_bar.dart:46-116`
- Create: `lib/widgets/camera_settings_bar_keys.dart`

- [ ] **Step 1: Create key registrations**

```dart
// lib/widgets/camera_settings_bar_keys.dart
import '../testing/widget_registry.dart' show WidgetRegistry;

final kBarClose = WidgetRegistry.instance.register(
  id: 'bar.close',
  label: 'Close settings',
  description: 'Closes camera settings panel',
);

final kChipIso = WidgetRegistry.instance.register(
  id: 'chip.iso',
  label: 'ISO setting',
  description: 'Selects ISO setting dial',
);

final kChipShutter = WidgetRegistry.instance.register(
  id: 'chip.shutter',
  label: 'Shutter setting',
  description: 'Selects shutter speed setting dial',
);

final kChipFocus = WidgetRegistry.instance.register(
  id: 'chip.focus',
  label: 'Focus setting',
  description: 'Selects focus distance setting dial',
);

final kChipWb = WidgetRegistry.instance.register(
  id: 'chip.wb',
  label: 'White balance setting',
  description: 'Selects white balance control',
);

final kChipZoom = WidgetRegistry.instance.register(
  id: 'chip.zoom',
  label: 'Zoom setting',
  description: 'Selects zoom ratio setting dial',
);
```

- [ ] **Step 2: Wrap widgets in camera_settings_bar.dart**

Add imports at top of `lib/widgets/camera_settings_bar.dart`:

```dart
import '../testing/testable.dart' show Testable;
import 'camera_settings_bar_keys.dart'
    show kBarClose, kChipIso, kChipShutter, kChipFocus, kChipWb, kChipZoom;
```

Wrap the CLOSE button (line 46) in `Testable`:

```dart
              Testable(
                entry: kBarClose,
                child: BottomBarActionButton(
                  icon: Icons.keyboard_arrow_down,
                  label: 'CLOSE',
                  onTap: onToggleSettings,
                ),
              ),
```

Wrap each `CameraSettingChip` in `Testable`. For ISO (line 60):

```dart
                      Testable(
                        entry: kChipIso,
                        child: CameraSettingChip(
                          icon: Icons.iso,
                          label: 'ISO',
                          valueLabel: values.isoValue.toString(),
                          isActive: activeSetting == CameraSettingType.iso,
                          onTap: () => onSettingChipTap(
                            activeSetting == CameraSettingType.iso
                                ? null
                                : CameraSettingType.iso,
                          ),
                        ),
                      ),
```

Repeat the same `Testable` wrapping pattern for SHUTTER (`kChipShutter`), FOCUS (`kChipFocus`), WB (`kChipWb`), ZOOM (`kChipZoom`).

- [ ] **Step 3: Verify it compiles**

Run: `flutter analyze lib/widgets/camera_settings_bar.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/camera_settings_bar_keys.dart lib/widgets/camera_settings_bar.dart
git commit -m "feat: register settings bar CLOSE button and 5 setting chips"
```

---

### Task 5: Register Auto Toggle, WB Segment, and Recording HUD

**Files:**
- Modify: `lib/main.dart:548-551`
- Modify: `lib/widgets/camera_control_overlay.dart:123-149`
- Modify: `lib/widgets/recording_hud.dart:163-182`
- Create: `lib/widgets/camera_control_keys.dart`

- [ ] **Step 1: Create key registrations**

```dart
// lib/widgets/camera_control_keys.dart
import '../testing/widget_registry.dart' show WidgetRegistry;

final kDialAutoToggle = WidgetRegistry.instance.register(
  id: 'dial.auto_toggle',
  label: 'Auto/manual toggle',
  description: 'Toggles between auto and manual mode for the active setting',
);

final kDialWbSegment = WidgetRegistry.instance.register(
  id: 'dial.wb_segment',
  label: 'White balance mode',
  description: 'Switches between auto white balance and locked white balance',
);

final kHudRecording = WidgetRegistry.instance.register(
  id: 'hud.recording',
  label: 'Recording status',
  description: 'Shows recording timer, saving progress, or hidden',
);
```

- [ ] **Step 2: Wrap CameraAutoToggleButton in main.dart**

Add imports at top of `lib/main.dart`:

```dart
import 'testing/testable.dart' show Testable;
import 'widgets/camera_control_keys.dart' show kDialAutoToggle, kHudRecording;
```

Wrap the `CameraAutoToggleButton` (line 548):

```dart
                              child: Testable(
                                entry: kDialAutoToggle,
                                child: CameraAutoToggleButton(
                                  isAuto: _isAutoMode(_activeSetting),
                                  onTap: () => _onAutoToggleTap(_activeSetting),
                                ),
                              ),
```

Wrap the `RecordingHud` (around line 512):

```dart
                        child: Testable(
                          entry: kHudRecording,
                          child: RecordingHud(
                            stateStream: _camera?.recordingStateStream ?? const Stream.empty(),
                            displayName: _recordingDisplayName,
                            outputDir: _recordingOutputDir,
                          ),
                        ),
```

- [ ] **Step 3: Wrap SegmentedButton in camera_control_overlay.dart**

Add imports at top of `lib/widgets/camera_control_overlay.dart`:

```dart
import '../testing/testable.dart' show Testable;
import 'camera_control_keys.dart' show kDialWbSegment;
```

Wrap the `SegmentedButton<bool>` (line 123):

```dart
    return Center(
      child: Testable(
        entry: kDialWbSegment,
        child: SegmentedButton<bool>(
          // ... existing code unchanged ...
        ),
      ),
    );
```

- [ ] **Step 4: Verify it compiles**

Run: `flutter analyze lib/main.dart lib/widgets/camera_control_overlay.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/camera_control_keys.dart lib/main.dart lib/widgets/camera_control_overlay.dart
git commit -m "feat: register auto toggle, WB segment, and recording HUD"
```

---

### Task 6: Register GPU Sidebar Sliders and Reset Button

**Files:**
- Modify: `lib/widgets/gpu_controls_sidebar.dart:66-145, 174-215`
- Create: `lib/widgets/gpu_controls_sidebar_keys.dart`

- [ ] **Step 1: Create key registrations**

```dart
// lib/widgets/gpu_controls_sidebar_keys.dart
import '../testing/widget_registry.dart' show WidgetRegistry;

final kGpuBrightness = WidgetRegistry.instance.register(
  id: 'gpu.brightness',
  label: 'Brightness',
  description: 'Adjusts image brightness (-1.0 to 1.0)',
);

final kGpuContrast = WidgetRegistry.instance.register(
  id: 'gpu.contrast',
  label: 'Contrast',
  description: 'Adjusts image contrast (-1.0 to 1.0)',
);

final kGpuSaturation = WidgetRegistry.instance.register(
  id: 'gpu.saturation',
  label: 'Saturation',
  description: 'Adjusts image saturation (-1.0 to 1.0)',
);

final kGpuGamma = WidgetRegistry.instance.register(
  id: 'gpu.gamma',
  label: 'Gamma',
  description: 'Adjusts gamma curve (0.1 to 4.0)',
);

final kGpuBlackR = WidgetRegistry.instance.register(
  id: 'gpu.black.r',
  label: 'Black balance red',
  description: 'Adjusts red black point (0.0 to 0.5)',
);

final kGpuBlackG = WidgetRegistry.instance.register(
  id: 'gpu.black.g',
  label: 'Black balance green',
  description: 'Adjusts green black point (0.0 to 0.5)',
);

final kGpuBlackB = WidgetRegistry.instance.register(
  id: 'gpu.black.b',
  label: 'Black balance blue',
  description: 'Adjusts blue black point (0.0 to 0.5)',
);

final kGpuResetAll = WidgetRegistry.instance.register(
  id: 'gpu.reset_all',
  label: 'Reset all processing',
  description: 'Resets all GPU processing parameters to defaults',
);
```

- [ ] **Step 2: Add a `widgetKey` parameter to `_ShaderSlider`**

In `lib/widgets/gpu_controls_sidebar.dart`, the `_ShaderSlider` is a private widget (line ~148). Add a `ValueKey<String>?` parameter and apply it to the `Slider`:

Find the `_ShaderSlider` constructor (around line 148):

```dart
class _ShaderSlider extends StatelessWidget {
  const _ShaderSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.valueLabel,
    required this.onChanged,
    this.activeColor,
    this.sliderKey,
    this.semanticsLabel,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final double defaultValue;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final Color? activeColor;
  final ValueKey<String>? sliderKey;
  final String? semanticsLabel;
```

Wrap the `Slider` widget (line 206) with `Semantics`:

```dart
            child: Semantics(
              label: semanticsLabel,
              slider: true,
              value: valueLabel,
              child: Slider(
                key: sliderKey,
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
```

- [ ] **Step 3: Pass keys and labels to each _ShaderSlider instantiation**

Add imports at top of `lib/widgets/gpu_controls_sidebar.dart`:

```dart
import 'gpu_controls_sidebar_keys.dart'
    show kGpuBrightness, kGpuContrast, kGpuSaturation, kGpuGamma,
         kGpuBlackR, kGpuBlackG, kGpuBlackB, kGpuResetAll;
```

Update each `_ShaderSlider(` call to include `sliderKey` and `semanticsLabel`. For Brightness (line 66):

```dart
            _ShaderSlider(
              label: 'Brightness',
              value: params.brightness,
              min: -1.0,
              max: 1.0,
              defaultValue: 0.0,
              valueLabel: params.brightness.toStringAsFixed(2),
              onChanged: (v) => onChanged(params.copyWith(brightness: v)),
              sliderKey: kGpuBrightness.key,
              semanticsLabel: kGpuBrightness.label,
            ),
```

Repeat for Contrast (`kGpuContrast`), Saturation (`kGpuSaturation`), Gamma (`kGpuGamma`), Black R (`kGpuBlackR`), Black G (`kGpuBlackG`), Black B (`kGpuBlackB`).

- [ ] **Step 4: Wrap Reset All button**

Add import for Testable:

```dart
import '../testing/testable.dart' show Testable;
```

Wrap the `OutlinedButton.icon` (line 141):

```dart
            Testable(
              entry: kGpuResetAll,
              child: OutlinedButton.icon(
                onPressed: () => onChanged(ProcessingParams()),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Reset all'),
              ),
            ),
```

- [ ] **Step 5: Verify it compiles**

Run: `flutter analyze lib/widgets/gpu_controls_sidebar.dart`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add lib/widgets/gpu_controls_sidebar_keys.dart lib/widgets/gpu_controls_sidebar.dart
git commit -m "feat: register GPU sidebar sliders and reset button"
```

---

### Task 7: Add CameraRulerDial Programmatic setValue()

**Files:**
- Modify: `lib/widgets/camera_ruler_dial/camera_ruler_dial.dart:55-153`

- [ ] **Step 1: Add setValue method to _CameraRulerDialState**

In `lib/widgets/camera_ruler_dial/camera_ruler_dial.dart`, add this method after `_snapToNearest()` (after line 153):

```dart
  // ── Test API ──────────────────────────────────────────────────────────────

  /// Programmatically sets the dial to [value], snapping to the nearest stop.
  ///
  /// Fires [CameraRulerDial.onChanged] with the snapped value. Intended for
  /// integration tests via `tester.state<CameraRulerDialState>(finder).setValue(v)`.
  void setValue(double value) {
    final closestValue = widget.config.closestTo(value);
    final idx = widget.config.stops.indexOf(closestValue);
    final clampedIdx = idx.clamp(0, widget.config.stopCount - 1);
    setState(() {
      _visualPercent = widget.config.indexToPercent(clampedIdx);
      _lastTickIndex = clampedIdx;
    });
    widget.onChanged(widget.config.stops[clampedIdx]);
  }
```

Also make the state class public so tests can reference it in `tester.state<CameraRulerDialState>(...)`:

- Rename `_CameraRulerDialState` → `CameraRulerDialState` (remove underscore)
- Add `@visibleForTesting` annotation (already available from the existing `package:flutter/material.dart` import)
- Update all internal references to the old name

```dart
@visibleForTesting
class CameraRulerDialState extends State<CameraRulerDial> {
```

- [ ] **Step 2: Update `createState` to use the public name**

In the `CameraRulerDial` widget class (around line 48):

```dart
  @override
  CameraRulerDialState createState() => CameraRulerDialState();
```

- [ ] **Step 3: Verify it compiles**

Run: `flutter analyze lib/widgets/camera_ruler_dial/camera_ruler_dial.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add lib/widgets/camera_ruler_dial/camera_ruler_dial.dart
git commit -m "feat: add programmatic setValue() to CameraRulerDial for tests"
```

---

### Task 8: Set Up integration_test Framework and Update Dependencies

**Files:**
- Modify: `pubspec.yaml`
- Delete: `lib/driver_main.dart`
- Create: `integration_test/app_test.dart`
- Create: `integration_test/helpers/camera_test_helpers.dart`

- [ ] **Step 1: Update pubspec.yaml**

Replace `flutter_driver` with `integration_test` in dev_dependencies (lines 18-23):

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0
  integration_test:
    sdk: flutter
```

- [ ] **Step 2: Run flutter pub get**

Run: `flutter pub get`
Expected: Resolving dependencies... Got dependencies!

- [ ] **Step 3: Delete driver_main.dart**

```bash
rm lib/driver_main.dart
```

- [ ] **Step 4: Create test helpers**

```dart
// integration_test/helpers/camera_test_helpers.dart
import 'package:flutter/material.dart' show ValueKey;
import 'package:flutter_test/flutter_test.dart' show CommonFinders, WidgetTester, find;

import 'package:camera2_flutter_demo/widgets/bottom_bar_keys.dart'
    show kBarSettings, kBarCalibrate, kBarRecord;
import 'package:camera2_flutter_demo/widgets/camera_settings_bar_keys.dart'
    show kBarClose, kChipIso, kChipShutter, kChipFocus, kChipWb, kChipZoom;
import 'package:camera2_flutter_demo/testing/widget_registry.dart'
    show WidgetEntry;

/// Taps a widget identified by its [WidgetEntry.key] and pumps.
Future<void> tapEntry(WidgetTester tester, WidgetEntry entry) async {
  await tester.tap(find.byKey(entry.key));
  await tester.pumpAndSettle();
}

/// Taps a widget and uses pump(duration) instead of pumpAndSettle.
/// Use this when the app has continuous animations (e.g. during recording).
Future<void> tapEntryNonSettling(
  WidgetTester tester,
  WidgetEntry entry, {
  Duration wait = const Duration(seconds: 1),
}) async {
  await tester.tap(find.byKey(entry.key));
  await tester.pump(wait);
}

/// Opens the camera settings panel.
Future<void> openSettings(WidgetTester tester) async {
  await tapEntry(tester, kBarSettings);
}

/// Closes the camera settings panel.
Future<void> closeSettings(WidgetTester tester) async {
  await tapEntry(tester, kBarClose);
}

/// Taps a settings chip.
Future<void> tapChip(WidgetTester tester, WidgetEntry chip) async {
  await tapEntry(tester, chip);
}

/// Opens the GPU calibration sidebar.
Future<void> openGpuSidebar(WidgetTester tester) async {
  await tapEntry(tester, kBarCalibrate);
}

/// Starts recording. Uses pump() instead of pumpAndSettle() because
/// continuous frame callbacks during recording prevent settling.
Future<void> startRecording(WidgetTester tester) async {
  await tapEntryNonSettling(tester, kBarRecord);
}

/// Stops recording and waits for encoder flush.
Future<void> stopRecording(WidgetTester tester) async {
  await tapEntryNonSettling(
    tester,
    kBarRecord,
    wait: const Duration(seconds: 3),
  );
}
```

- [ ] **Step 5: Create main test file**

```dart
// integration_test/app_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:camera2_flutter_demo/main.dart' as app;
import 'package:camera2_flutter_demo/testing/widget_registry.dart'
    show WidgetRegistry;
import 'package:camera2_flutter_demo/widgets/bottom_bar_keys.dart'
    show kBarSettings, kBarRecord;
import 'package:camera2_flutter_demo/widgets/camera_settings_bar_keys.dart'
    show kBarClose, kChipIso, kChipShutter, kChipFocus, kChipWb, kChipZoom;
import 'package:camera2_flutter_demo/widgets/camera_control_keys.dart'
    show kDialAutoToggle, kHudRecording;

import 'helpers/camera_test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Widget registry', () {
    testWidgets('all interactive widgets are registered', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final registry = WidgetRegistry.instance.all;
      // 21 widgets expected (4 bar + 5 chips + 3 controls + 8 gpu + 1 hud)
      expect(registry.length, greaterThanOrEqualTo(21));
    });
  });

  group('Settings panel', () {
    testWidgets('opens and shows all 5 chips', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      await openSettings(tester);

      expect(find.byKey(kChipIso.key), findsOneWidget);
      expect(find.byKey(kChipShutter.key), findsOneWidget);
      expect(find.byKey(kChipFocus.key), findsOneWidget);
      expect(find.byKey(kChipWb.key), findsOneWidget);
      expect(find.byKey(kChipZoom.key), findsOneWidget);
    });

    testWidgets('each chip can be selected', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      await openSettings(tester);

      // Tap each chip — no crash means it works
      for (final chip in [kChipIso, kChipShutter, kChipFocus, kChipWb, kChipZoom]) {
        await tapChip(tester, chip);
      }
    });
  });

  group('Recording', () {
    testWidgets('start and stop recording', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Start recording
      await startRecording(tester);

      // Verify HUD is visible
      expect(find.byKey(kHudRecording.key), findsOneWidget);

      // Let it record for a few seconds
      await tester.pump(const Duration(seconds: 3));

      // Stop recording
      await stopRecording(tester);
    });
  });
}
```

- [ ] **Step 6: Verify it compiles**

Run: `flutter analyze integration_test/`
Expected: No issues found.

- [ ] **Step 7: Commit**

```bash
git add pubspec.yaml integration_test/ && git rm lib/driver_main.dart
git commit -m "feat: add integration_test framework with helpers, remove flutter_driver"
```

---

### Task 9: Add Camera State Test Channel

**Files:**
- Create: `lib/testing/test_channel.dart`
- Modify: `lib/main.dart` (register in initState)

- [ ] **Step 1: Create test channel**

```dart
// lib/testing/test_channel.dart
import 'dart:convert' show jsonEncode;
import 'dart:developer' as developer;

/// Debug-only service extension that exposes camera state as JSON.
///
/// Registered only in debug builds. Integration tests (or Dart DevTools)
/// can query `ext.test.cameraState` to verify state without parsing logcat.
///
/// Response format:
/// ```json
/// {
///   "isStreaming": true,
///   "isRecording": false,
///   "iso": 1600,
///   "exposureTimeNs": 33333333,
///   "aeSeeded": true,
///   "isoAuto": true,
///   "exposureAuto": true,
///   "afEnabled": true
/// }
/// ```
class TestChannel {
  static bool _registered = false;

  /// Registers the camera state service extension.
  ///
  /// [getState] is a callback that returns the current camera state as a Map.
  /// Safe to call multiple times — subsequent calls are ignored.
  static void register(Map<String, dynamic> Function() getState) {
    if (_registered) return;
    _registered = true;

    assert(() {
      developer.registerExtension('ext.test.cameraState', (method, params) async {
        final state = getState();
        return developer.ServiceExtensionResponse.result(jsonEncode(state));
      });
      return true;
    }());
  }
}
```

- [ ] **Step 2: Register in CameraScreen initState**

In `lib/main.dart`, add import:

```dart
import 'testing/test_channel.dart' show TestChannel;
```

At the end of `_CameraScreenState.initState()` (after line 117, after `_fetchRotation();`), add:

```dart
    TestChannel.register(() => {
      'isStreaming': _camera != null,
      'isRecording': _isRecording,
      'iso': _values.isoValue,
      'exposureTimeNs': _values.exposureTimeNs,
      'aeSeeded': _aeSeeded,
      'isoAuto': _values.isoAuto,
      'exposureAuto': _values.exposureAuto,
      'afEnabled': _values.afEnabled,
    });
```

- [ ] **Step 3: Verify it compiles**

Run: `flutter analyze lib/testing/test_channel.dart lib/main.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add lib/testing/test_channel.dart lib/main.dart
git commit -m "feat: add debug-only camera state test channel"
```

---

### Task 10: Update CLAUDE.md and Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/usage-guide.md`

- [ ] **Step 1: Add Testing section to CLAUDE.md**

Append after the existing `## Rules for AI Agents` section:

```markdown
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
```

- [ ] **Step 2: Add Widget Map section to docs/usage-guide.md**

Read the current usage guide and append a Widget Map section at the end with the same table from CLAUDE.md. This keeps it alongside the public API docs.

- [ ] **Step 3: Verify CLAUDE.md is valid markdown**

Skim the file for formatting errors.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/usage-guide.md
git commit -m "docs: add testing infrastructure guide and widget map"
```

---

### Task 11: Build Verification

**Files:** None (verification only)

- [ ] **Step 1: Run full analyzer**

Run: `flutter analyze`
Expected: No issues found.

- [ ] **Step 2: Build debug APK**

Run: `flutter build apk --debug`
Expected: BUILD SUCCESSFUL

- [ ] **Step 3: Run integration tests on device**

Run: `flutter test integration_test/ -d <device-id>`
Expected: All tests pass.

- [ ] **Step 4: Verify widget count**

The "all interactive widgets are registered" test should confirm >= 21 entries in the registry.

- [ ] **Step 5: Final commit if any fixes needed**

If any issues were found and fixed in steps 1-4, commit the fixes.
