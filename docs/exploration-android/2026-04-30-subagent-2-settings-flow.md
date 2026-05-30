# Settings Flow (Code-Derived)

## Methodology

This report traces both outbound (UI → hardware) and inbound (hardware → UI) settings flows in the cambrian_camera Flutter plugin through systematic code exploration using:

- **LSP navigation**: call hierarchy and symbol resolution (Dart)
- **Grep/Read**: scanning Kotlin, C++, and Dart source files
- **Cross-file tracing**: following Pigeon channel boundaries and thread handoffs

No documentation files were read; all claims derive directly from source code.

**LSP budget used**: ~3 calls (Dart symbol resolution only; Kotlin has no LSP support)

**Coverage**: Complete outbound flow (UI → Dart → Pigeon → Kotlin → GPU → C++ → hardware), complete inbound flow (hardware TotalCaptureResult → Dart stream), all coupling rules, both calibration loops.

---

## Outbound (Dart → hardware)

### Camera2 ISP settings

**Entry point**: User interacts with sliders/toggles in `lib/main.dart` or `lib/camera/*.dart` UI widgets.

**Dart controller layer** (`packages/cambrian_camera/lib/src/cambrian_camera_controller.dart`):
- `updateSettings(CameraSettings)` method (line 312) accepts a partial settings object where null fields mean "don't change."
- Settings are passed to a `CameraSettingsSerializer` instance (line 85–87), which implements latest-value-wins queueing.
- The serializer calls `onSend: (s) => _hostApi.updateSettings(_handle, s.toCam())` once the Pigeon channel is free.

**Serializer** (`packages/cambrian_camera/lib/src/camera_settings_serializer.dart`):
- Maintains `_pending` (in-flight replacement) and `_inFlight` (dispatch gate).
- When a new `send()` arrives while a call is in flight, the old `_pending` is discarded and the new value replaces it (line 26–28).
- Once the in-flight call completes, `_pending` is dispatched if non-null (line 35–42).
- No time-based debounce — every value superseded by a later one is discarded without being sent.

**Encoding** (`packages/cambrian_camera/lib/src/camera_settings.dart:318–401`):
- `CameraSettings.toCam()` converts sealed types (`AutoValue<T>`, `WhiteBalance`) to string modes + values.
- ISO: mode ∈ {"auto", "manual", null}; value = sensor sensitivity int.
- Exposure: mode ∈ {"auto", "manual", null}; value = nanoseconds.
- Focus: mode ∈ {"auto", "manual", null}; value = diopters (double).
- White balance: mode ∈ {"auto", "locked", "manual", null}; values = gainR/G/B (doubles, or omitted for auto/locked).
- Zoom, noise reduction, edge mode, EV compensation transmitted as-is.
- Crop size serialized as `CamSize(width, height)`.

**Pigeon channel** (`packages/cambrian_camera/pigeons/camera_api.dart:312–326`):
- `CameraHostApi.updateSettings(int handle, CamSettings settings)` is a synchronous Pigeon method (no `@async`).
- Kotlin implementation immediately posts to `backgroundHandler` (line 1019 in CameraController.kt).

**Kotlin handler** (`packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1019–1127`):

1. **Auto-propagation (line 1033–1042)**: 
   - ISO and exposure share `CONTROL_AE_MODE` (single boolean).
   - If caller sets ISO to auto but exposure to manual (or vice versa): auto wins, both flip to auto.
   - If caller sets only ISO to auto: exposure is also pulled to auto (contagion).
   - This is checked on the *incoming* settings object, not the merged state, to avoid false wins from stale defaults.

2. **Latch-from-last-AE (line 1043–1076)**:
   - If user sends only ISO=manual and exposure=null, exposureTimeNs is seeded from `lastCaptureSnapshot?.exposureTimeNs` (the last hardware-reported value).
   - If `lastCaptureSnapshot` is null (no frame yet), a `SETTINGS_CONFLICT` error is emitted and the update is dropped.
   - Same logic for exposure=manual with iso=null.

3. **Crop validation and application (line 1078–1101)**:
   - If `cropOutputSize` is present in the update, `applyCropOutputSize()` validates against `sensorStreamWidth/Height`.
   - Constraints checked: positive dims, even pixel dimensions, within sensor bounds.
   - Invalid crops emit `SETTINGS_CONFLICT` error; valid crops are passed to `GpuPipeline.setCropOutput()`.
   - Crop changes can optionally clear an existing crop by setting size equal to sensor dims.

4. **Merging and persistence (line 1103–1106)**:
   - `appliedSettings` is updated with merged values; `pendingSettings = merged`; settings persisted via `SettingsStore.saveSettings()`.

5. **CaptureRequest construction (line 1112–1114)**:
   - `buildCaptureRequest(device, merged)` builds a Camera2 `CaptureRequest.Builder` with ISP-level settings.
   - `setRepeatingRequest()` installs it on the capture session and registers `repeatingCaptureCallback`.

**Camera2 ISP keys** (`packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2335–2434`):

