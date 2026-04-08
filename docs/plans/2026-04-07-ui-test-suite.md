# UI Test Suite for Post-PR#16 Features

**Date:** 2026-04-07
**Status:** Blocked — requires test infrastructure from `2026-04-07-test-infrastructure-impl.md`
**Prerequisite:** All tasks in the test infrastructure plan must be complete before executing these tests.

## Context

Between PR #16 (feature/logging) and the current HEAD, 14 PRs landed covering self-healing, pause/resume, GPU pipeline changes, recording safety, stall watchdog, settings persistence, and various hardening fixes. This test suite verifies all that functionality works end-to-end on a real device through the UI.

## What Changed Since PR #16

| PR | Feature | What to verify |
|----|---------|----------------|
| #17 | Hardened diagnostic logging | Logs appear in logcat without crashes |
| #18 | Self-healing camera pipeline | Camera recovers from errors automatically |
| #19 | PAUSED state + pause()/resume() | App can pause and resume camera |
| #20 | Lightweight pause/resume + frame stall watchdog | Watchdog detects stalls; lightweight pause works |
| #21 | Strip CPU pipeline, add ProcessingStage hook | Both preview panes render (raw + processed) |
| #22 | PBO sync with GL fences and timing queries | PBO diagnostics show low stall rate |
| #23 | Lifecycle hotfix (availability callback, background suspend, thread-safe close) | Background/foreground cycles don't crash |
| #24 | Restrict LogLevelReceiver to debug builds | No LogLevelReceiver in release (N/A for debug testing) |
| #25 | FPS degradation detection outside verboseDiagnostics gate | FPS reported in heartbeat logs |
| #26 | GpuRenderer diagnostic logging and GL extension safety | Renderer logs appear, no GL errors |
| #27 | Log lifecycle observer failures | Observer errors logged, not swallowed |
| #28 | nativeInit try/catch for JNI safety | App doesn't crash on native init failure |
| #29 | Pause/recording safety and KDoc accuracy | Recording stops cleanly on pause; no crash |
| #30 | Stall watchdog fires on zero-frame sessions | Watchdog fires even when no frames received |
| — | Settings persistence (SettingsStore) | Settings survive app restart |

## How to Run

After the test infrastructure is in place:

```bash
flutter test integration_test/ -d <device-id>
```

For manual verification of logcat-based tests, run the app and check logs:

```bash
adb logcat --pid=$(adb shell pidof com.example.camera2_flutter_demo) | grep "CC/"
```

## Test 1: Basic Camera Launch and Preview

**What:** App opens, camera initializes, both preview panes render frames.
**Verifies:** PR #21 (GPU-only pipeline), PR #22 (PBO sync)

**Pass criteria:**
- Both `StreamBuilder<CameraTextureInfo>` widgets (raw and tone-mapped) have data (not showing black `ColoredBox`)
- Logcat shows `CC/Renderer: GpuRenderer: first frame rendered successfully` within 5 seconds of launch
- Heartbeat logs (`CC/3A`) show `fps=30.0` (±5) with `capFail=0 bufLost=0`
- No `CC/` error-level messages in logcat

**How to test with integration_test:**
```dart
testWidgets('camera launches and streams', (tester) async {
  app.main();
  await tester.pumpAndSettle(const Duration(seconds: 5));

  // Both texture widgets should exist
  expect(find.byType(Texture), findsNWidgets(2));

  // Query test channel for streaming state
  // (Use dart:developer service extension 'ext.test.cameraState')
  // Expect: isStreaming=true, aeSeeded=true
});
```

**Logcat verification (supplementary):**
```
CC/Renderer: GpuRenderer: first frame rendered successfully (4160x3120)
CC/3A: [HB #30] fps=30.0  ae=CONVERGED ... capFail=0 bufLost=0
CC/Renderer: PBO diagnostics: ... stall_rate=0.0%
```

## Test 2: Settings Controls (ISO, Shutter, Focus, WB, Zoom)

