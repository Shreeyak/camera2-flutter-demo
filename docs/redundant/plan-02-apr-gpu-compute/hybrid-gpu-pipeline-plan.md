# Hybrid GPU Pipeline: ISP + Single-Pass GL Shader

## Context

The current CPU pipeline converts YUV→BGR with OpenCV and applies saturation with manual threading. At 4K this is slow. We're replacing it with a hybrid architecture:

- **ISP** handles white balance (Bayer-level gains via `COLOR_CORRECTION_GAINS`, most accurate) and crop region (`SCALER_CROP_REGION`)
- **GPU** handles brightness, contrast, saturation, black balance, and UV crop remap (instant slider response, single shader pass)
- **No library dependency** — one custom fragment shader
- Vendor S-curve and AWB stay intact by default (`TONEMAP_MODE_HIGH_QUALITY`); AWB is overridden only when the user sets a manual white balance patch

> **OES texture color space note:** `samplerExternalOES` delivers gamma-encoded RGB in BT.709 color space (the Camera2 ISP outputs YCbCr BT.709; the EGL driver converts to RGB before the shader sees it). All shader operations therefore run in gamma space. Saturation luma weights must be BT.709 `(0.2126, 0.7152, 0.0722)` to match.

---

## Architecture

```
Camera2 ISP (Level 3, API 36):
  COLOR_CORRECTION_GAINS       → white balance: per-channel Bayer gains
                                  (from user-selected patch; AWB disabled when active)
  SCALER_CROP_REGION           → sensor crop rectangle (Rect in sensor coords)
  TONEMAP_MODE_HIGH_QUALITY    → vendor S-curve preserved
  AWB (default: enabled)       → overridden only when user sets manual WB patch
  │
  ▼ zero-copy (YCbCr BT.709, gamma-encoded → RGB via EGL driver)
SurfaceTexture (GL_TEXTURE_EXTERNAL_OES)
  │ updateTexImage() on GL thread
  ▼ one shader pass
Fragment Shader:
  - YUV→RGB (free via samplerExternalOES; BT.709 matrix applied by EGL driver)
  - UV remap for crop alignment
  - contrast (midpoint pivot, gamma space)
  - brightness (additive, gamma space)
  - saturation (BT.709 luma-mix)
  - black balance (per-channel additive lift, vec3 uniform)
  │
  ▼
FBO (RGBA8, 4K)
  │                          │
  ▼                          ▼
Preview surface           PBO readback (async)
(GPU-direct)                │
                            ▼ memcpy into SharedFrame
                    publishToConsumers()
                      ├── stitcher sink
                      ├── tracker sink
                      └── other sinks
```

### Latency characteristics

| Parameter | Update latency | Where |
|-----------|---------------|-------|
| Brightness | Instant (next frame) | GPU uniform |
| Contrast | Instant (next frame) | GPU uniform |
| Saturation | Instant (next frame) | GPU uniform |
| Black balance | Instant (next frame) | GPU uniform (additive per-channel lift) |
| Crop (UV remap) | Instant (next frame) | GPU uniform |
| Crop (sensor region) | 2-3 frames | ISP via `SCALER_CROP_REGION` CaptureRequest |
| White balance (manual patch) | 2-3 frames | ISP via `COLOR_CORRECTION_GAINS` (Bayer-level, most accurate) |

---

## Alternatives Considered

### Pure ISP (rejected)
Push everything into Camera2 CaptureRequest (TonemapCurve for brightness/contrast, COLOR_CORRECTION_TRANSFORM for saturation). Simplest code, but:
- Overrides vendor tone mapping S-curve (worse baseline image quality)
- Overrides auto white balance (must manually compose with AWB matrix)
- 2-3 frame latency on ALL slider changes (sluggish UX)

### Pure GPU / android-gpuimage-plus (rejected)
All adjustments via GPU shader library. Instant sliders, but:
- Black balance in post-processing is less accurate than Bayer-level ISP gains
- Heavy library dependency for what amounts to 4 uniforms
- android-gpuimage-plus chains filters as sequential FBO bounces (unnecessary overhead for our use case)