| Setting | Mode | Key(s) | Behavior |
|---------|------|--------|----------|
| ISO | auto | `CONTROL_AE_MODE_ON` | AE controls sensitivity |
| ISO | manual | `CONTROL_AE_MODE_OFF` + `SENSOR_SENSITIVITY` | Fixed value |
| Exposure | auto | `CONTROL_AE_MODE_ON` | AE controls shutter |
| Exposure | manual | `CONTROL_AE_MODE_OFF` + `SENSOR_EXPOSURE_TIME` | Fixed nanoseconds |
| Focus | auto | `CONTROL_AF_MODE_CONTINUOUS_PICTURE` | Continuous AF |
| Focus | manual | `CONTROL_AF_MODE_OFF` + `LENS_FOCUS_DISTANCE` | Fixed diopters |
| WB | auto | `CONTROL_AWB_MODE_AUTO`, `CONTROL_AWB_LOCK=false` | Continuous AWB |
| WB | locked | `CONTROL_AWB_LOCK=true` | Freeze current gains |
| WB | manual | `CONTROL_AWB_MODE_OFF` + `COLOR_CORRECTION_GAINS` + `COLOR_CORRECTION_MODE_TRANSFORM_MATRIX` | User-supplied R/G_even/G_odd/B |
| Zoom | any | `CONTROL_ZOOM_RATIO` (API 30+) or `SCALER_CROP_REGION` (API <30) | Numeric ratio or rect |
| Noise reduction | any | `NOISE_REDUCTION_MODE` | Integer mode index |
| Edge mode | any | `EDGE_MODE` | Integer mode index |
| EV compensation | auto AE | `CONTROL_AE_EXPOSURE_COMPENSATION` | Integer steps (ignored if AE off) |

### GPU shader (ProcessingParams)

**Entry point**: `CambrianCamera.setProcessingParams(ProcessingParams)` (line 348).

**Pigeon channel** (`packages/cambrian_camera/pigeons/camera_api.dart:325`):
- `CameraHostApi.setProcessingParams(int handle, CamProcessingParams params)` is synchronous.

**Kotlin forwarding** (`packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1384–1400`):
- Saves to `lastProcessingParams` for replay after pipeline recreation.
- Persists via `SettingsStore.saveProcessingParams()`.
- Forwards to `GpuPipeline.setAdjustments()`.

**GPU uniform upload** (`packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:336–352`):
- `setAdjustments(brightness, contrast, saturation, blackR, blackG, blackB, gamma)` calls JNI `nativeGpuSetAdjustments()`.
- This is **fire-and-forget**: the call returns immediately; the next GPU frame picks up the new values.
- No blocking or queueing — safe to call from any thread because the C++ side protects uniforms with a mutex.

**C++ uniform storage and upload** (`packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp`):

*Storage (line 695–706)*:
```cpp
void GpuRenderer::setAdjustments(float brightness, float contrast, float saturation,
                                  float blackR, float blackG, float blackB, float gamma)
{
    std::lock_guard<std::mutex> lk(uniformMu_);  // protected by mutex
    brightness_      = brightness;
    contrast_        = contrast;
    saturation_      = saturation;
    blackBalance_[0] = blackR;
    blackBalance_[1] = blackG;
    blackBalance_[2] = blackB;
    gamma_           = gamma;
}
```

*Uniform upload to shader (line 370–374)*:
```cpp
glUniform1f(uBrightness_,   brightness);
glUniform1f(uContrast_,     contrast);
glUniform1f(uSaturation_,   saturation);
glUniform3f(uBlackBalance_, blackBalance[0], blackBalance[1], blackBalance[2]);
glUniform1f(uGamma_,        gamma);
```

**Fragment shader** (line 49–53, 112–116):
```glsl
uniform float uBrightness;
uniform float uContrast;
uniform float uSaturation;
uniform vec3  uBlackBalance;
uniform float uGamma;
// ... applied per-pixel:
rgb = max(rgb - uBlackBalance, 0.0);
rgb = applyBrightness(rgb, uBrightness);
rgb = applyContrast(rgb, uContrast);
rgb = applySaturation(rgb, uSaturation);
rgb = applyGamma(max(rgb, 0.0), uGamma);
```

### Crop (cropOutputSize)

**Flow**: `CameraSettings.cropOutputSize` field → `CamSettings.cropOutputSize` → Kotlin `applyCropOutputSize()` → `GpuPipeline.setCropOutput()` → C++ renderer.

**Validation** (line 1140–1168):
- Positive integer dims, even pixel dimensions (GPU/PBO/encoder alignment).
- Must fit within `sensorStreamWidth` and `sensorStreamHeight` (the actual Camera2 stream size, which never changes with crop).
- If crop dims equal sensor dims, crop is cleared (no GPU crop applied).

