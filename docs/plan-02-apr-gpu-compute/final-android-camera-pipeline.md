# Android Camera Pipeline: Final Architecture

## Context

After evaluating android-gpuimage-plus, Vulkan compute, `flutter_image_filters`, and Flutter's built-in ColorFilter:

**`flutter_image_filters` verdict — dropped.** Static images only. No support for camera streams (YUV_420_888, SurfaceTexture, ImageReader). Active stability bugs on Flutter 3.32+. Cannot replace any part of our pipeline.

**Vulkan compute verdict — dropped for Android.** At 6 GB/s effective CPU bandwidth on the target Snapdragon device, the mandatory libyuv YUV→RGBA CPU copy costs ~8 ms/frame before the GPU even sees data. OES texture (GL only) avoids this entirely. Vulkan compute is kept only as the desktop C++ prototype (`scripts/color_transform_lab_vk/`).

**Final decision: unified single GL pass for everything.**
- One OES fragment shader processes each camera frame
- FBO output goes to both preview (via EGL window surface) and consumers (via async PBO readback)
- Same processed pixels seen by preview and all consumer sinks — guaranteed consistency

---

## Architecture

```
Camera2 ISP (Level 3, API 36):
  COLOR_CORRECTION_GAINS   → manual white balance (Bayer-level, user patch)
  SCALER_CROP_REGION       → sensor crop
  TONEMAP_MODE_HIGH_QUALITY → vendor S-curve preserved
  │
  ▼ SurfaceTexture (zero-copy, no CPU cost)
GL_TEXTURE_EXTERNAL_OES
  │
  ▼ single-pass OES fragment shader
GpuRenderer::draw() → FBO (RGBA8, 4K)
  │                          │
  ▼                          ▼
GpuRenderer::             async PBO readback (double-buffered)
renderToSurface()         GpuRenderer::mapReadback()
  │                          │
Flutter SurfaceProducer   pipeline->deliverProcessedRgba()
(preview)                   ├── stitcher sink
                            └── tracker sink
```

### Latency

| Parameter | Latency | Path |
|---|---|---|
| Brightness / contrast / saturation / black balance | Next frame | OES shader uniform update |
| White balance (manual patch) | 2–3 frames | ISP `COLOR_CORRECTION_GAINS` (Bayer-level) |
| Sensor crop | 2–3 frames | ISP `SCALER_CROP_REGION` |

---

## OES Fragment Shader

Single pass: contrast → brightness → saturation (BT.709 luma-mix) → black balance.

```glsl
#version 300 es
#extension GL_OES_EGL_image_external : require
precision mediump float;

uniform samplerExternalOES uTexture;
uniform mat4  uTexMatrix;
uniform float uBrightness;
uniform float uContrast;
uniform float uSaturation;
uniform vec3  uBlackBalance;
in  vec2 vTexCoord;
out vec4 fragColor;

void main() {
    vec3 c = texture(uTexture, (uTexMatrix * vec4(vTexCoord, 0.0, 1.0)).xy).rgb;
    c = (c - 0.5) * uContrast + 0.5;
    c += uBrightness;
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    c = mix(vec3(luma), c, uSaturation);
    c += uBlackBalance;
    fragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
}
```

PBO double-buffering: frame N issues `glReadPixels` → PBO[0]; frame N+1 maps PBO[0] (GPU already done), issues → PBO[1]. No `glFinish` stall.

---

## Critical Files

| File | Change |
|---|---|
| `src/main/cpp/src/GpuRenderer.h/cpp` | **New** — OES shader, FBO, double-buffered PBO, `renderToSurface()` |
| `src/main/cpp/src/CameraBridge.cpp` | Add `nativeGpuInit`, `nativeGpuDrawAndReadback`, `nativeGpuSetAdjustments` |
| `src/main/cpp/src/ImagePipeline.h/cpp` | Add `deliverProcessedRgba()`, remove CPU processing loop |
| `src/main/cpp/CMakeLists.txt` | Add `GpuRenderer.cpp`, link `GLESv3`, `EGL` |
| `src/main/kotlin/.../GpuPipeline.kt` | **New** — HandlerThread GL loop, SurfaceTexture, `updateTexImage()` |
| `src/main/kotlin/.../CameraController.kt` | ISP params (WB, crop), swap ImageReader for SurfaceTexture surface |
| `lib/camera_controls.dart` (Flutter) | Sliders call JNI → `nativeGpuSetAdjustments()` → uniforms updated on next frame |

**Full step-by-step implementation:** `docs/plan-02-apr-gpu-compute/hybrid-gpu-pipeline-plan.md` (Steps 1–8 unchanged, this document supersedes the architecture decisions only).

---

## Verification

1. **Unified output:** Drag slider → same processed frame appears in preview AND delivered to test sink with identical pixel values
2. **Consumer throughput:** Test sink receives RGBA frames at camera framerate with correct metadata
3. **PBO readback:** No `glFinish` in logcat; frame delivery latency < 16ms at 4K
4. **White balance:** Tap neutral patch → `COLOR_CORRECTION_GAINS` applied, colors shift after 2–3 frames; AWB correctly disabled
5. **GLES validation:** Debug callback enabled; no GL errors during normal operation
6. **Memory:** No per-frame Bitmap allocations; native heap flat after warmup
