# Demo App Architecture (Code-Derived)

## Methodology

This report is derived entirely from live code inspection, without reference to any documentation under `docs/`. Tools used:

- **File read**: Examined all 17 `.dart` files under `lib/`
- **Workspace symbol resolution**: Located key classes (CameraScreen, _CameraScreenState)
- **Direct analysis**: Traced widget tree structure, stream subscriptions, and plugin integration points from source code

Coverage: Complete. All `.dart` files under `lib/` have been read. No Mermaid diagrams used; Excalidraw inputs are structured separately.

LSP budget consumed: 1 call (workspace symbol resolution). Dart LSP unavailable; used workspace symbol tool instead.

---

## File map

| Path | Purpose |
|---|---|
| lib/main.dart:1 | App entry point; MaterialApp, CameraApp root widget, CameraScreen state container |
| lib/camera/camera_callbacks.dart:1 | Bundle of camera action callbacks (ISO, exposure, focus, zoom, AF toggle) passed to UI |
| lib/camera/camera_format_utils.dart:1 | Utility to format shutter speed (ns) as fractional (1/250) or decimal (0.8s) |
| lib/camera/camera_settings_values.dart:1 | Data classes: CameraSettingType enum, CameraRanges, CameraSettingsValues snapshot |
| lib/theme/material_theme.dart:1 | Material 3 theme definition (salmon color scheme) with light/dark variants |
| lib/theme/theme_util.dart:1 | Helper to merge Google Fonts (Roboto + Noto Sans) into TextTheme |
| lib/widgets/bottom_bar.dart:1 | Main control bar: animates between action buttons and settings chips |
| lib/widgets/bottom_bar_buttons.dart:1 | BottomBarActionButton: reusable vertical icon+label button |
| lib/widgets/camera_control_overlay.dart:1 | Floating overlay showing CameraRulerDial for active numeric setting (ISO, shutter, focus, zoom) |
| lib/widgets/calibration_overlay.dart:1 | Fullscreen overlay with square patch outline and confirm button for WB/BB calibration |
| lib/widgets/camera_settings_bar.dart:1 | Settings drawer content: row of chips for ISO/shutter/focus, with close button |
| lib/widgets/gpu_controls_sidebar.dart:1 | Right-side panel: WB/BB calibration controls + GPU shader sliders (brightness, contrast, saturation, gamma) |
| lib/widgets/recording_hud.dart:1 | Non-intrusive overlay showing recording state and elapsed time |
| lib/widgets/resolution_picker.dart:1 | Dialog widget to select YUV stream resolution from available options |
| lib/widgets/camera_ruler_dial/camera_ruler_dial.dart:1 | Horizontal ruler dial styled after iOS; supports drag, inertia, and edge fade |
| lib/widgets/camera_ruler_dial/camera_dial_config.dart:1 | Configuration classes for dial appearance (layout, fade, ticks, labels, indicator) |
| lib/widgets/camera_ruler_dial/camera_dial_presets.dart:1 | Preset models for ISO, shutter, focus, zoom dials (stop lists, formatters, icons) |

---

## State management

The demo app uses **StatefulWidget with local state only**. No external state-management library (Provider, Riverpod, Bloc, etc.) is in `pubspec.yaml`. All UI state lives in `_CameraScreenState` as instance fields.

**State pattern breakdown:**

- **CameraApp** (`lib/main.dart:62`): Stateless root widget. Constructs MaterialApp with dark theme.
- **CameraScreen** (`lib/main.dart:79`): StatefulWidget host.
- **_CameraScreenState** (`lib/main.dart:86`): Holds all mutable state (camera instance, settings, UI toggles, calibration state, frame results, error state, recording state). Uses `setState()` to rebuild on changes.

**State categories:**

1. **Camera state** (`lib/main.dart:88-94`): `_camera`, `_frameResultSub`, `_errorSub`, `_ranges`, `_values` (snapshot of camera settings). Updated in `_openCamera()` and by frame result callbacks.

2. **UI state** (`lib/main.dart:96-100`): `_settingsDrawerOpen`, `_activeSetting`, `_processingParams`, `_sidebarOpen`. Modified by user taps in bottom bar.

3. **Recording state** (`lib/main.dart:102-107`): `_isRecording`, `_recordingActionInProgress`, `_recordingDisplayName`, `_recordingStateSub`. Synchronized with plugin's RecordingState stream.

