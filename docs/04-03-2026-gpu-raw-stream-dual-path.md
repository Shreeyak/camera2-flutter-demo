# Plan: GPU Raw Stream — Dual-Path Rendering with Passthrough Shader

## Context

The GPU pipeline renders camera frames through a color shader (brightness/contrast/saturation/black
level). C++ consumers and the Flutter preview both receive post-shader RGBA. There is no way to
get the camera's native color output (before transforms) through the GPU path.

**Goal:** Add an optional raw stream that renders the same OES texture through a passthrough shader
(no color math) to a separate 720p FBO, delivering raw RGBA to both a Flutter preview widget and
C++ sinks. The processed path is unchanged. C++ consumers choose their stream via `SinkRole`.

**Key decisions made during brainstorm:**
- Raw stream is **on-demand** via `enableRawStream: bool` flag at init time (not per-frame)
- Raw resolution: height from Dart param (`rawStreamHeight`), width auto-computed from stream
  aspect ratio and returned to Dart via CamCapabilities
- Separate passthrough fragment shader (not identity uniforms) for bit-exact raw
- Raw preview is independent of raw sinks — preview surface blit only if surface exists
- `buildRawPreview()` throws `StateError` if raw was not enabled at open time
- Failure in raw init → log descriptive error, disable raw, processed pipeline continues
- SCALER_CROP may change aspect ratio, so Kotlin computes raw dimensions from actual stream size
  and returns them to Dart

---

## Task 1 — Pigeon API: add enableRawStream + raw capabilities fields

**Files:**
- `packages/cambrian_camera/pigeons/camera_api.dart`
- Regenerated: `lib/src/messages.g.dart`, `Messages.g.kt`, `ios/Classes/Messages.g.swift`

**Changes to `camera_api.dart`:**

In `HostApi.open()`, add parameters:
```dart
void open({
  required bool enableRawStream,    // new
  required int rawStreamHeight,     // new — 0 if !enableRawStream
});
```
(Check existing `open()` signature and add to it.)

In `CamCapabilities`, replace old `yuvStreamWidth`/`yuvStreamHeight`/`rawStreamTextureId` with:
```dart
int rawStreamTextureId;   // Flutter texture ID, 0 if raw disabled
int rawStreamWidth;       // actual computed width, 0 if raw disabled
int rawStreamHeight;      // requested height, 0 if raw disabled
```
(These fields may already exist from the old CPU path — update their semantics/docs.)

Regenerate: `cd packages/cambrian_camera && dart run pigeon --input pigeons/camera_api.dart`

---

## Task 2 — Dart SDK: wire enableRawStream + buildRawPreview()

**Files:**
- `packages/cambrian_camera/lib/src/camera_state.dart` (CameraCapabilities)
- `packages/cambrian_camera/lib/cambrian_camera.dart` or `lib/src/cambrian_camera_controller.dart`

**CameraCapabilities** — update to include `rawStreamTextureId`, `rawStreamWidth`,
`rawStreamHeight` (matching Pigeon). Update `fromPigeon()` factory.

**CambrianCamera.open()** — add `enableRawStream` and `rawStreamHeight` params. Pass through
Pigeon to Kotlin.

**CambrianCamera.buildRawPreview()** — new method:
```dart
Widget buildRawPreview({BoxFit fit = BoxFit.contain, Widget? placeholder}) {
  if (!_enableRawStream) {
    throw StateError('Raw stream not enabled. Pass enableRawStream: true to open().');
  }
  final texId = _capabilities.rawStreamTextureId;
  if (texId == 0) {
    return placeholder ?? const ColoredBox(color: Colors.black);
  }
  return FittedBox(
    fit: fit,
    child: SizedBox(
      width: _capabilities.rawStreamWidth.toDouble(),
      height: _capabilities.rawStreamHeight.toDouble(),
      child: Texture(textureId: texId),
    ),
  );
}
```

Run `flutter test` — all existing tests still pass.

---

## Task 3 — Kotlin: rawSurfaceProducer + GpuPipeline raw params

**Files:**
- `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CambrianCameraPlugin.kt`
- `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt`
- `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt`

**CambrianCameraPlugin.kt:**
- In `open()`: if `enableRawStream`, create `rawSurfaceProducer`, else null.
- Pass `rawSurfaceProducer` and `rawStreamHeight` to CameraController.
- In `CameraSession`: include `rawSurfaceProducer?` (nullable). Release on cleanup if non-null.

**CameraController.kt:**
- Accept `enableRawStream: Boolean`, `rawStreamHeight: Int` in constructor.
- In `startCaptureSession()`:
  - If enableRawStream: compute `rawW = round_even(streamW.toFloat() / streamH * rawStreamHeight)`,
    `rawH = rawStreamHeight`. Set rawSurfaceProducer size.
  - Pass `rawPreviewSurface` (or null), `rawW`, `rawH` to GpuPipeline constructor.
