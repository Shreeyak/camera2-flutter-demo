# Vulkan + Kompute Pipeline: ISP + Compute Shader

## Context

Alternative to the OpenGL pipeline plan. Same ISP strategy (white balance, sensor crop) but replaces the GLES fragment shader + SurfaceTexture path with a Vulkan compute shader managed via Kompute.

**Why Vulkan/Kompute instead of GLES:**
- Compute shaders are semantically cleaner for image processing — no vertex buffers, quads, or rasterization state
- Explicit memory management: CPU↔GPU transfers are explicit, no hidden driver copies
- Better async primitives: Kompute sequences can overlap GPU work with CPU prep
- Future headroom: ML inference (via Vulkan compute) can run on the same Vulkan instance with shared memory
- No OES texture magic — data flow is transparent buffers

**Trade-off vs GLES:** The OES texture zero-copy path from `SurfaceTexture` does not exist in Vulkan. We must copy YUV data from `ImageReader` into a Kompute tensor. This costs ~1ms on a modern SoC for 4K YUV (libyuv SIMD). Preview display also requires a CPU readback → Bitmap blit (adds another ~1ms). Total added latency vs GL is ~2ms, well within the 100ms budget.

> **OES color space note (same as GL plan):** The Camera2 ISP outputs YCbCr BT.709. The GLES OES path converts automatically; here we do the conversion in the compute shader or via libyuv before upload. Saturation luma weights must be BT.709 `(0.2126, 0.7152, 0.0722)`.

---

## Architecture

```
Camera2 ISP (Level 3, API 36):
  COLOR_CORRECTION_GAINS       → manual white balance (Bayer-level, user patch)
  SCALER_CROP_REGION           → sensor crop rectangle
  TONEMAP_MODE_HIGH_QUALITY    → vendor S-curve preserved
  AWB (default: enabled)
  │
  ▼ ImageReader (YUV_420_888)
CPU: libyuv YUV420→RGBA (SIMD, ~1ms at 4K)
  │
  ▼ kp::OpSyncDevice
Kompute GPU Tensor (RGBA float32, flat)
  │
  ▼ kp::OpAlgoDispatch (compute shader)
Compute Shader (GLSL #version 450):
  - contrast   (midpoint pivot)
  - brightness (additive)
  - saturation (BT.709 luma-mix)
  - black balance (per-channel additive lift)
  │
  ▼ kp::OpSyncLocal (~1ms)
Output RGBA buffer (CPU-side)
  │                        │
  ▼                        ▼
Bitmap → SurfaceView    SharedFrame → publishToConsumers()
(preview, ~1ms blit)      ├── stitcher sink
                          ├── tracker sink
                          └── other sinks
```

### Latency characteristics

| Parameter | Update latency | Where |
|-----------|---------------|-------|
| Brightness | Instant (next frame) | Kompute push constant |
| Contrast | Instant (next frame) | Kompute push constant |
| Saturation | Instant (next frame) | Kompute push constant |
| Black balance | Instant (next frame) | Kompute push constant |
| Crop (sensor region) | 2-3 frames | ISP via `SCALER_CROP_REGION` |
| White balance (manual patch) | 2-3 frames | ISP via `COLOR_CORRECTION_GAINS` |

---

## Compute Shader

```glsl
#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// Flat RGBA float32 buffers. Pixel i → [4i, 4i+1, 4i+2, 4i+3]
layout(set = 0, binding = 0) buffer InputBuf  { float data[]; } inBuf;
layout(set = 0, binding = 1) buffer OutputBuf { float data[]; } outBuf;

layout(push_constant) uniform Params {
    float brightness;    // [-1, 1],   0.0 = identity
    float contrast;      // [0.5, 2],  1.0 = identity
    float saturation;    // [0, 2],    1.0 = identity
    float blackR;        // [0, 0.2],  0.0 = identity (additive lift)
    float blackG;
    float blackB;
    uint  numPixels;     // width * height
} p;

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= p.numPixels) return;

    uint base = idx * 4u;
    vec3 c = vec3(inBuf.data[base], inBuf.data[base + 1u], inBuf.data[base + 2u]);

    c = (c - 0.5) * p.contrast + 0.5;                   // contrast
    c += p.brightness;                                    // brightness
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));   // BT.709
    c = mix(vec3(luma), c, p.saturation);                // saturation
    c += vec3(p.blackR, p.blackG, p.blackB);             // black balance

    c = clamp(c, 0.0, 1.0);
    outBuf.data[base]      = c.r;
    outBuf.data[base + 1u] = c.g;
    outBuf.data[base + 2u] = c.b;
    outBuf.data[base + 3u] = inBuf.data[base + 3u];     // alpha passthrough
}
```