4. **Calibration state** (`lib/main.dart:140-158`): `_isCalibrating`, `_calibrationTarget`, snapshots of WB/BB values, `_latestFrameResult`, `_latestTextureInfo`. Used to drive the overlay and restore prior state on cancel.

5. **Crop state** (`lib/main.dart:113-122`): `_cropEnabled`, `_sensorStreamSize`. Toggles between cropped (1600×1200) and full-sensor output.

6. **WB/BB state** (`lib/main.dart:124-138`): `_wbMode`, `_lastWbGains`, `_bbLocked`, `_lastBbR/G/B`. Read from FrameResult, updated on calibration.

**No external state library.** All callbacks are passed directly as closures to child widgets, which invoke them via `onChanged`, `onTap`, etc., triggering `setState()` in the parent.

---

## Screen composition

### Top-level navigation

Single screen, no routing. `CameraApp.build()` (`lib/main.dart:66`) creates a `MaterialApp` with `home: const CameraScreen()`. No named routes, no `Navigator.push`, no `go_router`.

### Widget tree (top to bottom)

```
CameraApp (StatelessWidget)
  └─ MaterialApp
       └─ CameraScreen (StatefulWidget)
            └─ _CameraScreenState.build()
                 └─ PopScope (handles back button for settings drawer)
                      └─ Scaffold
                           ├─ body:
                           │    └─ SafeArea
                           │         └─ Column [preview + controls]
                           │              ├─ Expanded (preview area)
                           │              │    └─ Stack
                           │              │         ├─ Row (GPU sidebar + previews)
                           │              │         │    ├─ AnimatedContainer (sidebar collapse/expand)
                           │              │         │    │    └─ GpuControlsSidebar (StatelessWidget)
                           │              │         │    └─ Expanded
                           │              │         │         └─ Row
                           │              │         │              ├─ _buildRawPreview() → StreamBuilder<CameraTextureInfo>
                           │              │         │              └─ _buildCameraPreview() → Stack
                           │              │         │                   ├─ StreamBuilder<CameraTextureInfo> (toneMappedTexture)
                           │              │         │                   └─ CalibrationOverlay (conditional on _isCalibrating)
                           │              │         └─ Positioned (RecordingHud)
                           │              │              └─ RecordingHud (StatefulWidget)
                           │              │
                           │              └─ Column (bottom controls)
                           │                   ├─ Conditional: CameraControlOverlay (when _activeSetting != null)
                           │                   │    └─ Stack
                           │                   │         ├─ CameraRulerDial (StatefulWidget)
                           │                   │         └─ CameraAutoToggleButton (if auto-mode applies)
                           │                   │
                           │                   └─ ColoredBox (bottom bar background)
                           │                        └─ BottomBar (StatelessWidget)
                           │                             └─ TweenAnimationBuilder
                           │                                  └─ Stack [animates between layers]
                           │                                       ├─ _MainActionBar (action buttons)
                           │                                       └─ CameraSettingsBar (setting chips)
```

### Stream subscriptions and listeners

Three persistent subscriptions are created in `initState()` after camera opens:

1. **Frame results** (`lib/main.dart:261`): `_frameResultSub = camera.frameResultStream.listen(_onFrameResult)`. Updates ISO/exposure/focus sliders from hardware values; gates manual control until first frame arrives (`_aeSeeded`).

2. **Error stream** (`lib/main.dart:262`): `_errorSub = camera.errorStream.listen(_onCameraError)`. Handles settingsConflict, FPS degradation, AE timeout; shows SnackBar notifications.

3. **Recording state** (`lib/main.dart:263`): `_recordingStateSub = camera.recordingStateStream.listen(...)`. Updates `_isRecording` when recording ends or errors.

Each subscription is cancelled in `dispose()` (`lib/main.dart:184-186`).

---

## Plugin integration points

All plugin calls are routed through `_camera` (a nullable `CambrianCamera?` instance). Here is the complete integration surface:

### Camera open & setup

| Method | Location | Purpose |
|---|---|---|
| `CambrianCamera.open(settings: _kInitialSettings)` | lib/main.dart:222 | Opens camera with auto ISO/exposure/focus, raw stream, 1600×1200 crop |
| `camera.getPersistedProcessingParams()` | lib/main.dart:226 | Loads GPU processing params from previous session or null |
| `camera.setProcessingParams(initialParams)` | lib/main.dart:232 | Applies initial GPU shader state (clears black offsets on startup) |
| `camera.capabilities` | lib/main.dart:233 | Reads CameraCapabilities: ISO range, exposure range, focus max, zoom range, stream sizes |