- In `getCapabilities()`: return `rawStreamTextureId = rawSurfaceProducer?.id() ?: 0`,
  `rawStreamWidth = rawW`, `rawStreamHeight = rawH`.

**GpuPipeline.kt:**
- Constructor gains `rawPreviewSurface: Surface?`, `rawW: Int`, `rawH: Int`.
- `start()`: pass rawPreviewSurface + rawW/rawH to `nativeGpuInit`.
- `onFrameAvailable()`: no changes — `nativeGpuDrawAndReadback` handles raw internally.

---

## Task 4 — C++ GpuRenderer: passthrough shader + rawFBO + rawPBOs

**Files:**
- `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h`
- `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp`
- `packages/cambrian_camera/android/src/main/cpp/src/CameraBridge.cpp`

**GpuRenderer changes:**

`init()` signature gains: `ANativeWindow* rawPreviewWindow, int rawW, int rawH`

If rawW > 0 && rawH > 0:
- Compile passthrough fragment shader:
  ```glsl
  #version 300 es
  #extension GL_OES_EGL_image_external_essl3 : require
  precision mediump float;
  in vec2 vTexCoord;
  out vec4 fragColor;
  uniform samplerExternalOES uTexture;
  void main() {
      fragColor = texture(uTexture, vTexCoord);
  }
  ```
- Link passthrough program (reuse existing vertex shader)
- Create rawFBO(rawW, rawH) with RGBA8 color attachment
- Create rawPBOs[2] (double-buffered, rawW * rawH * 4 bytes each)
- If rawPreviewWindow != null: create rawEGLSurface from it
- Log: `LOGD("GpuRenderer: raw stream enabled %dx%d", rawW, rawH)`

If any raw resource allocation fails:
- `LOGE("GpuRenderer: raw stream init failed at [step]: [GL error] — disabling raw")`
- Set `rawW_ = 0` to disable raw path. Processed pipeline continues normally.

**drawAndReadback()** gains third callback:
```cpp
using RawCallback = std::function<void(const uint8_t* rgba, int w, int h,
                                        int stride, uint64_t frameId,
                                        const FrameMetadata& meta)>;

void drawAndReadback(GLuint oesTex, const float* texMat, uint64_t frameId,
                     const FrameMetadata& meta,
                     FullResCallback onFullRes,
                     TrackerCallback onTracker,
                     RawCallback onRaw);         // new
```

Per-frame logic (after existing processed + tracker path):
```
if rawW_ > 0:
    glBindFramebuffer(rawFBO_)
    glViewport(0, 0, rawW_, rawH_)
    glUseProgram(passthroughProgram_)
    // bind OES texture, set transform matrix uniform
    glDrawArrays(GL_TRIANGLE_STRIP, 4)

    if rawEGLSurface_:
        glBindFramebuffer(READ, rawFBO_)
        glBindFramebuffer(DRAW, 0)  // rawEGLSurface
        glBlitFramebuffer(...)
        eglSwapBuffers(rawEGLSurface_)

    // PBO readback (same double-buffer pattern as processed)
    if !rawFirstFrame_:
        glBindBuffer(rawPBO_[readIdx])
        map → onRaw(data, rawW_, rawH_, rawW_*4, frameId, meta)
        unmap
    glBindBuffer(rawPBO_[writeIdx])
    glReadPixels(0, 0, rawW_, rawH_, GL_RGBA, GL_UNSIGNED_BYTE, 0)
    rawFirstFrame_ = false
    swap readIdx/writeIdx
```

**CameraBridge.cpp — nativeGpuInit:**
- Add `rawPreviewSurface`, `rawW`, `rawH` params.
- Convert rawPreviewSurface to ANativeWindow (if non-null), pass to GpuRenderer.

**CameraBridge.cpp — nativeGpuDrawAndReadback:**
- Add third lambda:
  ```cpp
  [pipeline](const uint8_t* d, int w, int h, int s,
             uint64_t fId, const cam::FrameMetadata& m) {
      pipeline->deliverRawRgba(d, w, h, s, fId, m);
  }
  ```

**CameraBridge.cpp — remove old nativeSetRawPreviewWindow:**
- The old CPU raw preview JNI function is dead code. Remove it.

---

## Task 5 — C++ ImagePipeline: RAW sink role + deliverRawRgba

**Files:**
- `packages/cambrian_camera/android/src/main/cpp/include/cambrian_camera_native.h` (SinkRole enum)
- `packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h`
- `packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp`

**SinkRole enum:**
```cpp
enum class SinkRole { FULL_RES, TRACKER, RAW };
```