**GPU effect**:
- Crop updates FBO and PBO dimensions on the GL thread (blocking on `CountDownLatch` with 5 s safety timeout).
- All downstream consumers (preview, raw stream, video encoder, captureImage, 480p C++ sink) receive frames at cropped dims.
- Camera2 session remains at full sensor resolution — only GPU output is cropped.

---

## Inbound (hardware → Dart)

### FrameResult emission

**Source**: `repeatingCaptureCallback` (line 2730 in CameraController.kt) in `onCaptureCompleted()`.

**Throttling** (line 2810–2830):
- `captureResultCount` is incremented on every frame.
- Every 10th result (`captureResultCount % 10L == 0L`), a `CamFrameResult` is emitted via Pigeon FlutterApi.
- At 30 fps (assumed), this produces ≈3 Hz heartbeat.

**Extraction from TotalCaptureResult**:
```kotlin
val frameResult = CamFrameResult(
    iso = result.get(CaptureResult.SENSOR_SENSITIVITY)?.toLong(),
    exposureTimeNs = result.get(CaptureResult.SENSOR_EXPOSURE_TIME),
    focusDistanceDiopters = focusDist?.toDouble(),  // null during AF PASSIVE_SCAN
    wbGainR = wbGains?.red?.toDouble(),
    wbGainG = wbGains?.let { (it.greenEven.toDouble() + it.greenOdd.toDouble()) / 2.0 },  // average both greens
    wbGainB = wbGains?.blue?.toDouble(),
)
```

**Dispatch to Dart** (line 2829):
```kotlin
mainHandler.post { flutterApi.onFrameResult(handle, frameResult) {} }
```

**Pigeon FlutterApi** (`packages/cambrian_camera/pigeons/camera_api.dart:386`):
- `void onFrameResult(int handle, CamFrameResult result)` — the Dart callback registered via `CameraFlutterApi.setUp()`.

**Dart reception** (`packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:72–73`):
- A `StreamController<FrameResult>` broadcasts every throttled result.
- `frameResultStream` is a public broadcast stream that UI widgets listen to via `StreamBuilder`.
- Results decoded from Pigeon `CamFrameResult` → Dart `FrameResult` (line 23–24).

**UI subscription** (e.g., in `lib/main.dart`):
- Widgets bind to `camera.frameResultStream` to update live displays of ISO, exposure, focus, and WB gains.

---

## Concurrency model

### Latest-value-wins serializer (Dart side)

**Data structure**: Two slots in `CameraSettingsSerializer`.
- `_pending`: replacement value if one arrives while dispatch is in flight.
- `_inFlight`: boolean gate; prevents concurrent Pigeon calls.

**Atomicity**: No explicit locks — relies on Dart single-threaded event loop.
- `send()` checks `_inFlight` before mutating `_pending`.
- On completion callback, `_inFlight` is set false and `_pending` is checked.
- Event loop ensures atomicity of this sequence.

**Example**:
1. User rapidly scrubs ISO slider: ISO 100 → 200 → 300 → 400 → 500.
2. Dart emits: `send(100)` → `_inFlight=true`, schedules Pigeon call.
3. Before Pigeon returns: `send(200)` → `_pending=200`, returns.
4. Before Pigeon returns: `send(500)` → `_pending=500`, returns. (200 discarded.)
5. Pigeon returns, `_inFlight=false`, `_pending=500`.
6. Dispatch `500` to native side.

### Fire-and-forget for ProcessingParams

**Kotlin side** (line 1384–1400):
- `setProcessingParams()` is synchronous; returns immediately after posting to GPU pipeline.
- No wait or handshake.

**C++ side** (line 695–706):
- `GpuRenderer::setAdjustments()` holds a `std::lock_guard<std::mutex>` (`uniformMu_`) for the entire update.
- Protected fields: `brightness_`, `contrast_`, `saturation_`, `blackBalance_[]`, `gamma_`.
- Safe to call from any thread (Kotlin posts to GL handler, but lock serializes access).

**GL draw thread** (GpuPipeline-GL thread):
- Frame render loop acquires the same `uniformMu_` mutex before reading the uniforms for shader upload (line 370–374).
- Lock duration: microseconds (just a memcpy-like operation).
- Result: every GPU frame sees the most recent ProcessingParams without gaps or stalls.

### FrameResult emission (background → main)

**Background handler** (line 2829):
- `repeatingCaptureCallback.onCaptureCompleted()` runs on `backgroundHandler` (Camera2 callback thread).
- Calls `mainHandler.post { flutterApi.onFrameResult(...) {} }`.
- This schedules the FlutterApi call on the main Android thread.

**FlutterApi dispatch**:
- Main thread receives the Pigeon call and immediately invokes `CameraFlutterApi.setUp()` handler.
- Handler posts to Dart isolate's event loop via binary messenger.

**Dart reception**:
- `CameraFlutterApi._FlutterApiDispatcher` (line 3006–3055) receives the platform channel message and calls the static dispatcher.
- Dispatcher looks up the camera instance by handle and calls `_frameResultController.add(frameResult)` (line 3046).
- StreamController broadcasts to all subscribers on the next event loop tick.

