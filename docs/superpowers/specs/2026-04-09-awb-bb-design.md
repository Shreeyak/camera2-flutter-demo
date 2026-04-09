# AWB + Black Balance Design

**Date:** 2026-04-09  
**Branch:** feature/awb  
**Status:** Approved

---

## Overview

Add White Balance (WB) and Black Balance (BB) controls to the existing `GpuControlsSidebar`. Remove the WB chip from the bottom settings bar. The sidebar order mirrors the processing pipeline top-to-bottom.

### Pipeline order (informs UI order)
1. **Camera2 ISP** — White Balance gains applied in raw space
2. **GPU shader step 1** — Black Balance (blackR/G/B subtraction)
3. **GPU shader step 2–5** — Brightness, Contrast, Saturation, Gamma

---

## Section 1 — UI

### Sidebar layout (`gpu_controls_sidebar.dart`)

New top-to-bottom order:

| Position | Section | Controls |
|---|---|---|
| 1 | White Balance | Toggle + Calibrate button + status |
| 2 | Black Balance | Toggle + Calibrate button + status (locked only) |
| 3–6 | GPU sliders | Brightness, Contrast, Saturation, Gamma (unchanged) |
| 7 | Reset all | Resets GPU params only, not WB/BB calibration |

### White Balance section

- **Toggle**: `CameraAutoToggleButton(isAuto: wbMode is WbAuto)` — highlighted when auto mode active.
- **Calibrate button**: always visible. Label changes to "⊙ Capture" while calibrating.
- **Status line**: hidden in auto mode; shows `R×1.42 G×1.00 B×0.87` when locked.
- **On camera start**: auto mode — Camera2 AWB running.

### Black Balance section

- **Toggle**: `CameraAutoToggleButton(isAuto: bbLocked)` — highlighted when lock is active (gains being applied). No auto mode concept — "unlocked" means 0.0 offsets.
- **Calibrate button**: always visible. Label changes to "⊙ Capture" while calibrating.
- **Status line**: hidden when unlocked (default 0.0); shows `R 0.031 G 0.028 B 0.035` when locked.
- **Default state**: `blackR = blackG = blackB = 0.0` (no subtraction).

### Calibration flow (shared UX for WB and BB)

1. **Idle**: sidebar shows "Calibrate" button.
2. **Calibrating**: user taps "Calibrate" → crosshair appears centered on camera preview; button label changes to "⊙ Capture". Iteration counter shown in sidebar.
3. **Applied**: user taps "Capture" → iterative sampling loop runs (see Section 2); crosshair disappears; lock activates; status line updates with final values.

### Removed UI

- WB chip removed from `CameraSettingsBar`.
- `_WbControlPanel` overlay removed from `CameraControlOverlay`.
- `CameraSettingType.wb` enum case removed. Fix all resulting compile errors at call sites.

---

## Section 2 — Plugin: `sampleCenterPatch()`

A new primitive that samples the center 16×16 pixel patch of the most recent GPU-processed RGBA frame and returns the mean R, G, B as normalized `[0.0, 1.0]` values.

### Pigeon additions (`pigeons/camera_api.dart`)

```dart
class CamRgbSample {
  CamRgbSample({required this.r, required this.g, required this.b});
  double r;
  double g;
  double b;
}

// HostApi — new method:
CamRgbSample sampleCenterPatch(int handle);
```

Run `scripts/regenerate_pigeon.sh` after modifying the pigeon file.

### Public Dart API (`CambrianCamera`)

```dart
Future<({double r, double g, double b})> sampleCenterPatch();
```

### Kotlin implementation (`CameraController.kt`)

- Called on `backgroundHandler` thread.
- Acquires a read lock on the latest RGBA frame buffer from `GpuPipeline`.
- Iterates the center 16×16 region, accumulates R/G/B sums.
- Returns mean values normalized to `[0.0, 1.0]`.
- Returns `(0.5, 0.5, 0.5)` if no frame is available yet.

### Iterative calibration loop (Dart-side, `_CameraScreenState`)

Same structure for both WB and BB. Runs after user taps "Capture".

```
const maxIterations = 10
const tolerance = 0.01   // max acceptable channel error

for i in 0..<maxIterations:
    sample = await sampleCenterPatch()
    error = distanceFromTarget(sample)
    if error < tolerance: break
    applyCorrection(sample)
    await Future.delayed(const Duration(milliseconds: 200))
lock()
```

#### WB correction per iteration

Target: equal R, G, B channels (green as reference).

```
newGainR = currentGainR × (sample.g / sample.r)
newGainB = currentGainB × (sample.g / sample.b)
// currentGainG unchanged
apply WhiteBalance.manual(newGainR, currentGainG, newGainB)
```

Error metric: `max(|sample.r − sample.g|, |sample.b − sample.g|) / sample.g`

#### BB correction per iteration

Target: all channels → 0.

```
accumulatedBlackR += sample.r
accumulatedBlackG += sample.g
accumulatedBlackB += sample.b
apply ProcessingParams(blackR: accumulatedBlackR, blackG: accumulatedBlackG, blackB: accumulatedBlackB, …rest unchanged)
```

Error metric: `max(sample.r, sample.g, sample.b)`

---

## Section 3 — State management

All calibration state lives in `_CameraScreenState` (`lib/main.dart`).

### New fields