**ImagePipeline:**
- Add `deliverRawRgba(const uint8_t* rgba, int w, int h, int stride, uint64_t frameId, const FrameMetadata& meta)`.
- Same dispatch pattern as `deliverFullResRgba`: create SharedFrame, publish to RAW consumers.
- Consumer thread management: RAW consumers get their own consumer thread (same pattern as
  FULL_RES and TRACKER).

---

## Task 6 — Demo app: two-pane layout with raw preview

**File:** `lib/main.dart`

- Update `_openCamera()` to pass `enableRawStream: true, rawStreamHeight: 720`.
- Update `_buildRawPreview()` to use `camera.buildRawPreview(fit: BoxFit.cover)`.
- Keep the two-pane `Row` layout: left = raw, right = processed + sidebar.
- Initial `ProcessingParams(saturation: 3.0)` makes the difference visible (left = natural
  colors, right = high saturation).

---

## Task 7 — Extend sink consistency test: verify raw + processed delivery

**Files:**
- `packages/cambrian_camera/android/src/main/cpp/src/CameraBridge.cpp`
- `packages/cambrian_camera/android/src/androidTest/kotlin/com/cambrian/camera/GpuPipelineTestBridge.kt`
- `packages/cambrian_camera/android/src/androidTest/kotlin/com/cambrian/camera/GpuSinkConsistencyTest.kt`

**Add JNI helper `nativeGetLastDeliveredRgba`:**
- In the anonymous test-sink namespace, alongside the `shared_ptr<atomic<int>>` counter,
  also store the last delivered `vector<uint8_t>` bytes and dimensions (w, h).
- New JNI function: `nativeGetLastDeliveredRgba(pipelineHandle, sinkName): ByteArray?`
- Declare in `GpuPipelineTestBridge.kt`.

**New test `rawSinkReceivesFrameAfterDrawAndReadback`:**
- Init with `rawW = 320, rawH = 240` (small for fast test).
- Register RAW sink via `nativeAddDeliveryCountSink` with `SinkRole::RAW`.
- Call `nativeGpuDrawAndReadback` twice (PBO double-buffer).
- Poll delivery count → assert > 0.
- Call `nativeGetLastDeliveredRgba` → assert non-null, correct size (320*240*4),
  at least one non-zero byte.

**Extend existing `sinkReceivesFrameAfterDrawAndReadback`:**
- Add byte-level assertions: `nativeGetLastDeliveredRgba` returns non-null,
  correct size (width*height*4), at least one non-zero byte.
- Comment: "Both the EGL preview blit and this PBO readback read from the same FBO;
  identical pixel content is guaranteed by construction."

---

## Task 8 — Kotlin unit tests: raw stream wiring

**File:**
- `packages/cambrian_camera/android/src/test/kotlin/com/cambrian/camera/CameraControllerGpuTest.kt`

Add tests:
- `setProcessingParams does not affect raw stream` — verify setAdjustments is called (for
  processed) but no raw-specific call exists (raw has no adjustable params).
- `getCapabilities returns raw dimensions when enabled` — verify rawStreamTextureId != 0,
  rawStreamWidth/Height match computed values.
- `getCapabilities returns zero raw fields when disabled` — verify all raw fields are 0.

---

## Task 9 — Update documentation

**Files:**
- `docs/cambrian-camera-usage-guide.md`
- `docs/camera2-plugin-architecture-v2.md` (find this file, update architecture diagrams)

**Usage guide updates:**
- Add `enableRawStream` and `rawStreamHeight` to the `open()` API section.
- Document `buildRawPreview()` alongside `buildPreview()`.
- Add `SinkRole::RAW` to the C++ consumer section.
- Update the architecture frame-path diagram:
  ```
  Camera2 → SurfaceTexture → OES texture
    ├── [color shader]       → processedFBO → preview + FULL_RES/TRACKER sinks
    └── [passthrough shader] → rawFBO(720p) → raw preview + RAW sinks
  ```

**Architecture doc updates:**
- Add the dual-path rendering architecture.
- Document the passthrough shader.
- Document failure handling (raw init fails → processed continues).
- Document resource budget.

---

## Verification

```bash
# Dart tests
cd packages/cambrian_camera && flutter test

# Dart analysis
flutter analyze lib/ packages/cambrian_camera/lib/

# Kotlin unit tests
cd packages/cambrian_camera/android && ./gradlew test

# On device: two-pane preview (raw left, processed right)
flutter run --debug

# Logcat: raw stream enabled
adb logcat | grep -E "raw stream|nativeGpuInit"

# Logcat: no old CPU YUV path
adb logcat | grep nativeDeliverYuv   # should be empty

# Instrumented tests (sink consistency)
cd packages/cambrian_camera/android && ./gradlew connectedAndroidTest
```