**What:** Each setting chip can be selected and its dial/control appears.
**Verifies:** Settings UI works end-to-end after all the pipeline changes.

**Pass criteria:**
- Tapping `bar.settings` opens the settings bar (5 chips become visible)
- Tapping each chip (`chip.iso`, `chip.shutter`, `chip.focus`, `chip.wb`, `chip.zoom`) highlights it
- For ISO/Shutter/Focus/Zoom: `CameraRulerDial` appears above the bar
- For WB: `SegmentedButton` with AWB/Lock appears
- The `dial.auto_toggle` button appears for ISO, Shutter, Focus, and WB (not Zoom)
- Tapping `bar.close` dismisses the settings bar

**How to test with integration_test:**
```dart
testWidgets('settings chips open their controls', (tester) async {
  app.main();
  await tester.pumpAndSettle(const Duration(seconds: 3));

  await openSettings(tester);

  // All 5 chips visible
  for (final chip in [kChipIso, kChipShutter, kChipFocus, kChipWb, kChipZoom]) {
    expect(find.byKey(chip.key), findsOneWidget);
  }

  // Tap ISO — dial should appear
  await tapChip(tester, kChipIso);
  expect(find.byType(CameraRulerDial), findsOneWidget);
  expect(find.byKey(kDialAutoToggle.key), findsOneWidget);

  // Tap WB — segmented button should appear instead of dial
  await tapChip(tester, kChipWb);
  expect(find.byKey(kDialWbSegment.key), findsOneWidget);

  // Tap Zoom — auto toggle should NOT appear
  await tapChip(tester, kChipZoom);
  expect(find.byKey(kDialAutoToggle.key), findsNothing);

  await closeSettings(tester);
});
```

## Test 3: Settings Persistence Across App Restart

**What:** Change a GPU processing parameter, kill the app, relaunch, verify it persists.
**Verifies:** SettingsStore / `getPersistedProcessingParams()` round-trip.

**Pass criteria:**
- Open GPU sidebar, change a slider (e.g. Brightness to non-default)
- Force-stop the app via `adb shell am force-stop`
- Relaunch the app
- GPU sidebar shows the previously set value, not the default

**How to test:**
This requires app restart, which `integration_test` can't do in a single test. Test in two phases:

Phase 1 (set value):
```dart
testWidgets('phase 1: set brightness', (tester) async {
  app.main();
  await tester.pumpAndSettle(const Duration(seconds: 3));

  await openGpuSidebar(tester);

  // Drag brightness slider to a non-default value
  final slider = find.byKey(kGpuBrightness.key);
  await tester.drag(slider, const Offset(50, 0));
  await tester.pumpAndSettle();

  // Verify brightness changed from default (0.0)
  // Read the value text next to the slider label
});
```

Phase 2 (verify after restart): Relaunch app, open sidebar, check brightness is not 0.00.

Alternatively, verify via adb + logcat:
```bash
# After setting brightness, force stop and relaunch
adb shell am force-stop com.example.camera2_flutter_demo
adb shell am start -n com.example.camera2_flutter_demo/.MainActivity
# Check logcat for persisted params being restored
```

## Test 4: Video Recording Start/Stop

**What:** Start recording, verify HUD appears with timer, stop recording, verify file exists.
**Verifies:** PR #29 (pause/recording safety), VideoRecorder, RecordingHud widget.

**Pass criteria:**
- Tapping `bar.record` starts recording
- `hud.recording` becomes visible with a timer capsule
- Bottom bar button label changes to "STOP"
- Tapping `bar.record` again (now STOP) stops recording
- Logcat shows `VideoRecorder: start: recording to content://...`
- Logcat shows recording state transitions: `recordingState=recording` → `recordingState=idle`
- A video file exists on device after stop