### Hybrid (chosen)
Best of both: ISP for what it does best (Bayer-level ops), GPU for what it does best (instant uniform updates). No library dependency.

---

## Implementation Steps

### Step 1: GL renderer (C++ / GLES 3.x)

Create a self-contained GL renderer class that manages the EGL context, shader, FBO, and PBO.

**New file:** `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h`
**New file:** `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp`

```cpp
class GpuRenderer {
public:
    /// Initialize EGL context, compile shader, allocate FBO + PBO.
    /// Called once when camera session starts.
    bool init(int width, int height);

    /// Called per frame on the GL thread after SurfaceTexture.updateTexImage().
    /// Renders OES texture through the adjustment shader into the FBO.
    void draw(GLuint oesTexture, const float* texMatrix);

    /// Render the FBO result to the given EGL surface (preview).
    void renderToSurface();

    /// Async PBO readback. Returns pointer valid until unmapReadback().
    /// Issues glReadPixels into PBO, maps it for CPU read.
    const uint8_t* mapReadback(int* outWidth, int* outHeight, int* outStride);
    void unmapReadback();

    /// Update shader uniforms (thread-safe, applied on next draw).
    void setAdjustments(float brightness, float contrast, float saturation);
    void setCrop(float scaleX, float scaleY, float offsetX, float offsetY);

    void release();

private:
    GLuint program_;
    GLuint fbo_, fboTexture_;
    GLuint pbo_[2];          // double-buffered PBO
    int pboIndex_ = 0;
    int width_, height_;

    // Uniform locations
    GLint uTexture_, uBrightness_, uContrast_, uSaturation_;
    GLint uCropScale_, uCropOffset_, uTexMatrix_;

    // Pending uniform values (atomic or mutex-protected)
    std::atomic<float> brightness_{0.f}, contrast_{1.f}, saturation_{1.f};
    float cropScale_[2] = {1.f, 1.f};
    float cropOffset_[2] = {0.f, 0.f};
};
```

**The shader:**
```glsl
// Input: gamma-encoded RGB in BT.709 color space.
// The EGL driver converts YCbCr (BT.709) → RGB before the shader sees the texture.
// All operations run in gamma space — correct for interactive adjustments.
// Operation order: black balance → brightness → contrast → saturation.
// Black balance is subtractive (sensor floor removal), not additive lift.
#version 300 es
#extension GL_OES_EGL_image_external : require
precision mediump float;

uniform samplerExternalOES uTexture;
uniform mat4  uTexMatrix;    // SurfaceTexture.getTransformMatrix() — mandatory
uniform float uBrightness;   // [-1, 1],  0.0 = identity
uniform float uContrast;     // [0.5, 2], 1.0 = identity
uniform float uSaturation;   // [0, 2],   1.0 = identity
uniform vec3  uBlackBalance; // per-channel sensor floor; subtractive: max(rgb - bb, 0)
uniform vec2  uCropScale;    // UV scale for crop remap, vec2(1) = no crop
uniform vec2  uCropOffset;   // UV offset for crop remap, vec2(0) = no crop

in  vec2 vTexCoord;
out vec4 fragColor;

const vec3 kLuma = vec3(0.2126, 0.7152, 0.0722);

void main() {
    vec2 uv    = vTexCoord * uCropScale + uCropOffset;
    vec2 texUv = (uTexMatrix * vec4(uv, 0.0, 1.0)).xy;
    vec3 rgb   = texture(uTexture, texUv).rgb;

    rgb = max(rgb - uBlackBalance, 0.0);        // 1. black balance (sensor floor removal)
    rgb += uBrightness;                          // 2. brightness
    rgb = (rgb - 0.5) * uContrast + 0.5;        // 3. contrast
    float luma = dot(rgb, kLuma);
    rgb = mix(vec3(luma), rgb, uSaturation);    // 4. saturation (luma from post-contrast)

    fragColor = vec4(clamp(rgb, 0.0, 1.0), 1.0);
}
```