**Thread-safety**: Flutter's binary messenger and event loop guarantee that the `add()` call is serialized; multiple cameras' FrameResults are queued and processed in FIFO order.

---

## Coupling rules

### ISO ↔ exposure auto-contagion

**Rule**: Setting either field to `Auto` propagates to the other.

**Implementation** (line 1033–1042):
```kotlin
val incomingIsoAuto = incoming.isoMode == "auto"
val incomingExpAuto = incoming.exposureMode == "auto"
if (incomingIsoAuto && !incomingExpAuto) {
    // iso explicitly set to auto — pull exposure along with it
    merged = merged.copy(exposureMode = "auto", exposureTimeNs = null)
} else if (incomingExpAuto && !incomingIsoAuto) {
    // exposure explicitly set to auto — pull iso along with it
    merged = merged.copy(isoMode = "auto", iso = null)
}
```

**Reason**: Camera2 ties ISO and exposure to a single `CONTROL_AE_MODE` flag. Auto-exposure (AE) cannot control only ISO or only exposure — it controls both together. Contagion ensures the Camera2 request stays consistent.

### Auto-wins-over-manual in mixed update

**Rule**: If one field is `Auto` and the other is `Manual` in the same `updateSettings()` call, both switch to auto.

**Implementation**: Same code as above. The contagion check examines `incoming` (what the caller explicitly sent), not the merged state. This handles the UI case where the slider position for one field is stale.

**Example**: User moves ISO slider to "auto" position, but the exposure slider is still at a manual position from before.
- `incoming = {isoMode="auto", exposureMode=null}` (exposure field not in the update).
- Check: `incomingIsoAuto=true`, so `merged.exposureMode` also becomes "auto".
- Result: both flip to auto, which is the user's intent.

**Cite**: line 1034–1042.

### settingsConflict error on missing AE seed

**Rule**: Manual ISO or exposure can only be set if at least one prior capture result has been received.

**Implementation** (line 1048–1076):
```kotlin
val finalIsoManual = merged.isoMode == "manual"
val finalExpManual = merged.exposureMode == "manual"
if (finalIsoManual && !finalExpManual) {
    val knownExp = lastCaptureSnapshot?.exposureTimeNs
    if (knownExp == null) {
        // emit SETTINGS_CONFLICT error, return early
        return
    }
    // auto-fill exposure from last AE
    merged = merged.copy(exposureMode = "manual", exposureTimeNs = knownExp)
}
```

**Reason**: When switching from auto to manual ISO, the user expects brightness to remain constant. The system seeds the manual exposure from the last AE-reported value so the camera starts from the same exposure it was already using. If no frame has arrived yet, this value is unknown, and setting manual ISO would cause a sudden brightness jump.

**Cite**: line 1050–1076; error code `CamErrorCode.SETTINGS_CONFLICT` (line 1057).

### Crop validation and rejection

**Rule**: `cropOutputSize` must satisfy: positive, even dimensions; within sensor bounds.

**Implementation** (line 1154–1159):
```kotlin
val err: String? = when {
    w <= 0 || h <= 0 -> "crop dims must be positive"
    (w and 1) != 0 || (h and 1) != 0 -> "crop dims must be even (GPU/PBO/encoder alignment)"
    w > sw || h > sh -> "crop ${w}x${h} exceeds configured stream ${sw}x${sh}"
    else -> null
}
if (err != null) {
    flutterApi.onError(handle, CamError(CamErrorCode.SETTINGS_CONFLICT, "invalid_crop: $err", false)) {}
    return false
}
```

**Cite**: line 1140–1168.

### EV compensation only in auto-exposure mode

**Rule**: `evCompensation` has no effect when `isoMode` or `exposureMode` is manual (AE is off).

**Implementation** (line 2429–2433):
```kotlin
// EV compensation — only applied by Camera2 when CONTROL_AE_MODE != OFF.
// Has no effect when isoMode or exposureMode is "manual" (AE is disabled).
settings.evCompensation?.let {
    set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, it.toInt())
}
```

**Reason**: Camera2 ignores `CONTROL_AE_EXPOSURE_COMPENSATION` when `CONTROL_AE_MODE=OFF`. The AE algorithm must be running for the compensation steps to be applied.

**Cite**: line 2429–2433; also documented in `camera_settings.dart:169–170`.

---

## Calibration loops

### White balance calibration

**Entry point**: `CambrianCamera.calibrateWhiteBalance()` (line 404 in controller).

**Algorithm** (line 427–444):
```dart
for (var i = 0; i < kWbMaxIterations; i++) {
    if (wbError(lastSample) < kWbTolerance) break;
    final gains = wbStep((r: gainR, g: gainG, b: gainB), lastSample);
    gainR = gains.r;
    gainB = gains.b;
    await updateSettings(
        CameraSettings(
            whiteBalance: WhiteBalance.manual(
                gainR: gainR, gainG: gainG, gainB: gainB
            ),
        ),
    );
    await Future<void>.delayed(const Duration(milliseconds: kCalibrationSettleMs));
    lastSample = await sampleCenterPatch();
}
```