**How to test with integration_test:**
```dart
testWidgets('recording start and stop', (tester) async {
  app.main();
  await tester.pumpAndSettle(const Duration(seconds: 3));

  // Start recording — use pump() not pumpAndSettle() because continuous frames
  await startRecording(tester);

  // HUD should be visible
  expect(find.byKey(kHudRecording.key), findsOneWidget);

  // Let it record
  await tester.pump(const Duration(seconds: 3));

  // Stop recording
  await stopRecording(tester);

  // Verify via test channel that isRecording is false
});
```

**IMPORTANT:** During recording, continuous frame callbacks prevent `pumpAndSettle()` from ever completing. Always use `tester.pump(duration)` while recording is active.

**Logcat verification:**
```
VideoRecorder: start: recording to content://media/external/video/media/...
CC/Dart: recordingState=recording handle=0
VideoRecorder: drainEncoderLoop: muxer started, trackIndex=0
# ... after stop ...
CC/Dart: recordingState=idle handle=0
```

## Test 5: Pause/Resume via App Lifecycle

**What:** Background the app, bring it back, camera recovers.
**Verifies:** PR #19 (PAUSED state), PR #20 (lightweight pause/resume), PR #23 (lifecycle hotfix), PR #27 (observer logging).

**Pass criteria:**
- Camera is streaming at 30 FPS before pause
- After `adb shell input keyevent KEYCODE_HOME` (background), camera pauses
- After `adb shell am start -n com.example.camera2_flutter_demo/.MainActivity` (foreground), camera resumes
- Logcat shows `pause()` and `resume()` calls
- FPS returns to 30 within 3 seconds of resume
- No errors or crashes in logcat

**How to test:**
This requires lifecycle events which `integration_test` can partially simulate. Use `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused)` and `.resumed`:

```dart
testWidgets('pause and resume camera', (tester) async {
  app.main();
  await tester.pumpAndSettle(const Duration(seconds: 3));

  // Simulate backgrounding
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump(const Duration(seconds: 2));

  // Simulate foregrounding
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump(const Duration(seconds: 3));

  // Camera should be streaming again
  // Verify via test channel: isStreaming=true
});
```

**Supplementary adb test (tests real Android lifecycle):**
```bash
adb shell input keyevent KEYCODE_HOME   # Background
sleep 3
adb shell am start -n com.example.camera2_flutter_demo/.MainActivity  # Foreground
sleep 3
# Check logcat for successful resume
adb logcat -d --pid=$(adb shell pidof com.example.camera2_flutter_demo) | grep -E "(pause|resume|STREAMING)"
```

## Test 6: Self-Healing with Rapid Lifecycle Cycling

**What:** Rapidly background/foreground the app 5+ times, verify no crash and camera recovers.
**Verifies:** PR #18 (self-healing), PR #23 (thread-safe close, retry reset, availability callback).

**Pass criteria:**
- No crash after 5 rapid pause/resume cycles
- Camera returns to STREAMING state after the final resume
- No `retryCount exhausted` or unrecoverable error in logcat
- FPS stabilizes at 30 within 5 seconds of final resume

**How to test:**
```dart
testWidgets('rapid lifecycle cycling', (tester) async {
  app.main();
  await tester.pumpAndSettle(const Duration(seconds: 3));

  for (int i = 0; i < 5; i++) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 500));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 1));
  }

  // Wait for recovery
  await tester.pump(const Duration(seconds: 5));

  // Camera should be streaming
  // Verify via test channel: isStreaming=true
  // Check no runtime errors
});
```

## Test 7: Stall Watchdog and FPS Monitoring

**What:** Verify the stall watchdog is active and FPS degradation detection runs.
**Verifies:** PR #20 (stall watchdog), PR #25 (FPS detection outside verbose gate), PR #30 (zero-frame sessions).

**Pass criteria:**
- Heartbeat logs (`CC/3A`) appear every 30 frames, showing `fps=` values
- `CC/Renderer: PBO diagnostics:` appears every 300 frames with stall rate
- No `fpsDegraded` error events (assuming healthy camera)
- FPS stays within 25-35 range