**PBO double-buffering pattern:**
```
Frame N:   glReadPixels → PBO[0] (non-blocking, GPU-side DMA)
Frame N+1: map PBO[0] (data ready), glReadPixels → PBO[1]
Frame N+2: map PBO[1] (data ready), glReadPixels → PBO[0]
...
```

This avoids `glFinish()` — the map of the *previous* frame's PBO returns immediately because the GPU already finished writing it.

**Files to modify:**
- `CMakeLists.txt` — add `GpuRenderer.cpp`, link `GLESv3`, `EGL`

### Step 2: GL thread + SurfaceTexture (Kotlin)

Create a Kotlin class that manages the GL thread, SurfaceTexture, and drives the render loop.

**New file:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt`

**Responsibilities:**
- Create EGL context + EGL surface (for preview)
- Create OES texture + SurfaceTexture
- Expose `SurfaceTexture.surface` for Camera2 capture session
- On frame available: `updateTexImage()` → call native `nativeDrawAndReadback()`
- Receive adjustment parameters and forward to native `GpuRenderer`

**Key design:** Use a `HandlerThread` with a manually created EGL context (not `GLSurfaceView`). This gives full control over the render loop timing and avoids the `GLSurfaceView` lifecycle complexity with Flutter.

```kotlin
class GpuPipeline(
    private val width: Int,
    private val height: Int,
    private val previewSurface: Surface?,  // Flutter SurfaceProducer or null
    private val pipelineHandle: Long       // ImagePipeline native ptr
) {
    private val glThread = HandlerThread("GpuGL").apply { start() }
    private val glHandler = Handler(glThread.looper)
    private var nativeHandle: Long = 0
    private lateinit var surfaceTexture: SurfaceTexture
    val surface: Surface  // add to Camera2 capture session

    fun setAdjustments(brightness: Float, contrast: Float, saturation: Float)
    fun setCrop(scaleX: Float, scaleY: Float, offsetX: Float, offsetY: Float)
    fun release()
}
```

**Preview integration with Flutter:** Two options:
1. Render to Flutter's `SurfaceProducer` surface via EGL window surface — stays in Flutter's texture system
2. Use a PlatformView with a `SurfaceView` — native Android view overlaid

Option 1 is simpler for now — reuse the existing `SurfaceProducer` path. The GL thread creates an EGL window surface from Flutter's `Surface` and renders the FBO content to it.

### Step 3: JNI bridge for GPU renderer

**New JNI methods in `CameraBridge.cpp`:**

```cpp
// Initialize GpuRenderer, return native handle
JNIEXPORT jlong JNICALL
nativeGpuInit(JNIEnv*, jclass, jint width, jint height);

// Called per frame from GL thread after updateTexImage()
// Draws shader, does PBO readback, delivers to ImagePipeline
JNIEXPORT void JNICALL
nativeGpuDrawAndReadback(JNIEnv*, jclass,
    jlong gpuHandle, jlong pipelineHandle,
    jint oesTexture, jfloatArray texMatrix,
    jlong frameId, jint iso, jlong exposureNs, jlong sensorTimestamp);

// Update shader uniforms
JNIEXPORT void JNICALL
nativeGpuSetAdjustments(JNIEnv*, jclass,
    jlong gpuHandle, jfloat brightness, jfloat contrast, jfloat saturation);