**Convergence criterion** (`calibration.dart:79–82`):
```dart
double wbError(RgbSample s) {
    final errR = (s.r - s.g).abs();
    final errB = (s.b - s.g).abs();
    return (errR > errB ? errR : errB) / s.g.clamp(_kClipGuard, 1.0);
}
```
- Max per-channel deviation from green (reference), normalized by green.
- Error < 0.01 (1%) is imperceptible.

**Iteration step** (`calibration.dart:93–96`):
```dart
WbGains wbStep(WbGains gains, RgbSample s) {
    final newR = s.r > _kClipGuard ? gains.r * (s.g / s.r) : gains.r;
    final newB = s.b > _kClipGuard ? gains.b * (s.g / s.b) : gains.b;
    return (r: newR, g: gains.g, b: newB);
}
```
- Proportional correction: multiply each gain by `green / channel`.
- If a channel is clipped (< 0.001), skip it to avoid divide-by-zero.

**Timing** (`calibration.dart:55`):
- 200 ms settle time between iterations (~6 frames at 30 fps).
- Max 10 iterations → up to 2 s total; typical neutral scenes converge in 3–5 steps.

**Sampling** (`cambrian_camera_controller.dart:372–387`):
- Calls `sampleCenterPatch()` → `GpuPipeline.sampleCenterPatch()` → `nativeGpuSampleCenterPatch()`.
- Extracts trimmed-mean RGB (top/bottom 15% discarded per channel) from center 96×96 pixel patch of the GPU-processed frame.

**Error handling** (line 414–421):
```dart
final originalSettings = CameraSettings(
    whiteBalance: WhiteBalance.manual(
        gainR: initialGainR, gainG: initialGainG, gainB: initialGainB,
    ),
);
// ... if loop throws before final updateSettings, restore originalSettings
```
- Snapshots the starting gains; restores them on exception before re-throwing.

### Black balance calibration

**Entry point**: `CambrianCamera.calibrateBlackBalance()` (mentioned in line 449–504 of controller).

**Algorithm** (`calibration.dart:123–124`):
```dart
BbOffsets bbStep(BbOffsets acc, RgbSample s) =>
    (r: acc.r + s.r, g: acc.g + s.g, b: acc.b + s.b);
```
- Accumulates the measured residual sample into the offset.
- The GPU shader subtracts the accumulated offset: `output = max(input − acc, 0)`.
- Next iteration measures what remains after subtraction.

**Convergence criterion** (`calibration.dart:115–116`):
```dart
double bbError(RgbSample s) =>
    s.r > s.g ? (s.r > s.b ? s.r : s.b) : (s.g > s.b ? s.g : s.b);
```
- Maximum channel value.
- Error < 0.01 (1% brightness) is imperceptible; indicates the black point is calibrated.

**Timing and limits** (`calibration.dart:105–110`):
- Same 200 ms settle time.
- Max 10 iterations; dark scenes typically converge in 2–4 steps.

**Applied via** `setProcessingParams(ProcessingParams(blackR=..., blackG=..., blackB=...))`:
- Fire-and-forget to GPU shader.
- Sampled values flow back via `sampleCenterPatch()`.

---

## Diagram inputs

### Symbols

