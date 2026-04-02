# GPU Pipeline Wiring + Color Controls UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CPU YUV→BGR pipeline with the GPU OES→GLES3 pipeline in CameraController, and add a right-side Material3 slider sidebar so users can adjust brightness, contrast, saturation, and black balance in real time.

**Architecture:** Camera2 delivers frames to a `SurfaceTexture` (owned by `GpuPipeline`) instead of a `YUV ImageReader`. Each frame is rendered through the OES fragment shader to a full-res FBO, blitted to both the Flutter preview surface (via EGL) and a 480p tracker FBO, then read back via double-buffered PBOs to `deliverFullResRgba`/`deliverTrackerRgba`. Slider changes call `camera.setProcessingParams()` → Pigeon → `GpuPipeline.setAdjustments()` → `nativeGpuSetAdjustments` → shader uniforms updated next frame.

**Tech Stack:** Kotlin (Camera2, GpuPipeline), C++ (CameraBridge JNI), Dart/Flutter (Pigeon, Material3 sliders), Pigeon codegen.

---

## File Map

| File | Change |
|---|---|
| `src/main/cpp/src/CameraBridge.cpp` | Allow null previewSurface in `nativeInit` |
| `pigeons/camera_api.dart` | Add `double contrast` to `CamProcessingParams` |
| `lib/src/messages.g.dart` | **Regenerated** by Pigeon |
| `android/src/main/kotlin/.../Messages.g.kt` | **Regenerated** by Pigeon |
| `lib/src/camera_settings.dart` | Add `contrast` to `ProcessingParams`, update `toCam()` + `copyWith()` |
| `android/src/main/kotlin/.../CameraController.kt` | Swap ImageReader→GpuPipeline, route setProcessingParams to GPU |
| `lib/widgets/gpu_controls_sidebar.dart` | **New** — 6 labeled M3 sliders in a right side panel |
| `lib/main.dart` | Add `ProcessingParams` state, sidebar toggle, wire sliders |

---

## Task 1: Allow null previewSurface in nativeInit

**Files:**
- Modify: `packages/cambrian_camera/android/src/main/cpp/src/CameraBridge.cpp`

In the GPU pipeline, `ImagePipeline` is needed only for sink management — GpuRenderer handles preview output via EGL. Passing `null` as the preview surface lets nativeInit succeed without hooking ANativeWindow into the CPU preview path.

- [ ] **Step 1: Remove the null guard in nativeInit**

In `CameraBridge.cpp`, find `Java_com_cambrian_camera_CameraController_nativeInit`. Replace:
```cpp
    if (!previewSurface) {
        LOGE("nativeInit: previewSurface is null");
        return 0;
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, previewSurface);
    if (!window) {
        LOGE("nativeInit: ANativeWindow_fromSurface returned null");
        return 0;
    }
```
With:
```cpp
    ANativeWindow* window = nullptr;
    if (previewSurface) {
        window = ANativeWindow_fromSurface(env, previewSurface);
        if (!window) {
            LOGE("nativeInit: ANativeWindow_fromSurface returned null");
            return 0;
        }
    }
```

`ImagePipeline`'s constructor already guards `if (previewWindow_)` before acquiring, so null is safe.

- [ ] **Step 2: Commit**
```bash
git add packages/cambrian_camera/android/src/main/cpp/src/CameraBridge.cpp
git commit -m "fix(jni): allow null previewSurface in nativeInit for GPU pipeline path"
```

---

## Task 2: Add `contrast` to ProcessingParams + regenerate Pigeon

**Files:**
- Modify: `packages/cambrian_camera/pigeons/camera_api.dart`
- Modify: `packages/cambrian_camera/lib/src/camera_settings.dart`
- Regenerate: `packages/cambrian_camera/lib/src/messages.g.dart`
- Regenerate: `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/Messages.g.kt`

The GPU shader has a `uContrast` uniform `[0.5, 2.0]` (identity = 1.0) not present in the current params.

- [ ] **Step 1: Add `contrast` to `CamProcessingParams` in `pigeons/camera_api.dart`**