---

## Implementation Steps

### Step 1: Kompute integration in CMake/NDK

Add Kompute via CMake `FetchContent`. Kompute works with Android NDK 25+ which includes Vulkan headers.

**In `CMakeLists.txt`:**
```cmake
include(FetchContent)
FetchContent_Declare(
    kompute
    GIT_REPOSITORY https://github.com/KomputeProject/kompute.git
    GIT_TAG        v0.9.0
)
set(KOMPUTE_OPT_LOG_LEVEL_DISABLED ON)
set(KOMPUTE_OPT_DISABLE_VULKAN_VERSION_CHECK ON)  # needed for Android
FetchContent_MakeAvailable(kompute)

# Existing target:
target_link_libraries(cambrian_camera PRIVATE kompute)
```

**SPIR-V at build time:** The shader must be compiled to SPIR-V before running on Android (no `glslc` at runtime). Add a custom CMake command:
```cmake
find_program(GLSLC glslc HINTS $ENV{VULKAN_SDK}/bin)
add_custom_command(
    OUTPUT  ${CMAKE_CURRENT_BINARY_DIR}/color_transform.spv
    COMMAND ${GLSLC} -fshader-stage=compute
            ${CMAKE_CURRENT_SOURCE_DIR}/src/color_transform.comp
            -o ${CMAKE_CURRENT_BINARY_DIR}/color_transform.spv
    DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/src/color_transform.comp
)
add_custom_target(shaders DEPENDS ${CMAKE_CURRENT_BINARY_DIR}/color_transform.spv)
add_dependencies(cambrian_camera shaders)
```

Then embed SPIR-V via `incbin` or load it as an asset.

### Step 2: `KomputeProcessor` C++ class

**New file:** `src/main/cpp/src/KomputeProcessor.h`
**New file:** `src/main/cpp/src/KomputeProcessor.cpp`

```cpp
#include <kompute/Kompute.hpp>

struct ColorParams {
    float brightness = 0.f;
    float contrast   = 1.f;
    float saturation = 1.f;
    float blackR     = 0.f;
    float blackG     = 0.f;
    float blackB     = 0.f;
    uint32_t numPixels = 0;
};

class KomputeProcessor {
public:
    /// Initialize Kompute manager, upload SPIR-V, allocate tensors.
    /// spirvBytes: pre-compiled SPIR-V from CMake build step.
    bool init(int width, int height,
              const std::vector<uint32_t>& spirvBytes);

    /// Process one frame. rgbaIn: CPU-side RGBA float32, width*height*4 floats.
    /// Updates output tensor; call getOutput() afterwards.
    void process(const float* rgbaIn, const ColorParams& params);

    /// Returns pointer to output tensor CPU data (valid until next process() call).
    const float* getOutput() const;

    void release();

private:
    kp::Manager mgr_;
    std::shared_ptr<kp::Tensor> tensorIn_, tensorOut_;
    std::shared_ptr<kp::Algorithm> algo_;
    int width_ = 0, height_ = 0;
    std::vector<uint32_t> spirv_;
};
```

**`process()` implementation:**
```cpp
void KomputeProcessor::process(const float* rgbaIn, const ColorParams& params) {
    // Update input tensor data (memcpy to staging, then OpSyncDevice)
    auto* dst = tensorIn_->data<float>();
    std::memcpy(dst, rgbaIn, width_ * height_ * 4 * sizeof(float));

    std::vector<float> pushConsts = {
        params.brightness, params.contrast, params.saturation,
        params.blackR, params.blackG, params.blackB,
        static_cast<float>(params.numPixels)
    };

    kp::Workgroup wg = { static_cast<uint32_t>(std::ceil(width_ * height_ / 256.0)), 1, 1 };

    mgr_.sequence()
        ->record<kp::OpSyncDevice>({tensorIn_})
        ->record<kp::OpAlgoDispatch>(algo_, pushConsts)
        ->eval()
        ->record<kp::OpSyncLocal>({tensorOut_})
        ->eval();
}
```