// Cleanup
JNIEXPORT void JNICALL
nativeGpuRelease(JNIEnv*, jclass, jlong gpuHandle);
```

**`nativeGpuDrawAndReadback` implementation flow:**
```
1. renderer->draw(oesTexture, texMatrix)       // shader pass → FBO
2. renderer->renderToSurface()                 // FBO → preview EGL surface
3. const uint8_t* rgba = renderer->mapReadback(...)  // map previous frame's PBO
4. if (rgba) pipeline->deliverProcessedRgba(rgba, ...)
5. renderer->unmapReadback()
```

### Step 4: ISP configuration (Kotlin)

Two ISP-level operations: **manual white balance** (from user patch) and **sensor crop**.
Black balance is a GPU uniform (Step 1 shader) — no ISP involvement needed.

#### Manual white balance from a user-selected patch

User taps a region of the preview that should be neutral (gray card, white surface).
The pipeline samples that patch from the latest frame, computes per-channel WB gains,
and applies them via `COLOR_CORRECTION_GAINS` at Bayer level (before demosaicing —
more accurate than shader-based WB for color fringing at edges).

```kotlin
// Called when user selects a neutral patch (avgR, avgG, avgB from patch pixels)
fun setManualWhiteBalance(avgR: Float, avgG: Float, avgB: Float) {
    // Normalize so that green channel (reference) = 1.0
    val gainR = avgG / avgR
    val gainG = 1.0f
    val gainB = avgG / avgB

    // Disable AWB, apply our gains + latest AWB transform (preserve color matrix)
    captureRequestBuilder.set(CaptureRequest.COLOR_CORRECTION_MODE,
        CameraMetadata.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX)
    captureRequestBuilder.set(CaptureRequest.COLOR_CORRECTION_GAINS,
        RggbChannelVector(gainR, gainG, gainG, gainB))  // Gr = Gb = gainG
    latestAwbTransform?.let {
        captureRequestBuilder.set(CaptureRequest.COLOR_CORRECTION_TRANSFORM, it)
    }
    session.setRepeatingRequest(captureRequestBuilder.build(), captureCallback, handler)
}

fun resetToAutoWhiteBalance() {
    captureRequestBuilder.set(CaptureRequest.COLOR_CORRECTION_MODE,
        CameraMetadata.COLOR_CORRECTION_MODE_HIGH_QUALITY)
    session.setRepeatingRequest(captureRequestBuilder.build(), captureCallback, handler)
}
```

Cache the latest AWB color transform from `onCaptureCompleted` so it is available
when manual WB is set (prevents color matrix from going to identity):
```kotlin
// In CaptureCallback.onCaptureCompleted:
latestAwbTransform = result.get(CaptureResult.COLOR_CORRECTION_TRANSFORM)
```

#### Sensor crop

`SCALER_CROP_REGION` takes a `Rect` in active sensor array coordinates.
Full sensor size is available from `CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE`.

```kotlin
fun setSensorCrop(rect: Rect) {
    captureRequestBuilder.set(CaptureRequest.SCALER_CROP_REGION, rect)
    session.setRepeatingRequest(captureRequestBuilder.build(), captureCallback, handler)
}
```

For digital zoom or region-of-interest crop, compute the Rect relative to the
full sensor active array. This operates independently of the GPU UV remap.

### Step 5: `deliverProcessedRgba()` on ImagePipeline

New entry point that accepts RGBA from PBO readback.

**In `ImagePipeline.h`:**
```cpp
void deliverProcessedRgba(const uint8_t* rgba, int width, int height,
                          int stride, uint64_t frameId,
                          const FrameMetadata& meta);