In `pigeons/camera_api.dart`, find the `CamProcessingParams` class and add `contrast` after `brightness`:
```dart
class CamProcessingParams {
  CamProcessingParams({
    required this.blackR,
    required this.blackG,
    required this.blackB,
    required this.gamma,
    required this.histBlackPoint,
    required this.histWhitePoint,
    required this.autoStretch,
    required this.autoStretchLow,
    required this.autoStretchHigh,
    required this.brightness,
    required this.contrast,    // ← add this
    required this.saturation,
  });

  double blackR;
  double blackG;
  double blackB;
  double gamma;
  double histBlackPoint;
  double histWhitePoint;
  bool autoStretch;
  double autoStretchLow;
  double autoStretchHigh;
  double brightness;
  double contrast;             // ← add this
  double saturation;
}
```

- [ ] **Step 2: Regenerate Pigeon**
```bash
cd packages/cambrian_camera
dart run pigeon --input pigeons/camera_api.dart
```
Expected: no errors; `lib/src/messages.g.dart` and `android/src/main/kotlin/com/cambrian/camera/Messages.g.kt` are updated with the new `contrast` field.

- [ ] **Step 3: Add `contrast` to `ProcessingParams` in `lib/src/camera_settings.dart`**

Add `contrast` field (default 1.0) to the constructor, field declarations, `_validate()`, `toCam()`, and `copyWith()`:

Constructor default:
```dart
ProcessingParams({
  this.blackR = 0.0,
  this.blackG = 0.0,
  this.blackB = 0.0,
  this.gamma = 1.0,
  this.histBlackPoint = 0.0,
  this.histWhitePoint = 1.0,
  this.autoStretch = false,
  this.autoStretchLow = 0.01,
  this.autoStretchHigh = 0.99,
  this.brightness = 0.0,
  this.contrast = 1.0,        // ← add
  this.saturation = 1.0,
})
```

Field declaration (after `brightness`):
```dart
/// Contrast multiplier in [0.5, 2.0]. 1.0 = identity.
final double contrast;
```

`_validate()` (after brightness NaN check):
```dart
if (contrast.isNaN) {
  throw ArgumentError.value(contrast, 'contrast', 'must not be NaN');
}
```

`toCam()`:
```dart
CamProcessingParams toCam() => CamProcessingParams(
      blackR: blackR,
      blackG: blackG,
      blackB: blackB,
      gamma: gamma,
      histBlackPoint: histBlackPoint,
      histWhitePoint: histWhitePoint,
      autoStretch: autoStretch,
      autoStretchLow: autoStretchLow,
      autoStretchHigh: autoStretchHigh,
      brightness: brightness,
      contrast: contrast,       // ← add
      saturation: saturation,
    );
```

`copyWith()` parameter list and body (after `brightness`):
```dart
ProcessingParams copyWith({
  // ... existing params ...
  double? brightness,
  double? contrast,            // ← add parameter
  double? saturation,
}) => ProcessingParams(
  // ... existing fields ...
  brightness: brightness ?? this.brightness,
  contrast: contrast ?? this.contrast,   // ← add
  saturation: saturation ?? this.saturation,
);
```

- [ ] **Step 4: Run Flutter tests to verify no regression**
```bash
cd packages/cambrian_camera
flutter test
```
Expected: `+16: All tests passed!`

- [ ] **Step 5: Commit**
```bash
git add pigeons/camera_api.dart lib/src/camera_settings.dart \
        lib/src/messages.g.dart \
        android/src/main/kotlin/com/cambrian/camera/Messages.g.kt
git commit -m "feat: add contrast field to ProcessingParams and regenerate Pigeon"
```

---

## Task 3: Wire CameraController.kt to GpuPipeline

**Files:**
- Modify: `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt`

Replace the YUV `ImageReader` frame delivery path with `GpuPipeline`. Camera2 now outputs to the `SurfaceTexture` inside `GpuPipeline`; the GL thread renders each OES frame and delivers RGBA to pipeline sinks.

- [ ] **Step 1: Add `gpuPipeline` field near `imageReader`**

Find the `@Volatile private var imageReader: ImageReader? = null` field declaration (around line 175). Add below it:
```kotlin
@Volatile private var gpuPipeline: GpuPipeline? = null
```