### Stream subscriptions (producer: plugin, consumer: UI)

| Stream | Location | Usage |
|---|---|---|
| `camera.frameResultStream` (Stream<FrameResult>) | lib/main.dart:261 | Listens to `_onFrameResult()`. Updates live ISO, exposure, focus, WB gains from hardware. |
| `camera.errorStream` (Stream<CameraError>) | lib/main.dart:262 | Listens to `_onCameraError()`. Shows error SnackBar for conflict, FPS degrade, AE timeout. |
| `camera.recordingStateStream` (Stream<RecordingState>) | lib/main.dart:263, lib/widgets/recording_hud.dart | Listened by both _CameraScreenState and RecordingHud. Updates recording UI and guards stop on background. |
| `camera.toneMappedTexture` (Stream<CameraTextureInfo>) | lib/main.dart:985 | StreamBuilder in _buildCameraPreview(). Displays processed preview + calibration overlay. |
| `camera.rawTexture` (Stream<CameraTextureInfo>) | lib/main.dart:1021 | StreamBuilder in _buildRawPreview(). Displays raw YUV→BGR output. |

### Settings updates (consumer: UI, producer: plugin)

| Method | Location | Usage |
|---|---|---|
| `camera.updateSettings(settings)` | lib/main.dart:287 | Called by `_applySettings()` on ISO/exposure/focus/zoom/AF changes. Partial update: omitted fields keep prior values. |
| `camera.setProcessingParams(params)` | lib/main.dart:292 | Called by `_applyProcessingParams()` on slider adjustments (brightness, contrast, saturation, gamma) or calibration. |
| `camera.setResolution(width, height)` | lib/main.dart:602 | Called by `_onResolutionSelected()` when user picks a YUV stream resolution. |

### Capture & recording

| Method | Location | Usage |
|---|---|---|
| `camera.captureImage()` | lib/main.dart:697 | Async call; returns file path. Shown in SnackBar after completion. Guarded by mounted check. |
| `camera.startRecording()` | lib/main.dart:674 | Async; returns (pathStr, displayName). Sets `_isRecording=true` and `_recordingDisplayName`. |
| `camera.stopRecording()` | lib/main.dart:672 | Async; awaited in toggle. |
| `camera.pause()` | lib/main.dart:207 | Called on AppLifecycleState.paused/hidden. Stops recording first if active. |
| `camera.resume()` | lib/main.dart:209 | Called on AppLifecycleState.resumed. Resumes streaming. |

### Calibration

| Method | Location | Usage |
|---|---|---|
| `camera.calibrateWhiteBalance(initialGainR, initialGainG, initialGainB)` | lib/main.dart:478 | Async. User confirms patch in overlay; returns WB gains + before/after patches. Updates UI sliders & applies settings. |
| `camera.calibrateBlackBalance(params: _processingParams)` | lib/main.dart:510 | Async. User confirms patch; returns offsets + patches. Updates `_processingParams` sliders & applies. |

### Close & lifecycle

| Method | Location | Usage |
|---|---|---|
| `camera.close()` | lib/main.dart:189 | Called in dispose() with error handling. Awaited with catchError. |
| `WidgetsBindingObserver.didChangeAppLifecycleState()` | lib/main.dart:197 | Overridden in _CameraScreenState. Pauses/resumes camera, stops recording on background. |

---

## Cross-cutting concerns

### Theming

**Theme definition:** `lib/theme/material_theme.dart:16` defines `MaterialTheme` class with `lightScheme()` and `dark()` factory methods. Salmon color palette (primary `#8e4d31`).

**Text theme:** `lib/theme/theme_util.dart:16` merges Google Fonts (Roboto body, Noto Sans display) into Material 3 TextTheme at app start.

**Application:** `lib/main.dart:68-73` constructs theme and applies it:
```dart
final textTheme = createTextTheme('Roboto', 'Noto Sans');
final materialTheme = MaterialTheme(textTheme);
MaterialApp(..., darkTheme: materialTheme.dark(), themeMode: ThemeMode.dark, ...)
```