```yaml
Symbols:
- id: dart-ui-slider
  kind: function
  label: "UI slider drag (ISO/focus/zoom/etc)"
  cite: lib/camera/camera_settings_values.dart:30-55

- id: updateSettings
  kind: function
  label: "CambrianCamera.updateSettings(CameraSettings)"
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:312

- id: serializer
  kind: class
  label: "CameraSettingsSerializer"
  cite: packages/cambrian_camera/lib/src/camera_settings_serializer.dart:11

- id: pigeon-updateSettings
  kind: pigeon-stub
  label: "Pigeon HostApi.updateSettings"
  cite: packages/cambrian_camera/pigeons/camera_api.dart:320

- id: kotlin-updateSettings
  kind: function
  label: "CameraController.updateSettings(CamSettings)"
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1019

- id: buildCaptureRequest
  kind: function
  label: "buildCaptureRequest(CameraDevice, CamSettings)"
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2335

- id: camera2-captureRequest
  kind: class
  label: "Camera2 CaptureRequest"
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2338

- id: repeatingCaptureCallback
  kind: callback
  label: "CameraCaptureSession.CaptureCallback"
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2730

- id: frameResult-throttle
  kind: function
  label: "Throttled FrameResult every 10 frames"
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2811

- id: pigeon-onFrameResult
  kind: pigeon-stub
  label: "Pigeon FlutterApi.onFrameResult"
  cite: packages/cambrian_camera/pigeons/camera_api.dart:386

- id: dart-frameResultStream
  kind: stream
  label: "frameResultStream broadcast"
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:293

- id: setProcessingParams
  kind: function
  label: "CambrianCamera.setProcessingParams(ProcessingParams)"
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:348

- id: pigeon-setProcessingParams
  kind: pigeon-stub
  label: "Pigeon HostApi.setProcessingParams"
  cite: packages/cambrian_camera/pigeons/camera_api.dart:325

- id: kotlin-setProcessingParams
  kind: function
  label: "CameraController.setProcessingParams(CamProcessingParams)"
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1384

- id: gpu-setAdjustments
  kind: function
  label: "GpuPipeline.setAdjustments(...)"
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:336

- id: cpp-setAdjustments
  kind: function
  label: "GpuRenderer::setAdjustments (C++)"
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:695

- id: shader-uniform-brightness
  kind: texture
  label: "GL uniform uBrightness"
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:49

- id: shader-uniform-contrast
  kind: texture
  label: "GL uniform uContrast"
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:50

- id: shader-uniform-saturation
  kind: texture
  label: "GL uniform uSaturation"
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:51

- id: shader-uniform-blackBalance
  kind: texture
  label: "GL uniform uBlackBalance"
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:52

- id: shader-uniform-gamma
  kind: texture
  label: "GL uniform uGamma"
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:53

- id: applyCropOutputSize
  kind: function
  label: "applyCropOutputSize(CamSize)"
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1140

- id: gpu-setCropOutput
  kind: function
  label: "GpuPipeline.setCropOutput(CamSize)"
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:300+

- id: sampleCenterPatch
  kind: function
  label: "CambrianCamera.sampleCenterPatch()"
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:384

- id: calibrateWhiteBalance
  kind: function
  label: "CambrianCamera.calibrateWhiteBalance()"
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:404

- id: calibrateBlackBalance
  kind: function
  label: "CambrianCamera.calibrateBlackBalance()"
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:449

- id: uniformMu
  kind: mutex
  label: "GpuRenderer::uniformMu_ (C++ mutex)"
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:698

- id: appliedSettings
  kind: mailbox
  label: "CameraController.appliedSettings (last accepted ISP state)"
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:256

- id: lastCaptureSnapshot
  kind: mailbox
  label: "CameraController.lastCaptureSnapshot (TotalCaptureResult cache)"
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:251
```

### Edges

```yaml
Edges:
- from: dart-ui-slider
  to: updateSettings
  label: "user slides ISO/focus/zoom"
  mechanism: sync-call
  cite: lib/main.dart:280+

- from: updateSettings
  to: serializer
  label: "enqueue settings"
  mechanism: sync-call
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:315

- from: serializer
  to: pigeon-updateSettings
  label: "dispatch when free (latest-value-wins)"
  mechanism: pigeon
  cite: packages/cambrian_camera/lib/src/camera_settings_serializer.dart:35

- from: pigeon-updateSettings
  to: kotlin-updateSettings
  label: "cross-language boundary"
  mechanism: pigeon
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CambrianCameraPlugin.kt:289-290

- from: kotlin-updateSettings
  to: buildCaptureRequest
  label: "merge + construct ISP request"
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1112

- from: buildCaptureRequest
  to: camera2-captureRequest
  label: "set ISP keys (SENSOR_SENSITIVITY, LENS_FOCUS_DISTANCE, etc)"
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2347-2433

- from: camera2-captureRequest
  to: camera2-captureRequest
  label: "setRepeatingRequest → Camera2 applies on next frame"
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1114

- from: kotlin-updateSettings
  to: applyCropOutputSize
  label: "validate and apply crop if present"
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1097-1101

- from: applyCropOutputSize
  to: gpu-setCropOutput
  label: "update GPU output dimensions"
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1098

- from: setProcessingParams
  to: pigeon-setProcessingParams
  label: "fire-and-forget async call"
  mechanism: pigeon
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:351

- from: pigeon-setProcessingParams
  to: kotlin-setProcessingParams
  label: "cross-language boundary"
  mechanism: pigeon
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CambrianCameraPlugin.kt:318-319

- from: kotlin-setProcessingParams
  to: gpu-setAdjustments
  label: "forward to GPU thread"
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1391

- from: gpu-setAdjustments
  to: cpp-setAdjustments
  label: "JNI call nativeGpuSetAdjustments"
  mechanism: jni
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:347

- from: cpp-setAdjustments
  to: uniformMu
  label: "acquire mutex, update uniforms"
  mechanism: mutex-protected-write
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:698

- from: uniformMu
  to: shader-uniform-brightness
  label: "store brightness"
  mechanism: atomic-store
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:699

- from: uniformMu
  to: shader-uniform-contrast
  label: "store contrast"
  mechanism: atomic-store
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:700

- from: uniformMu
  to: shader-uniform-saturation
  label: "store saturation"
  mechanism: atomic-store
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:701

- from: uniformMu
  to: shader-uniform-blackBalance
  label: "store black R/G/B"
  mechanism: atomic-store
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:702-704

- from: uniformMu
  to: shader-uniform-gamma
  label: "store gamma"
  mechanism: atomic-store
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:705

- from: repeatingCaptureCallback
  to: lastCaptureSnapshot
  label: "extract TotalCaptureResult fields (ISO, exposure, focus, WB gains)"
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2776

- from: lastCaptureSnapshot
  to: appliedSettings
  label: "used as seed for latch-from-last-AE when switching to manual"
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1051

- from: repeatingCaptureCallback
  to: frameResult-throttle
  label: "every 10th result (≈3 Hz at 30 fps)"
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2811

- from: frameResult-throttle
  to: pigeon-onFrameResult
  label: "post to mainHandler then emit via Pigeon"
  mechanism: pigeon
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2829

- from: pigeon-onFrameResult
  to: dart-frameResultStream
  label: "dispatch to _frameResultController.add()"
  mechanism: channel-send
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:72-73

- from: dart-frameResultStream
  to: dart-ui-slider
  label: "UI widgets subscribe and update displays"
  mechanism: stream-emit
  cite: lib/main.dart:290+

- from: calibrateWhiteBalance
  to: sampleCenterPatch
  label: "read center patch RGB"
  mechanism: sync-call
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:444

- from: sampleCenterPatch
  to: updateSettings
  label: "apply WB correction step: gains *= green/channel"
  mechanism: sync-call
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:432

- from: calibrateBlackBalance
  to: sampleCenterPatch
  label: "read center patch RGB"
  mechanism: sync-call
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:470+

- from: calibrateBlackBalance
  to: setProcessingParams
  label: "apply BB correction step: offsets += sample"
  mechanism: sync-call
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:470+
```