- [ ] **Step 2: Replace YUV ImageReader setup in `startCaptureSession`**

Find the block starting at line ~828:
```kotlin
// Streaming ImageReader — YUV_420_888 frames are delivered to the C++ pipeline
val streamReader = ImageReader.newInstance(streamWidth, streamHeight, streamFormat, 2)
imageReader = streamReader
```

Replace it (and the entire `streamReader.setOnImageAvailableListener({ ... }, backgroundHandler)` block, lines ~856-904) with:
```kotlin
// GPU pipeline — SurfaceTexture receives camera frames as an OES texture;
// GpuPipeline renders each frame on its GL thread and delivers RGBA to pipeline sinks.
val previewSurface = surfaceProducer.getSurface()
val pipeline = GpuPipeline(streamWidth, streamHeight, previewSurface, nativePipelinePtr)
pipeline.start()
gpuPipeline = pipeline
```

- [ ] **Step 3: Change `nativeInit` call to pass null surface**

Find:
```kotlin
val previewSurface = surfaceProducer.getSurface()
nativePipelinePtr = nativeInit(previewSurface, streamWidth, streamHeight)
```
Change to:
```kotlin
// Pass null: ImagePipeline is used only for sink dispatch in the GPU path.
// GpuRenderer owns the preview surface via EGL.
nativePipelinePtr = nativeInit(null, streamWidth, streamHeight)
```

Note: the local `val previewSurface` is now declared in the GpuPipeline block above. Ensure order is:
1. `nativePipelinePtr = nativeInit(null, streamWidth, streamHeight)` — create ImagePipeline first
2. null-check nativePipelinePtr
3. `val pipeline = GpuPipeline(streamWidth, streamHeight, surfaceProducer.getSurface(), nativePipelinePtr)` — pass the pipeline handle

- [ ] **Step 4: Replace `imageReader?.surface` capture target**

Find in `createRepeatingRequestBuilder` (~line 1039):
```kotlin
imageReader?.surface?.let { builder.addTarget(it) }
```
Change to:
```kotlin
gpuPipeline?.cameraSurface?.let { builder.addTarget(it) }
```

- [ ] **Step 5: Replace `repeatingTargetSurface` assignment in `startCaptureSession`**

Find (~line 912):
```kotlin
val surfaces = listOf(streamReader.surface, jpegReader.surface)
repeatingTargetSurface = streamReader.surface
```
Change to:
```kotlin
val gpuSurface = gpuPipeline!!.cameraSurface!!
val surfaces = listOf(gpuSurface, jpegReader.surface)
repeatingTargetSurface = gpuSurface
```

- [ ] **Step 6: Also update the fallback in `updateSettings` (line ~606)**

Find:
```kotlin
val targetSurface = repeatingTargetSurface ?: imageReader?.surface ?: return
```
Change to:
```kotlin
val targetSurface = repeatingTargetSurface ?: gpuPipeline?.cameraSurface ?: return
```

- [ ] **Step 7: Route `setProcessingParams` to GPU**

Find the `setProcessingParams` method (~line 681):
```kotlin
fun setProcessingParams(params: CamProcessingParams) {
    lastProcessingParams = params
    val ptr = nativePipelinePtr
    if (ptr == 0L) return
    nativeSetProcessingParams(
        ptr,
        params.blackR, params.blackG, params.blackB,
        ...
    )
}
```
Replace body with:
```kotlin
fun setProcessingParams(params: CamProcessingParams) {
    lastProcessingParams = params
    // GPU path: uniforms are updated via GpuPipeline.setAdjustments().
    // nativeSetProcessingParams is not called — the CPU pipeline is inactive.
    gpuPipeline?.setAdjustments(
        brightness = params.brightness,
        contrast   = params.contrast,
        saturation = params.saturation,
        blackR     = params.blackR,
        blackG     = params.blackG,
        blackB     = params.blackB,
    )
}
```

- [ ] **Step 8: Stop GpuPipeline in session teardown**

Find in the teardown block (~line 1240):
```kotlin
try {
    imageReader?.close()
} catch (_: Exception) {
}
imageReader = null
```
Add after `imageReader = null`:
```kotlin
try {
    gpuPipeline?.stop()
} catch (_: Exception) {
}
gpuPipeline = null
```