**Dark mode only:** `themeMode: ThemeMode.dark` hardcodes dark theme; no light mode in UI.

### Logging

No custom logging in the demo app. Debug output via `debugPrint()` used sparingly:
- `lib/main.dart:190`: Camera close error
- `lib/main.dart:203`: Auto-stop on background error
- `lib/main.dart:275`: Camera open failure

No structured CC/Dart logging tags.

### Permissions

**Camera permission request:** `lib/main.dart:216` uses `permission_handler` package:
```dart
final status = await Permission.camera.request();
if (!status.isGranted) { ... return; }
```

Called once in `_openCamera()`, before `CambrianCamera.open()`. If denied, app shows no error UI; camera remains null and preview shows black.

**Import:** `lib/main.dart:21` imports `package:permission_handler/permission_handler.dart`.

### Lifecycle management

**WidgetsBindingObserver:** `_CameraScreenState` extends `WidgetsBindingObserver` and registers itself (`lib/main.dart:169`):
```dart
WidgetsBinding.instance.addObserver(this);
```

**Lifecycle callbacks:** `didChangeAppLifecycleState()` (`lib/main.dart:197`) handles:
- **Paused/Hidden:** Stops recording if active, then calls `camera.pause()`.
- **Resumed:** Calls `camera.resume()`.

**Disposal:** `dispose()` (`lib/main.dart:182`) cancels all stream subscriptions, unregisters observer, and closes camera with error handling.

**Critical note:** Per CLAUDE.md, the plugin's contract is that the demo *should* call `pause()`/`resume()` on lifecycle changes, and it does so correctly (lines 197–209). The demo correctly does NOT manually pause/resume on every settings change.

---

## Diagram inputs

### Symbols

```yaml
- id: cambrian-camera
  kind: class
  label: CambrianCamera (plugin class)
  cite: lib/main.dart:4

- id: camera-app
  kind: class
  label: CameraApp
  cite: lib/main.dart:62

- id: camera-screen
  kind: class
  label: CameraScreen
  cite: lib/main.dart:79

- id: camera-screen-state
  kind: class
  label: _CameraScreenState
  cite: lib/main.dart:86

- id: bottom-bar
  kind: class
  label: BottomBar
  cite: lib/widgets/bottom_bar.dart:9

- id: main-action-bar
  kind: class
  label: _MainActionBar
  cite: lib/widgets/bottom_bar.dart:109

- id: camera-settings-bar
  kind: class
  label: CameraSettingsBar
  cite: lib/widgets/camera_settings_bar.dart:8

- id: gpu-controls-sidebar
  kind: class
  label: GpuControlsSidebar
  cite: lib/widgets/gpu_controls_sidebar.dart:43

- id: camera-control-overlay
  kind: class
  label: CameraControlOverlay
  cite: lib/widgets/camera_control_overlay.dart:17

- id: camera-ruler-dial
  kind: class
  label: CameraRulerDial
  cite: lib/widgets/camera_ruler_dial/camera_ruler_dial.dart:29

- id: calibration-overlay
  kind: class
  label: CalibrationOverlay
  cite: lib/widgets/calibration_overlay.dart:52

- id: recording-hud
  kind: class
  label: RecordingHud
  cite: lib/widgets/recording_hud.dart:45

- id: bottom-bar-action-button
  kind: class
  label: BottomBarActionButton
  cite: lib/widgets/bottom_bar_buttons.dart:12

- id: resolution-picker
  kind: class
  label: _ResolutionPickerDialog
  cite: lib/widgets/resolution_picker.dart:29

- id: camera-callbacks
  kind: class
  label: CameraCallbacks
  cite: lib/camera/camera_callbacks.dart:4

- id: camera-settings-values
  kind: class
  label: CameraSettingsValues
  cite: lib/camera/camera_settings_values.dart:31

- id: camera-ranges
  kind: class
  label: CameraRanges
  cite: lib/camera/camera_settings_values.dart:8

- id: frame-result-stream
  kind: stream
  label: camera.frameResultStream
  cite: lib/main.dart:261

- id: error-stream
  kind: stream
  label: camera.errorStream
  cite: lib/main.dart:262

- id: recording-state-stream
  kind: stream
  label: camera.recordingStateStream
  cite: lib/main.dart:263

- id: tone-mapped-texture-stream
  kind: stream
  label: camera.toneMappedTexture
  cite: lib/main.dart:985

- id: raw-texture-stream
  kind: stream
  label: camera.rawTexture
  cite: lib/main.dart:1021
```