```dart
// White Balance
WhiteBalance _wbMode = const WhiteBalance.auto();
double? _lastWbGainR, _lastWbGainG, _lastWbGainB;

// Black Balance
bool _bbLocked = false;
double _lastBbR = 0.0, _lastBbG = 0.0, _lastBbB = 0.0;

// Calibration flow (shared)
bool _isCalibrating = false;
CalibrationTarget? _calibrationTarget;   // wb | bb
int _calibrationIteration = 0;
```

```dart
// Defined at library level (not private) so GpuControlsSidebar can reference it.
enum CalibrationTarget { wb, bb }
```

### `GpuControlsSidebar` new parameters

```dart
// Inputs
final WhiteBalance wbMode;
final (double r, double g, double b)? lastWbGains;   // null = no status line
final bool bbLocked;
final (double r, double g, double b)? lastBbValues;  // null = no status line
final bool isCalibrating;
final CalibrationTarget? calibrationTarget;
final int calibrationIteration;

// Callbacks
final VoidCallback onWbToggle;             // flip auto ↔ lock
final VoidCallback onBbToggle;             // flip locked ↔ default
final void Function(CalibrationTarget) onStartCalibration;
final VoidCallback onCapture;              // triggers iteration loop
```

### FrameResult subscription

No new streams needed. The existing `frameResultStream` subscription in `_CameraScreenState` stores the latest `FrameResult` in `_latestFrameResult`. WB lock reads `_latestFrameResult?.wbGainR/G/B`.

### Crosshair overlay

A `Stack` child on the camera preview `Widget`. Visible when `_isCalibrating == true`. Implemented as a simple `CustomPaint` drawing two centered perpendicular lines.

---

## Section 4 — Data flow

### Camera start
```
_wbMode = WhiteBalance.auto()
updateSettings(CameraSettings(whiteBalance: WhiteBalance.auto()))
```

### WB toggle: auto → lock
```
gains = (_latestFrameResult?.wbGainR ?? 1.0, wbGainG ?? 1.0, wbGainB ?? 1.0)
_wbMode = WhiteBalance.manual(gainR: gains.r, gainG: gains.g, gainB: gains.b)
_lastWbGainR/G/B = gains
updateSettings(CameraSettings(whiteBalance: _wbMode))
```

### WB toggle: lock → auto
```
_wbMode = WhiteBalance.auto()
updateSettings(CameraSettings(whiteBalance: WhiteBalance.auto()))
// _lastWbGainR/G/B preserved for next lock
```

### WB Calibrate → Capture
```
_isCalibrating = true, _calibrationTarget = wb
currentGainR = _latestFrameResult?.wbGainR ?? 1.0
currentGainG = _latestFrameResult?.wbGainG ?? 1.0
currentGainB = _latestFrameResult?.wbGainB ?? 1.0

loop (max 10 iterations):
    sample = await sampleCenterPatch()
    error = max(|sample.r - sample.g|, |sample.b - sample.g|) / sample.g
    if error < 0.01: break
    currentGainR *= (sample.g / sample.r)
    currentGainB *= (sample.g / sample.b)
    apply WhiteBalance.manual(currentGainR, currentGainG, currentGainB)
    await 200ms

_lastWbGainR/G/B = (currentGainR, currentGainG, currentGainB)
_wbMode = WhiteBalance.manual(...)   // already applied — just update state
_isCalibrating = false               // lock is now active
```

### BB toggle: unlock → lock
```
apply ProcessingParams(...blackR: _lastBbR, blackG: _lastBbG, blackB: _lastBbB)
_bbLocked = true
```

### BB toggle: lock → unlock
```
apply ProcessingParams(...blackR: 0.0, blackG: 0.0, blackB: 0.0)
_bbLocked = false
// _lastBbR/G/B preserved for next lock
```

### BB Calibrate → Capture
```
_isCalibrating = true, _calibrationTarget = bb
accR = accG = accB = 0.0

loop (max 10 iterations):
    sample = await sampleCenterPatch()
    error = max(sample.r, sample.g, sample.b)
    if error < 0.01: break
    accR += sample.r; accG += sample.g; accB += sample.b
    apply ProcessingParams(...blackR: accR, blackG: accG, blackB: accB)
    await 200ms

_lastBbR/G/B = (accR, accG, accB)
_bbLocked = true
_isCalibrating = false
```

### Reset all button
Resets only GPU params (brightness, contrast, saturation, gamma) to defaults via `ProcessingParams()`. **Does not** reset WB mode, WB calibration gains, BB lock state, or BB calibration values.

---

## Files changed

| File | Change |
|---|---|
| `lib/widgets/gpu_controls_sidebar.dart` | Add WB + BB sections at top; new params + callbacks; reorder sliders |
| `lib/main.dart` | New WB/BB state fields; calibration loop; wire callbacks; crosshair overlay |
| `lib/widgets/camera_settings_bar.dart` | Remove WB chip |
| `lib/widgets/camera_control_overlay.dart` | Remove `_WbControlPanel`; remove `CameraSettingType.wb` case |
| `lib/camera/camera_settings_values.dart` | Remove `wbLocked` field; remove `CameraSettingType.wb` enum case |
| `lib/camera/camera_callbacks.dart` | Remove `onWbLockChanged` |
| `packages/cambrian_camera/pigeons/camera_api.dart` | Add `CamRgbSample`; add `sampleCenterPatch(int handle)` to HostApi |
| `packages/cambrian_camera/lib/src/cambrian_camera_controller.dart` | Add `sampleCenterPatch()` public method |
| `packages/cambrian_camera/android/src/main/kotlin/…/CameraController.kt` | Implement `sampleCenterPatch` |
| Generated pigeon files | Re-run `scripts/regenerate_pigeon.sh` |