- [ ] **Step 9: Commit**
```bash
git add packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt
git commit -m "feat(kotlin): replace YUV ImageReader with GpuPipeline for GPU camera path"
```

---

## Task 4: Create GPU controls sidebar widget

**Files:**
- Create: `lib/widgets/gpu_controls_sidebar.dart`

A right-side Material3 panel with one labeled slider per GPU uniform. Calls `onChanged` immediately on every slider move (no debounce — GPU uniform updates are cheap).

- [ ] **Step 1: Create `lib/widgets/gpu_controls_sidebar.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:cambrian_camera/cambrian_camera.dart' show ProcessingParams;

/// Right-side panel with Material3 sliders for each GPU shader uniform.
///
/// [params] is the current value displayed by the sliders.
/// [onChanged] is called immediately on every drag with the updated params.
class GpuControlsSidebar extends StatelessWidget {
  const GpuControlsSidebar({
    super.key,
    required this.params,
    required this.onChanged,
  });

  final ProcessingParams params;
  final ValueChanged<ProcessingParams> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 260,
      color: theme.colorScheme.surface.withOpacity(0.92),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            Text(
              'Color Controls',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _ShaderSlider(
              label: 'Brightness',
              value: params.brightness,
              min: -1.0,
              max: 1.0,
              defaultValue: 0.0,
              valueLabel: params.brightness.toStringAsFixed(2),
              onChanged: (v) => onChanged(params.copyWith(brightness: v)),
            ),
            _ShaderSlider(
              label: 'Contrast',
              value: params.contrast,
              min: 0.5,
              max: 2.0,
              defaultValue: 1.0,
              valueLabel: params.contrast.toStringAsFixed(2),
              onChanged: (v) => onChanged(params.copyWith(contrast: v)),
            ),
            _ShaderSlider(
              label: 'Saturation',
              value: params.saturation,
              min: 0.0,
              max: 2.0,
              defaultValue: 1.0,
              valueLabel: params.saturation.toStringAsFixed(2),
              onChanged: (v) => onChanged(params.copyWith(saturation: v)),
            ),
            const Divider(height: 24),
            Text(
              'Black Balance',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            _ShaderSlider(
              label: 'R',
              value: params.blackR,
              min: 0.0,
              max: 0.5,
              defaultValue: 0.0,
              valueLabel: params.blackR.toStringAsFixed(3),
              activeColor: Colors.redAccent,
              onChanged: (v) => onChanged(params.copyWith(blackR: v)),
            ),
            _ShaderSlider(
              label: 'G',
              value: params.blackG,
              min: 0.0,
              max: 0.5,
              defaultValue: 0.0,
              valueLabel: params.blackG.toStringAsFixed(3),
              activeColor: Colors.greenAccent,
              onChanged: (v) => onChanged(params.copyWith(blackG: v)),
            ),
            _ShaderSlider(
              label: 'B',
              value: params.blackB,
              min: 0.0,
              max: 0.5,
              defaultValue: 0.0,
              valueLabel: params.blackB.toStringAsFixed(3),
              activeColor: Colors.blueAccent,
              onChanged: (v) => onChanged(params.copyWith(blackB: v)),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => onChanged(const ProcessingParams()),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reset all'),
            ),
          ],
        ),
      ),
    );
  }
}

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
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final double defaultValue;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: theme.textTheme.bodySmall),
              GestureDetector(
                onTap: () => onChanged(defaultValue),
                child: Text(
                  valueLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: activeColor,
              thumbColor: activeColor,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
```

Note: `FontFeature` requires `import 'dart:ui' show FontFeature;` at the top of the file.

Full imports for the file:
```dart
import 'dart:ui' show FontFeature;
import 'package:flutter/material.dart';
import 'package:cambrian_camera/cambrian_camera.dart' show ProcessingParams;
```

- [ ] **Step 2: Commit**
```bash
git add lib/widgets/gpu_controls_sidebar.dart
git commit -m "feat(ui): add GpuControlsSidebar with Material3 sliders for shader uniforms"
```

---

## Task 5: Integrate sidebar into main.dart