### Edges

**Widget tree (parent → child sync-call):**

```yaml
- from: camera-app
  to: camera-screen
  label: home
  mechanism: sync-call
  cite: lib/main.dart:74

- from: camera-screen-state
  to: bottom-bar
  label: constructs in build
  mechanism: sync-call
  cite: lib/main.dart:949

- from: bottom-bar
  to: main-action-bar
  label: main layer
  mechanism: sync-call
  cite: lib/widgets/bottom_bar.dart:67

- from: bottom-bar
  to: camera-settings-bar
  label: settings layer
  mechanism: sync-call
  cite: lib/widgets/bottom_bar.dart:91

- from: main-action-bar
  to: bottom-bar-action-button
  label: SETTINGS, CAPTURE, RECORD, CROP, RESOLUTION buttons
  mechanism: sync-call
  cite: lib/widgets/bottom_bar.dart:152-201

- from: camera-screen-state
  to: gpu-controls-sidebar
  label: constructs when _sidebarOpen
  mechanism: sync-call
  cite: lib/main.dart:858

- from: camera-screen-state
  to: camera-control-overlay
  label: constructs when _activeSetting != null
  mechanism: sync-call
  cite: lib/main.dart:921

- from: camera-control-overlay
  to: camera-ruler-dial
  label: dial for active param
  mechanism: sync-call
  cite: lib/widgets/camera_control_overlay.dart:77

- from: camera-screen-state
  to: calibration-overlay
  label: conditional on _isCalibrating
  mechanism: sync-call
  cite: lib/main.dart:1002

- from: camera-screen-state
  to: recording-hud
  label: positioned overlay
  mechanism: sync-call
  cite: lib/main.dart:897

- from: camera-settings-bar
  to: bottom-bar-action-button
  label: CLOSE button
  mechanism: sync-call
  cite: lib/widgets/camera_settings_bar.dart:46

- from: gpu-controls-sidebar
  to: bottom-bar-action-button
  label: WB/BB toggle buttons
  mechanism: sync-call
  cite: lib/widgets/gpu_controls_sidebar.dart:1 (internal _sections)

- from: camera-screen-state
  to: cambrian-camera
  label: holds _camera instance
  mechanism: sync-call
  cite: lib/main.dart:92

- from: camera-screen-state
  to: camera-settings-values
  label: holds _values snapshot
  mechanism: sync-call
  cite: lib/main.dart:89

- from: camera-screen-state
  to: camera-ranges
  label: holds _ranges
  mechanism: sync-call
  cite: lib/main.dart:90

- from: camera-screen-state
  to: camera-callbacks
  label: creates _callbacks bundle
  mechanism: sync-call
  cite: lib/main.dart:172
```

**Stream subscriptions (async, tap into plugin producer):**

```yaml
- from: frame-result-stream
  to: camera-screen-state
  label: _frameResultSub listens, calls _onFrameResult()
  mechanism: stream-emit
  cite: lib/main.dart:261

- from: error-stream
  to: camera-screen-state
  label: _errorSub listens, calls _onCameraError()
  mechanism: stream-emit
  cite: lib/main.dart:262

- from: recording-state-stream
  to: camera-screen-state
  label: _recordingStateSub listens, updates _isRecording
  mechanism: stream-emit
  cite: lib/main.dart:263

- from: recording-state-stream
  to: recording-hud
  label: RecordingHud subscribes in initState
  mechanism: stream-emit
  cite: lib/widgets/recording_hud.dart:45

- from: tone-mapped-texture-stream
  to: camera-screen-state
  label: _buildCameraPreview() wraps with StreamBuilder
  mechanism: stream-emit
  cite: lib/main.dart:985

- from: raw-texture-stream
  to: camera-screen-state
  label: _buildRawPreview() wraps with StreamBuilder
  mechanism: stream-emit
  cite: lib/main.dart:1021
```

**Callbacks (UI → state mutations):**