**How to test:**
This is primarily a logcat verification test. After launching the app and waiting 15 seconds:

```bash
adb logcat -d --pid=$(adb shell pidof com.example.camera2_flutter_demo) | grep "CC/3A"
# Expect: multiple heartbeat lines with fps=30.0, capFail=0, bufLost=0

adb logcat -d --pid=$(adb shell pidof com.example.camera2_flutter_demo) | grep "PBO diagnostics"
# Expect: stall_rate < 5%
```

In integration_test, this can be verified indirectly via the test channel (aeSeeded=true implies frames are flowing).

## Test 8: GPU Controls Sidebar

**What:** Open sidebar, verify all 7 sliders render, adjust values, reset.
**Verifies:** PR #21 (ProcessingStage hook), GPU pipeline, settings persistence.

**Pass criteria:**
- Tapping `bar.calibrate` opens the sidebar with all 7 sliders visible
- Each slider can be dragged to change its value
- "Reset all" button resets all sliders to defaults
- The right preview pane (tone-mapped) visually changes when sliders are adjusted
- Sidebar can be closed by tapping `bar.calibrate` again

**How to test with integration_test:**
```dart
testWidgets('GPU sidebar controls', (tester) async {
  app.main();
  await tester.pumpAndSettle(const Duration(seconds: 3));

  await openGpuSidebar(tester);

  // All sliders visible
  for (final key in [
    kGpuBrightness, kGpuContrast, kGpuSaturation, kGpuGamma,
    kGpuBlackR, kGpuBlackG, kGpuBlackB,
  ]) {
    expect(find.byKey(key.key), findsOneWidget);
  }

  // Reset all visible
  expect(find.byKey(kGpuResetAll.key), findsOneWidget);

  // Drag brightness slider
  await tester.drag(find.byKey(kGpuBrightness.key), const Offset(50, 0));
  await tester.pumpAndSettle();

  // Tap reset all
  await tester.tap(find.byKey(kGpuResetAll.key));
  await tester.pumpAndSettle();

  // Close sidebar
  await openGpuSidebar(tester); // toggle off
});
```

## Test 9: Recording Safety During Pause

**What:** Start recording, then background the app. Recording should auto-stop cleanly.
**Verifies:** PR #29 (pause/recording safety).

**Pass criteria:**
- Recording starts successfully
- On backgrounding, recording stops automatically (no crash)
- Logcat shows `auto-stop on background` or normal stop sequence
- Camera pauses cleanly after recording stops
- On resume, camera recovers to streaming (not recording)

**How to test:**
```dart
testWidgets('recording stops on background', (tester) async {
  app.main();
  await tester.pumpAndSettle(const Duration(seconds: 3));

  await startRecording(tester);
  await tester.pump(const Duration(seconds: 2));

  // Background the app — should auto-stop recording
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await tester.pump(const Duration(seconds: 2));

  // Resume
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump(const Duration(seconds: 3));

  // Should NOT be recording
  // Verify via test channel: isRecording=false, isStreaming=true
});
```

## Notes for Test Agents

1. **Device required:** All tests require a real Android device with a camera. Emulators won't work.
2. **Package name:** `com.example.camera2_flutter_demo`
3. **Activity:** `.MainActivity`
4. **Camera permission:** Must be granted before tests. The app requests it on launch — if running for the first time, grant manually or via the permission dialog.
5. **`pump()` vs `pumpAndSettle()`:** During recording, ALWAYS use `pump(duration)`. The camera's continuous frame callbacks prevent `pumpAndSettle()` from ever completing.
6. **Widget keys:** All interactive widgets are findable via `find.byKey(kWidgetName.key)`. Import keys from `lib/widgets/*_keys.dart`.
7. **Test channel:** Query `ext.test.cameraState` for programmatic state verification in debug builds.
8. **Logcat tag prefix:** All camera logs use `CC/` prefix (e.g. `CC/3A`, `CC/Renderer`, `CC/Settings`).