**Files:**
- Modify: `lib/main.dart`

Add `ProcessingParams` state, a toggle button, and wire slider changes to `camera.setProcessingParams()`.

- [ ] **Step 1: Add `_processingParams` and `_sidebarOpen` state fields**

In `_CameraScreenState`, after the existing state fields (near `_settingsDrawerOpen`), add:
```dart
ProcessingParams _processingParams = const ProcessingParams();
bool _sidebarOpen = false;
```

- [ ] **Step 2: Add import for the new sidebar widget**

At the top of `lib/main.dart`, add:
```dart
import 'package:camera2_flutter_demo/widgets/gpu_controls_sidebar.dart';
```
(Adjust the package name to match the actual app package — check `pubspec.yaml` for `name:`.)

- [ ] **Step 3: Add `_applyProcessingParams` helper**

In `_CameraScreenState`, add:
```dart
void _applyProcessingParams(ProcessingParams params) {
  setState(() => _processingParams = params);
  _camera?.setProcessingParams(params);
}
```

- [ ] **Step 4: Add sidebar toggle button to the camera preview area**

In the `build` method, find `_buildCameraPreview()` (the right-side processed preview). Wrap it in a `Stack` with a toggle button in the top-right corner:

Find the line that calls `_buildCameraPreview()` in the `Row` and replace it with:
```dart
Expanded(
  child: Stack(
    fit: StackFit.expand,
    children: [
      _buildCameraPreview(),
      // Sidebar toggle button — top right corner
      Positioned(
        top: 8,
        right: _sidebarOpen ? 268 : 8,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: FloatingActionButton.small(
            key: ValueKey(_sidebarOpen),
            heroTag: 'sidebarToggle',
            onPressed: () => setState(() => _sidebarOpen = !_sidebarOpen),
            child: Icon(_sidebarOpen ? Icons.tune_outlined : Icons.tune),
          ),
        ),
      ),
      // Sidebar slides in from right
      AnimatedPositioned(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOutCubic,
        top: 0,
        bottom: 0,
        right: _sidebarOpen ? 0 : -270,
        child: GpuControlsSidebar(
          params: _processingParams,
          onChanged: _applyProcessingParams,
        ),
      ),
    ],
  ),
),
```

- [ ] **Step 5: Seed initial processing params after camera opens**

In `initState` (or wherever the camera is opened and `_camera` is assigned), after the camera opens successfully, apply the initial params:
```dart
// After camera is opened and streaming:
_applyProcessingParams(_processingParams);
```

Find the existing call that sets processing params in `initState` (currently something like `_camera!.setProcessingParams(ProcessingParams(saturation: 2.0))`). Replace it with:
```dart
_processingParams = const ProcessingParams();   // identity defaults
_applyProcessingParams(_processingParams);
```

- [ ] **Step 6: Run flutter analyze**
```bash
flutter analyze
```
Expected: same pre-existing errors only (pigeon file errors are pre-existing on main). No new errors from our files.

- [ ] **Step 7: Build and run on device**
```bash
flutter run --debug
```
Expected:
- Camera opens and previews normally (GPU pipeline active)
- Tapping the ⚙ tune button slides in the sidebar from the right
- Dragging Brightness slider immediately lightens/darkens the preview
- Dragging Contrast, Saturation sliders immediately affect the preview
- Black Balance R/G/B sliders lift the respective channel floor
- "Reset all" restores everything to identity
- The raw preview (left panel) is unaffected by slider changes

- [ ] **Step 8: Commit**
```bash
git add lib/main.dart
git commit -m "feat(ui): integrate GPU controls sidebar into main screen"
```

---

## Verification

| Check | How |
|---|---|
| GPU pipeline active | logcat: `GpuPipeline: nativeGpuInit` on camera open; no `nativeDeliverYuv` calls |
| Slider → preview latency | Drag brightness: preview updates within one frame (~16ms at 60fps) |
| Sink consistency | Register test sink with `SinkRole.FULL_RES` via native handle; pixel values match preview at same frameId |
| No glFinish stall | `adb logcat | grep glFinish` — empty |
| Tests pass | `cd packages/cambrian_camera && flutter test` → 16 passed |