```yaml
- from: main-action-bar
  to: camera-screen-state
  label: onToggleSettings → _toggleSettingsDrawer()
  mechanism: sync-call
  cite: lib/widgets/bottom_bar.dart:69, lib/main.dart:757

- from: main-action-bar
  to: camera-screen-state
  label: onSettingChipTap → _onSettingChipTap()
  mechanism: sync-call
  cite: lib/widgets/bottom_bar.dart:93, lib/main.dart:753

- from: main-action-bar
  to: camera-screen-state
  label: onToggleGpuControls → setState(_sidebarOpen)
  mechanism: sync-call
  cite: lib/widgets/bottom_bar.dart:70, lib/main.dart:957

- from: main-action-bar
  to: camera-screen-state
  label: onCapture → _captureImage()
  mechanism: sync-call
  cite: lib/widgets/bottom_bar.dart:76, lib/main.dart:693

- from: main-action-bar
  to: camera-screen-state
  label: onToggleRecording → _toggleRecording()
  mechanism: sync-call
  cite: lib/widgets/bottom_bar.dart:74, lib/main.dart:666

- from: main-action-bar
  to: camera-screen-state
  label: onToggleCrop → _toggleCrop()
  mechanism: sync-call
  cite: lib/widgets/bottom_bar.dart:78, lib/main.dart:300

- from: camera-ruler-dial
  to: camera-callbacks
  label: onChanged → callback (ISO/exposure/focus/zoom)
  mechanism: sync-call
  cite: lib/widgets/camera_ruler_dial/camera_ruler_dial.dart:32

- from: camera-callbacks
  to: camera-screen-state
  label: onIsoChanged, onExposureTimeNsChanged, onFocusChanged, onZoomChanged, onToggleAf
  mechanism: sync-call
  cite: lib/main.dart:173-178

- from: gpu-controls-sidebar
  to: camera-screen-state
  label: onChanged (brightness, contrast, saturation, gamma)
  mechanism: sync-call
  cite: lib/widgets/gpu_controls_sidebar.dart:59, lib/main.dart:860

- from: gpu-controls-sidebar
  to: camera-screen-state
  label: onWbToggle → _onWbToggle()
  mechanism: sync-call
  cite: lib/widgets/gpu_controls_sidebar.dart:76, lib/main.dart:873

- from: gpu-controls-sidebar
  to: camera-screen-state
  label: onBbToggle → _onBbToggle()
  mechanism: sync-call
  cite: lib/widgets/gpu_controls_sidebar.dart:79, lib/main.dart:874

- from: gpu-controls-sidebar
  to: camera-screen-state
  label: onStartCalibration → _onStartCalibration()
  mechanism: sync-call
  cite: lib/widgets/gpu_controls_sidebar.dart:82, lib/main.dart:875

- from: calibration-overlay
  to: camera-screen-state
  label: onConfirm → unawaited(_onCapture())
  mechanism: sync-call
  cite: lib/widgets/calibration_overlay.dart:62, lib/main.dart:1006
```

**Plugin method calls (camera control):**

```yaml
- from: camera-screen-state
  to: cambrian-camera
  label: updateSettings() on ISO/exposure/focus/zoom change
  mechanism: pigeon
  cite: lib/main.dart:287

- from: camera-screen-state
  to: cambrian-camera
  label: setProcessingParams() on GPU slider change or calibration
  mechanism: pigeon
  cite: lib/main.dart:292

- from: camera-screen-state
  to: cambrian-camera
  label: captureImage()
  mechanism: pigeon
  cite: lib/main.dart:697

- from: camera-screen-state
  to: cambrian-camera
  label: startRecording() / stopRecording()
  mechanism: pigeon
  cite: lib/main.dart:672, lib/main.dart:674

- from: camera-screen-state
  to: cambrian-camera
  label: calibrateWhiteBalance()
  mechanism: pigeon
  cite: lib/main.dart:478

- from: camera-screen-state
  to: cambrian-camera
  label: calibrateBlackBalance()
  mechanism: pigeon
  cite: lib/main.dart:510

- from: camera-screen-state
  to: cambrian-camera
  label: setResolution()
  mechanism: pigeon
  cite: lib/main.dart:602

- from: camera-screen-state
  to: cambrian-camera
  label: pause() / resume()
  mechanism: pigeon
  cite: lib/main.dart:207, lib/main.dart:209

- from: camera-screen-state
  to: cambrian-camera
  label: close()
  mechanism: pigeon
  cite: lib/main.dart:189
```

### Sequences

**Sequence 1: Camera initialization**