### Sequences

```yaml
Sequences:
- name: "ISO slider tap → CaptureRequest"
  steps:
    - actor: dart-ui-slider
      op: "user moves slider from 200 to 400"
      cite: lib/camera/camera_settings_values.dart:32
    - actor: updateSettings
      op: "enqueue CameraSettings(iso=Manual(400))"
      cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:312
    - actor: serializer
      op: "schedule dispatch via Pigeon (or replace pending if in-flight)"
      cite: packages/cambrian_camera/lib/src/camera_settings_serializer.dart:24-30
    - actor: pigeon-updateSettings
      op: "cross-language call to Kotlin handler"
      cite: packages/cambrian_camera/pigeons/camera_api.dart:320
    - actor: kotlin-updateSettings
      op: "merge incoming settings with appliedSettings"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1033
    - actor: kotlin-updateSettings
      op: "check auto-propagation: iso manual + exp null → seed exp from lastCaptureSnapshot"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1048-1062
    - actor: buildCaptureRequest
      op: "construct Camera2 CaptureRequest: CONTROL_AE_MODE=OFF, SENSOR_SENSITIVITY=400"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2347-2354
    - actor: camera2-captureRequest
      op: "Camera2 applies request on next capture: sensor uses 400 ISO"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1114

- name: "ProcessingParams update → shader uniforms"
  steps:
    - actor: setProcessingParams
      op: "call with ProcessingParams(brightness=0.3, saturation=0.5, ...)"
      cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:348
    - actor: pigeon-setProcessingParams
      op: "async dispatch to Kotlin"
      cite: packages/cambrian_camera/pigeons/camera_api.dart:325
    - actor: kotlin-setProcessingParams
      op: "save to lastProcessingParams and SharedPreferences"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1385-1386
    - actor: gpu-setAdjustments
      op: "forward to GpuPipeline.setAdjustments()"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1391
    - actor: cpp-setAdjustments
      op: "JNI call; acquire uniformMu_ mutex, store brightness_/contrast_/saturation_/blackBalance_/gamma_"
      cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:698-706
    - actor: cpp-setAdjustments
      op: "release mutex; next GPU frame will read new uniforms"
      cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:706

- name: "Crop output size update"
  steps:
    - actor: updateSettings
      op: "enqueue CameraSettings(cropOutputSize=CameraSize(width=1920, height=1080))"
      cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:312
    - actor: serializer
      op: "dispatch via Pigeon when free"
      cite: packages/cambrian_camera/lib/src/camera_settings_serializer.dart:35
    - actor: kotlin-updateSettings
      op: "extract cropOutputSize from incoming settings"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1097
    - actor: applyCropOutputSize
      op: "validate dims: positive, even, within sensorStreamWidth/Height"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1154-1159
    - actor: applyCropOutputSize
      op: "on error: emit SETTINGS_CONFLICT, return without updating FBO"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1162-1167
    - actor: gpu-setCropOutput
      op: "post to GL handler, reallocate FBOs/PBOs to crop size"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1098
    - actor: gpu-setCropOutput
      op: "block on CountDownLatch until resize complete (safety timeout 5s)"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1083-1090

- name: "Frame result emission and inbound flow"
  steps:
    - actor: repeatingCaptureCallback
      op: "Camera2 fires onCaptureCompleted(TotalCaptureResult) on backgroundHandler"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2764
    - actor: repeatingCaptureCallback
      op: "extract all ISO, exposure, focus, WB gains into lastCaptureSnapshot"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2776-2806
    - actor: repeatingCaptureCallback
      op: "check throttle: captureResultCount % 10 == 0? (≈3 Hz at 30 fps)"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2811
    - actor: frameResult-throttle
      op: "construct CamFrameResult from TotalCaptureResult fields"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2821-2828
    - actor: pigeon-onFrameResult
      op: "mainHandler.post { flutterApi.onFrameResult(handle, frameResult) }"
      cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2829
    - actor: dart-frameResultStream
      op: "_frameResultController.add(frameResult) on main thread"
      cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:72-73
    - actor: dart-ui-slider
      op: "StreamBuilder rebuilds UI with new ISO/exposure/focus values"
      cite: lib/main.dart:290+

- name: "White balance calibration loop"
  steps:
    - actor: calibrateWhiteBalance
      op: "snapshot initial gains, take patchBefore sample"
      cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:423-424
    - actor: calibrateWhiteBalance
      op: "loop: check wbError(sample) < 0.01 tolerance"
      cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:427-428
    - actor: calibrateWhiteBalance
      op: "iteration: gainR *= sample.g / sample.r; gainB *= sample.g / sample.b"
      cite: packages/cambrian_camera/lib/src/calibration.dart:94-95
    - actor: updateSettings
      op: "apply corrected gains: WhiteBalance.manual(gainR, gainG, gainB)"
      cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:432-439
    - actor: calibrateWhiteBalance
      op: "wait 200 ms for Camera2 to apply new gains and expose fresh frame"
      cite: packages/cambrian_camera/lib/src/calibration.dart:55
    - actor: sampleCenterPatch
      op: "read center 96×96 patch RGB (trimmed-mean)"
      cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:444
    - actor: calibrateWhiteBalance
      op: "loop continues or breaks on convergence (max 10 iterations)"
      cite: packages/cambrian_camera/lib/src/calibration.dart:73

- name: "Black balance calibration loop"
  steps:
    - actor: calibrateBlackBalance
      op: "take patchBefore sample, init offset accumulator to (0, 0, 0)"
      cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:460+
    - actor: calibrateBlackBalance
      op: "loop: check bbError(sample) < 0.01 (max channel value < 1%)"
      cite: packages/cambrian_camera/lib/src/calibration.dart:115
    - actor: calibrateBlackBalance
      op: "iteration: accumulator += sample (each channel)"
      cite: packages/cambrian_camera/lib/src/calibration.dart:123-124
    - actor: setProcessingParams
      op: "apply offset: ProcessingParams(blackR=acc.r, blackG=acc.g, blackB=acc.b)"
      cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:470+
    - actor: calibrateBlackBalance
      op: "wait 200 ms, sample again (GPU shader subtracts black offset each frame)"
      cite: packages/cambrian_camera/lib/src/calibration.dart:55
    - actor: sampleCenterPatch
      op: "read residual RGB after black offset applied"
      cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:470+
    - actor: calibrateBlackBalance
      op: "loop continues or breaks on convergence (max 10 iterations)"
      cite: packages/cambrian_camera/lib/src/calibration.dart:111
```