```

**In `ImagePipeline.cpp`:**
- Implement: create `SharedFrame` with RGBA data, call `publishToConsumers()`
- Remove `__preview` built-in consumer (GPU handles preview directly)
- `processingLoop` and `InputRing` become dormant (remove in cleanup step)

### Step 6: Metadata pairing

**In `CameraController.kt`:**
- `onCaptureCompleted` stores `TotalCaptureResult` in a timestamp-keyed ring map (capacity ~8)
- `GpuPipeline` reads `SurfaceTexture.getTimestamp()` after `updateTexImage()`
- Looks up metadata by timestamp, passes to `nativeGpuDrawAndReadback()`

### Step 7: Wire to CameraController

**Modify `CameraController.kt`:**
1. Create `GpuPipeline` instead of (or alongside) `ImageReader` for streaming
2. Add `GpuPipeline.surface` to Camera2 capture session targets (replace `ImageReader.surface`)
3. Keep `ImageReader` for JPEG still capture only
4. Route `setProcessingParams()`:
   - Brightness/contrast/saturation/black balance → `gpuPipeline.setAdjustments()` (GPU uniforms, instant)
   - White balance patch → `setManualWhiteBalance()` (ISP, CaptureRequest, 2-3 frames)
   - Sensor crop → `setSensorCrop()` (ISP, CaptureRequest, 2-3 frames)
5. Remove `nativeDeliverYuv()` call from `onImageAvailable`

### Step 8: Cleanup dead CPU path

Once GPU pipeline is working end-to-end:
- Remove `InputRing` class and files
- Remove `processingLoop()`, `applySaturation()`, `deliverYuv()` from `ImagePipeline`
- Remove `nativeDeliverYuv` JNI method
- Remove streaming `ImageReader` (keep JPEG)
- Remove `ANativeWindow` preview blit (`blitToWindow`, `previewWindow_`, `rawPreviewWindow_`)
- Remove raw preview consumer
- Remove OpenCV dependency if no longer needed by any consumer

---

## Critical Files

| File | Change |
|------|--------|
| `src/main/cpp/src/GpuRenderer.h` | **New** — GL renderer class |
| `src/main/cpp/src/GpuRenderer.cpp` | **New** — EGL, shader, FBO, PBO implementation |
| `src/main/cpp/src/CameraBridge.cpp` | Add GPU JNI methods |
| `src/main/cpp/src/ImagePipeline.h` | Add `deliverProcessedRgba()` |
| `src/main/cpp/src/ImagePipeline.cpp` | Implement new entry point, disable CPU path |
| `src/main/cpp/CMakeLists.txt` | Add `GpuRenderer.cpp`, link `GLESv3`, `EGL` |
| `src/main/kotlin/.../GpuPipeline.kt` | **New** — GL thread, SurfaceTexture, render loop |
| `src/main/kotlin/.../CameraController.kt` | ISP params, swap ImageReader for SurfaceTexture, metadata pairing |
| `android/build.gradle.kts` | No new dependencies needed (GLES/EGL are Android system libs) |

### Reference files (read-only, for PBO/EGL patterns)
| File | What to reference |
|------|-------------------|
| `tmp_files/android-gpuimage-plus/library/src/main/jni/cge/common/cgeImageHandler.cpp:257-289` | PBO `mapOutputBuffer`/`unmapOutputBuffer` |
| `tmp_files/android-gpuimage-plus/library/src/main/jni/interface/cgeFrameRenderer.cpp` | OES→FBO blit, EGL setup |
| `tmp_files/android-gpuimage-plus/library/src/main/jni/cge/common/cgeSharedGLContext.cpp` | EGL context creation |

---

## Verification

1. **Build:** Project compiles with `GLESv3` + `EGL` linked, no new library dependencies
2. **Preview:** Camera preview displays through GL pipeline with vendor tone mapping intact (image should look identical to stock camera app baseline)
3. **Brightness slider:** Drag brightness slider — preview responds on next frame, no perceptible lag
4. **Contrast slider:** Same instant response
5. **Saturation slider:** Same instant response
6. **Black balance:** Set per-channel additive lift — preview responds on next frame (GPU uniform, instant)
7. **Manual white balance:** Select neutral patch — gains applied via `COLOR_CORRECTION_GAINS`, takes effect after 2-3 frames; AWB correctly disabled
8. **Consumer readback:** Register test sink via `addSink()`, log frame dimensions/format — confirm RGBA frames arrive at camera framerate
9. **Metadata:** Test sink logs ISO/exposure/timestamp — values match Camera2 capture results
10. **Performance:** `adb logcat` perf logs show total frame time (shader + PBO readback + consumer dispatch) well under 100ms at 4K
11. **AWB preservation:** Point camera at different color temperature lights — white balance adjusts automatically despite black balance gains being set