```yaml
- name: User launches app → camera opens
  steps:
    - actor: camera-screen-state
      op: initState calls _openCamera()
      cite: lib/main.dart:171

    - actor: camera-screen-state
      op: request camera permission (Permission.camera.request())
      cite: lib/main.dart:216

    - actor: camera-screen-state
      op: call CambrianCamera.open(settings: _kInitialSettings)
      cite: lib/main.dart:222

    - actor: camera-screen-state
      op: read camera.capabilities (ranges, stream sizes)
      cite: lib/main.dart:233

    - actor: camera-screen-state
      op: restore persisted GPU params or use defaults (black offsets = 0)
      cite: lib/main.dart:226-232

    - actor: camera-screen-state
      op: setState: _camera, _ranges, _values, _processingParams, _availableResolutions
      cite: lib/main.dart:252-260

    - actor: camera-screen-state
      op: subscribe to frameResultStream, errorStream, recordingStateStream
      cite: lib/main.dart:261-271

    - actor: frame-result-stream
      op: emit FrameResult with hardware ISO, exposure, focus
      cite: lib/main.dart:621

    - actor: camera-screen-state
      op: _onFrameResult() updates _values (ISO/exposure/focus) if in auto mode; sets _aeSeeded=true
      cite: lib/main.dart:621-662
```

**Sequence 2: User adjusts ISO via slider**

```yaml
- name: User taps ISO chip, drags dial
  steps:
    - actor: camera-settings-bar
      op: user taps ISO chip; _onSettingChipTap(CameraSettingType.iso)
      cite: lib/widgets/camera_settings_bar.dart:50

    - actor: camera-screen-state
      op: setState(_activeSetting = CameraSettingType.iso)
      cite: lib/main.dart:754

    - actor: camera-screen-state
      op: build() renders CameraControlOverlay with IsoDialPreset
      cite: lib/main.dart:921

    - actor: camera-control-overlay
      op: constructs CameraRulerDial with stops, callbacks
      cite: lib/widgets/camera_control_overlay.dart:77

    - actor: camera-ruler-dial
      op: user drags; onChanged(newIsoValue) called
      cite: lib/widgets/camera_ruler_dial/camera_ruler_dial.dart:32

    - actor: camera-callbacks
      op: onIsoChanged(iso) called
      cite: lib/main.dart:540

    - actor: camera-screen-state
      op: _onIsoChanged() guards on _aeSeeded; setState updates _values; calls _applySettings(iso)
      cite: lib/main.dart:540

    - actor: camera-screen-state
      op: camera.updateSettings(CameraSettings(iso: AutoValue.manual(iso)))
      cite: lib/main.dart:550

    - actor: cambrian-camera
      op: applies ISO to Camera2, emits next frameResultStream
      cite: lib/main.dart:261
```

**Sequence 3: User captures image**

```yaml
- name: User taps CAPTURE button
  steps:
    - actor: main-action-bar
      op: user taps CAPTURE button; onCapture() called
      cite: lib/widgets/bottom_bar.dart:170

    - actor: camera-screen-state
      op: _captureImage() calls camera.captureImage()
      cite: lib/main.dart:693

    - actor: cambrian-camera
      op: captures RAW + applies tone mapping, saves to DCIM
      cite: lib/main.dart:697

    - actor: camera-screen-state
      op: await completes; shows SnackBar with file path
      cite: lib/main.dart:699-714
```

**Sequence 4: User starts/stops recording**

```yaml
- name: User taps RECORD / STOP button
  steps:
    - actor: main-action-bar
      op: user taps RECORD; onToggleRecording() called
      cite: lib/widgets/bottom_bar.dart:178

    - actor: camera-screen-state
      op: _toggleRecording() checks !_isRecording; calls camera.startRecording()
      cite: lib/main.dart:666

    - actor: cambrian-camera
      op: initializes MediaRecorder, emits RecordingState.recording
      cite: lib/main.dart:674

    - actor: recording-state-stream
      op: emits RecordingState.recording
      cite: lib/main.dart:263

    - actor: recording-hud
      op: subscribes to stream; displays elapsed time, recording indicator
      cite: lib/widgets/recording_hud.dart:45

    - actor: camera-screen-state
      op: setState(_isRecording=true, _recordingDisplayName)
      cite: lib/main.dart:676-679

    - actor: camera-screen-state
      op: user taps STOP; _toggleRecording() calls camera.stopRecording()
      cite: lib/main.dart:672

    - actor: cambrian-camera
      op: finalizes MediaRecorder, emits RecordingState.idle or error
      cite: lib/main.dart:263

    - actor: camera-screen-state
      op: recordingStateSub callback: setState(_isRecording=false)
      cite: lib/main.dart:269
```