### Step 3: JNI bridge

**In `CameraBridge.cpp`:**
```cpp
// Initialize KomputeProcessor, return native handle
JNIEXPORT jlong JNICALL
nativeKomputeInit(JNIEnv*, jclass, jint width, jint height,
                  jbyteArray spirvBytes);

// Process one RGBA frame, deliver to ImagePipeline + preview
JNIEXPORT void JNICALL
nativeKomputeProcess(JNIEnv*, jclass,
    jlong kpHandle, jlong pipelineHandle,
    jbyteArray rgbaData,
    jfloat brightness, jfloat contrast, jfloat saturation,
    jfloat blackR, jfloat blackG, jfloat blackB,
    jlong frameId, jint iso, jlong exposureNs, jlong sensorTimestamp);

// Release
JNIEXPORT void JNICALL
nativeKomputeRelease(JNIEnv*, jclass, jlong kpHandle);
```

**`nativeKomputeProcess` implementation flow:**
```
1. Get byte[] → float* (uint8 RGBA → float32 RGBA, divide by 255)
2. processor->process(rgbaFloats, params)          // compute shader on GPU
3. const float* out = processor->getOutput()       // CPU-side output
4. Convert float32 RGBA → uint8 RGBA               // for preview + consumers
5. pipeline->deliverProcessedRgba(uint8Out, ...)   // fan out to sinks
6. Update preview SurfaceView via deliverPreviewRgba(uint8Out, ...) 
```

### Step 4: YUV→RGBA on the input path (Kotlin + libyuv)

Camera2 delivers `YUV_420_888` via `ImageReader`. Convert to RGBA on CPU using libyuv (already available via NDK) before passing to Kompute.

**In `VulkanPipeline.kt`:**
```kotlin
imageReader.setOnImageAvailableListener({ reader ->
    val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
    // Extract Y, U, V planes → pass to native for libyuv conversion + Kompute dispatch
    val yPlane = image.planes[0].buffer
    val uPlane = image.planes[1].buffer
    val vPlane = image.planes[2].buffer
    nativeKomputeProcessYuv(
        kpHandle, pipelineHandle,
        yPlane, uPlane, vPlane,
        image.width, image.height,
        /* ... params ... */,
        metaRingMap[image.timestamp] ?: return@setOnImageAvailableListener
    )
    image.close()
}, handler)
```

**libyuv conversion in JNI:**
```cpp
// NV12/I420 → RGBA (libyuv, SIMD-accelerated)
libyuv::I420ToABGR(
    yData, yStride,
    uData, uStride,
    vData, vStride,
    rgbaOut, width * 4,
    width, height);
// Then: uint8 RGBA → float32 (divide by 255.f) → processor->process()
```

### Step 5: Preview display (Bitmap → SurfaceView)

After Kompute outputs RGBA, blit to preview via Android `Canvas`:

**In `VulkanPipeline.kt`:**
```kotlin
fun deliverPreview(rgbaBytes: ByteArray, width: Int, height: Int) {
    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
    bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgbaBytes))
    val canvas = previewSurface?.lockCanvas(null) ?: return
    canvas.drawBitmap(bitmap, 0f, 0f, null)
    previewSurface.unlockCanvasAndPost(canvas)
    bitmap.recycle()
}
```

**Alternative (zero-copy preview):** Use `AHardwareBuffer` → `SurfaceView`. Write Kompute output into an `AHardwareBuffer` mapped for CPU write, then queue it to the `SurfaceView`. This eliminates the Bitmap allocation but requires API 26+.

### Step 6: ISP configuration (Kotlin)

Identical to the GL plan — see `docs/hybrid-gpu-pipeline-plan.md` Step 4.
- Manual white balance: `COLOR_CORRECTION_GAINS` (Bayer-level, from user neutral patch)
- Sensor crop: `SCALER_CROP_REGION`
- Cache `COLOR_CORRECTION_TRANSFORM` from `onCaptureCompleted` for AWB preservation

### Step 7: `deliverProcessedRgba()` on ImagePipeline