### Threads

```yaml
Threads:
- name: "Dart event loop (main isolate)"
  owns: [updateSettings, setProcessingParams, calibrateWhiteBalance, calibrateBlackBalance, sampleCenterPatch, dart-frameResultStream, dart-ui-slider]
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:1-25

- name: "Android main thread (AKA UI thread)"
  owns: [pigeon-onFrameResult, FlutterApi dispatch]
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2829

- name: "backgroundHandler (Camera2 callbacks)"
  owns: [repeatingCaptureCallback, Camera2 capture callbacks, kotlin-updateSettings background post]
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:120

- name: "GpuPipeline-GL (HandlerThread for GL rendering)"
  owns: [gpu-setAdjustments, shader uniform upload, gpu-setCropOutput, FBO/PBO allocation]
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:43-44

- name: "Camera2 HAL callbacks (system thread)"
  owns: [TotalCaptureResult capture delivery]
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2764
```

### Sync primitives

```yaml
Sync primitives:
- name: "_inFlight + _pending (Dart serializer)"
  kind: mailbox
  guards: [CameraSettings in-flight state, latest-value-wins queue]
  cite: packages/cambrian_camera/lib/src/camera_settings_serializer.dart:17-18

- name: "GpuRenderer::uniformMu_ (C++ mutex)"
  kind: mutex
  guards: [brightness_, contrast_, saturation_, blackBalance_[], gamma_]
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:698

- name: "CameraController.appliedSettings"
  kind: mailbox
  guards: [last-accepted ISP settings for reference and replay]
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:256

- name: "CameraController.lastCaptureSnapshot"
  kind: mailbox
  guards: [most recent TotalCaptureResult fields for latch-from-last-AE]
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:251

- name: "GpuPipeline.pendingSampleCallback (AtomicReference)"
  kind: atomic
  guards: [sampleCenterPatch callback ownership during stop()]
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:50
```