**Sequence 5: User calibrates white balance**

```yaml
- name: User taps WB Calibrate button, positions patch, confirms
  steps:
    - actor: gpu-controls-sidebar
      op: user taps Calibrate button; onStartCalibration(CalibrationTarget.wb) called
      cite: lib/main.dart:875

    - actor: camera-screen-state
      op: _onStartCalibration() snapshots WB state, sets _isCalibrating=true, resets to auto WB
      cite: lib/main.dart:386-432

    - actor: camera-screen-state
      op: build() renders CalibrationOverlay with target=wb
      cite: lib/main.dart:1002

    - actor: calibration-overlay
      op: displays fullscreen with square patch outline and confirm button
      cite: lib/widgets/calibration_overlay.dart:74

    - actor: camera-screen-state
      op: user positions patch over neutral surface, taps confirm; onConfirm() → _onCapture()
      cite: lib/main.dart:1006

    - actor: camera-screen-state
      op: _runWbCalibration() calls camera.calibrateWhiteBalance(currentGains)
      cite: lib/main.dart:474

    - actor: cambrian-camera
      op: samples 96×96 patch, computes optimal gains (iterative Nelder-Mead), returns result
      cite: lib/main.dart:478

    - actor: camera-screen-state
      op: setState(_wbMode=manual, _lastWbGains, patches); _applySettings(manual WB)
      cite: lib/main.dart:484-495

    - actor: camera-screen-state
      op: camera.updateSettings(CameraSettings(whiteBalance: manual))
      cite: lib/main.dart:495

    - actor: camera-screen-state
      op: _onCapture() exits calibration: setState(_isCalibrating=false)
      cite: lib/main.dart:467

    - actor: camera-screen-state
      op: build() hides CalibrationOverlay
      cite: lib/main.dart:1002
```

**Sequence 6: App backgrounded → recording auto-stopped**

```yaml
- name: User switches to another app (AppLifecycleState.paused)
  steps:
    - actor: camera-screen-state
      op: WidgetsBinding notifies didChangeAppLifecycleState(paused)
      cite: lib/main.dart:197

    - actor: camera-screen-state
      op: if _isRecording, call camera.stopRecording()
      cite: lib/main.dart:202

    - actor: camera-screen-state
      op: call camera.pause()
      cite: lib/main.dart:207

    - actor: cambrian-camera
      op: stops capture session, releases Camera2 resources
      cite: lib/main.dart:207

    - actor: camera-screen-state
      op: user returns to app; WidgetsBinding notifies resumed
      cite: lib/main.dart:208

    - actor: camera-screen-state
      op: call camera.resume()
      cite: lib/main.dart:209

    - actor: cambrian-camera
      op: recreates capture session, resumes streaming
      cite: lib/main.dart:209
```

### Threads

```yaml
- name: Dart UI thread (main isolate)
  owns:
    - _CameraScreenState
    - All widget tree rendering
    - Stream subscriptions (listener callbacks run here)
  cite: lib/main.dart:86-1036

- name: Native plugin threads (per CLAUDE.md architecture)
  owns:
    - Camera2 capture session (backgroundHandler in CameraController.kt)
    - GPU rendering (EGL thread)
  cite: (plugin architecture, not in app code)
```

### Sync primitives

**No application-level sync primitives found.** The app relies on Dart's built-in mechanisms:

- **StreamSubscription**: Manages lifecycle of stream listeners (frame results, errors, recording state, texture info). Cancelled in dispose().
- **StreamBuilder**: Rebuilds widget when stream emits. Thread-safe via Dart's async primitives.
- **setState()**: Schedules UI rebuild on the Dart UI thread. Guarded by `if (mounted)` checks to prevent updates after dispose.
- **Completer**: Used by plugin internally for async method returns (captureImage, startRecording, calibrations), not by the demo app itself.

No mutexes, atomics, condition variables, or custom mailboxes are used in the demo app layer.

---

End of report.