Same as GL plan Step 5 — new entry point accepting RGBA from Kompute output.

### Step 8: Wire to CameraController

**Modify `CameraController.kt`:**
1. Create `VulkanPipeline` (wraps `KomputeProcessor` JNI) + `ImageReader(YUV_420_888)`
2. Add `ImageReader.surface` to Camera2 session (replaces current ImageReader)
3. Keep separate `ImageReader` for JPEG still capture
4. Route slider params → `nativeKomputeSetParams()` (applied as push constants on next dispatch)
5. Remove old `nativeDeliverYuv()` flow

### Step 9: Cleanup dead CPU path

Same as GL plan Step 8:
- Remove `InputRing`, `processingLoop`, `applySaturation`, `deliverYuv`
- Remove OpenCV YUV→BGR conversion (replaced by libyuv I420→RGBA)
- Remove `ANativeWindow` preview blit
- Keep OpenCV only if downstream consumers require it

---

## Critical Files

| File | Change |
|------|--------|
| `src/main/cpp/src/color_transform.comp` | **New** — GLSL compute shader |
| `src/main/cpp/src/KomputeProcessor.h` | **New** — Kompute wrapper class |
| `src/main/cpp/src/KomputeProcessor.cpp` | **New** — process loop, tensor management |
| `src/main/cpp/src/CameraBridge.cpp` | Add Kompute JNI methods |
| `src/main/cpp/src/ImagePipeline.h` | Add `deliverProcessedRgba()` |
| `src/main/cpp/src/ImagePipeline.cpp` | Implement new entry point |
| `src/main/cpp/CMakeLists.txt` | FetchContent Kompute, add glslc build step |
| `src/main/kotlin/.../VulkanPipeline.kt` | **New** — ImageReader, YUV dispatch, preview blit |
| `src/main/kotlin/.../CameraController.kt` | ISP params, swap processing path |

### Reference (same as GL plan)
| File | What to reference |
|------|-------------------|
| `tmp_files/android-gpuimage-plus/library/src/main/jni/cge/common/cgeImageHandler.cpp:257-289` | GPU buffer readback pattern (analogous to PBO) |

---

## Comparison vs GL Plan

| Aspect | GL Plan | Vulkan/Kompute Plan |
|--------|---------|---------------------|
| Input path | SurfaceTexture OES (zero-copy) | ImageReader YUV + libyuv CPU convert |
| GPU processing | GLES fragment shader | Vulkan compute shader (Kompute) |
| Preview output | GPU renders direct to EGL surface | CPU blit: RGBA → Bitmap → SurfaceView |
| Preview added latency | 0ms (GPU-direct) | ~2ms (readback + Bitmap blit) |
| Setup complexity | Medium (EGL, SurfaceTexture, OES) | Medium (Kompute manager, libyuv) |
| Build dependency | Android system GLES (no extra dep) | Kompute (FetchContent, ~1MB SPIR-V runtime) |
| Async compute | No (sequential render) | Yes (sequence → eval_async) |
| ML inference on same context | No (GLES ≠ compute) | Yes (same Vulkan instance) |

**Choose GL plan** if: preview latency is critical, no ML compute planned.
**Choose Kompute plan** if: need async compute, ML integration, or explicit memory control.

---

## Verification

1. **Build:** `cmake` generates SPIR-V from `color_transform.comp`; project links Kompute without errors
2. **Vulkan device:** `adb logcat` shows Kompute selected a Vulkan device (not SwiftShader fallback)
3. **Preview:** Camera preview displays via Bitmap blit — image quality matches stock camera baseline
4. **Brightness/contrast/saturation/black balance sliders:** Respond on next frame (push constant update, no pipeline recreation)
5. **YUV conversion:** No green tint or chroma shift — libyuv I420→RGBA producing correct colors
6. **Consumer readback:** Test sink receives RGBA frames at camera framerate with correct metadata
7. **White balance:** Neutral patch → `COLOR_CORRECTION_GAINS` applied, AWB disabled, colors shift correctly
8. **Performance:** `adb logcat` shows: libyuv convert < 2ms, Kompute dispatch < 5ms, readback < 2ms, preview blit < 2ms — total well under 100ms at 4K
9. **Memory:** No tensor reallocations per frame — tensors allocated once in `init()`, reused each frame
