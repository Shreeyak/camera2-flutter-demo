# android-gpuimage-plus — Codebase Checkpoint

> Paste this block into a conversation to restore full context about the android-gpuimage-plus library.
> Source: `tmp_files/android-gpuimage-plus/` (cloned for evaluation, not a project dependency)

---

## Purpose & Verdict

Evaluated as a candidate GPU image processing library for a real-time 4K camera pipeline.
**Decision: NOT using as a dependency.** Useful as reference for OES texture handling, PBO readback, and shared EGL contexts.

Key disqualifier: filters are chained as sequential FBO-bounced draw calls (one per filter), not fused into a single shader pass. Our pipeline requires a single-pass fragment shader doing YUV→RGBA + crop + rotation + black balance + brightness + contrast + saturation.

---

## Architecture Overview

```
Java layer (org.wysaid.*)
  ├── view/           — GLSurfaceView subclasses for camera preview
  ├── nativePort/     — JNI bridge classes (CGENativeLibrary, CGEFrameRecorder)
  └── texUtils/       — TextureDrawer variants (OES, NV21, I420, etc.)

Native C++ layer (library/src/main/jni/)
  ├── interface/      — JNI entry points, CGEFrameRenderer
  └── cge/
      ├── common/     — Core: image handler, shader functions, GL utils
      ├── filters/    — Individual filter implementations
      └── extends/    — Extended filters, blend modes
```

- ~375 C++ source files
- CMake build system (`library/src/main/jni/CMakeLists.txt`)
- GLES 2.0 base, conditional GLES 3.x via `_CGE_USE_ES_API_3_0_` compile flag
- Optional FFmpeg video module via `CGE_USE_VIDEO_MODULE` flag

---

## Key Files

### Camera Integration
| File | Role |
|------|------|
| `library/src/main/java/org/wysaid/view/CameraGLSurfaceViewWithTexture.java` | Camera2 → SurfaceTexture → OES texture. `updateTexImage()` on GL thread, passes texture ID + transform matrix to native renderer |
| `library/src/main/java/org/wysaid/texUtils/TextureDrawer4ExtOES.java` | Draws from `GL_TEXTURE_EXTERNAL_OES` using `samplerExternalOES` |

### Native Rendering Pipeline
| File | Role |
|------|------|
| `library/src/main/jni/interface/cgeFrameRenderer.cpp` | Main render loop: `update(externalTex, matrix)` → blit OES to FBO; `runProc()` → apply filters; `render()` → draw result to screen |
| `library/src/main/jni/cge/common/cgeImageHandler.h/.cpp` | Frame handler: owns FBO pair, manages filter chain, provides PBO readback (`mapOutputBuffer`/`unmapOutputBuffer`) |
| `library/src/main/jni/cge/common/cgeImageFilter.h` | Base filter interface: `render2Texture(handler, srcTex, vertexBuf)` |
| `library/src/main/jni/cge/common/cgeShaderFunctions.h` | Shader string constants, program compilation utilities |
| `library/src/main/jni/cge/common/cgeGLFunctions.h/.cpp` | GL utility wrappers, texture creation, FBO setup |

### PBO Async Readback (GLES 3.0+ only)
| File | Lines | Details |
|------|-------|---------|
| `library/src/main/jni/cge/common/cgeImageHandler.h` | 150-156 | `mapOutputBuffer(CGEBufferFormat)` / `unmapOutputBuffer()` API; `m_pixelPackBuffer` member |
| `library/src/main/jni/cge/common/cgeImageHandler.cpp` | 220-330 | Implementation: `GL_PIXEL_PACK_BUFFER` + `glMapBufferRange(GL_MAP_READ_BIT)` for non-blocking reads |

### Shared EGL Context
| File | Role |
|------|------|
| `library/src/main/jni/cge/common/cgeSharedGLContext.h/.cpp` | Creates shared EGL contexts for off-screen rendering. Supports `PBUFFER` and `RECORDABLE_ANDROID` surface types |

### Filter System
| File | Role |
|------|------|
| `library/src/main/jni/cge/filters/cgeFilterBasic.h/.cpp` | Brightness, contrast, saturation, etc. — each a separate shader program |
| `library/src/main/jni/cge/filters/cgeHSLFilter.h/.cpp` | HSL adjustment filter |
| `library/src/main/jni/cge/filters/cgeCurveFilter.h/.cpp` | Curve (tone mapping) filter |

### Build
| File | Role |
|------|------|
| `library/src/main/jni/CMakeLists.txt` | Native build config. Flags: `_CGE_USE_ES_API_3_0_`, `CGE_USE_VIDEO_MODULE` |

### Sample App
| File | Role |
|------|------|
| `cgeDemo/src/main/java/.../CameraDemoActivity.java` | Live camera + filter demo |

---

## Render Loop Detail

```
Per frame on GL thread:
1. mSurfaceTexture.updateTexImage()          // latch latest camera frame
2. renderer.update(oesTextureId, matrix)     // blit OES → internal FBO (one draw call)
3. renderer.runProc()                        // apply filter chain:
   │  for each filter:
   │    swapBufferFBO()
   │    filter.render2Texture(src)           // one draw call per filter
   │    glFlush()
   │  glFinish()                             // BLOCKS until all filters done
4. renderer.render(x, y, w, h)              // draw final FBO texture to screen
```

**Critical perf note:** `glFinish()` after filter chain is a full pipeline stall.

---

## Filter Chain Architecture

Filters are specified via rule strings parsed at runtime:
```
"@adjust brightness 0.5 @adjust contrast 1.2 @adjust saturation 1.5"
```

Each `@adjust` token creates a separate `CGEImageFilter` subclass with its own shader program.
`CGEFastFrameHandler::processingFilters()` iterates and renders each filter sequentially with FBO ping-pong.

**There is no mechanism to fuse multiple adjustments into a single shader pass.**

---

## What To Borrow (Reference Code)

1. **OES → FBO blit pattern** (`cgeFrameRenderer.cpp`):
   - How to sample `samplerExternalOES` with a transform matrix and render to an FBO
   - This is exactly the first stage of our pipeline

2. **PBO double-buffer readback** (`cgeImageHandler.cpp:220-330`):
   - Working `glMapBufferRange` / `GL_PIXEL_PACK_BUFFER` code
   - Pattern for non-blocking GPU→CPU transfer

3. **Shared EGL context creation** (`cgeSharedGLContext`):
   - Creating additional GL contexts that share textures/FBOs with the main context
   - Useful if we need encoder or off-screen processing on a separate thread

4. **Shader math for color adjustments** (from filter implementations):
   - Saturation: `mix(grey, color.rgb, saturation)` where `grey = dot(color.rgb, vec3(0.2125, 0.7154, 0.0721))`
   - Brightness: `color.rgb + vec3(brightness)`
   - Contrast: `(color.rgb - 0.5) * contrast + 0.5`
   - HSL: full HSL↔RGB conversion in shader

---

## Comparison: android-gpuimage vs android-gpuimage-plus vs Our Pipeline

| Feature | android-gpuimage (CyberAgent) | android-gpuimage-plus | Our target pipeline |
|---------|-------------------------------|----------------------|-------------------|
| Camera input | CPU YUV→RGB, upload as GL_TEXTURE_2D | Zero-copy SurfaceTexture → OES | Zero-copy SurfaceTexture → OES |
| GLES version | 2.0 only | 2.0 + conditional 3.x | 3.x required |
| PBO readback | No (glReadPixels only) | Yes (double-buffered) | Yes (double-buffered) |
| Filter execution | N draw calls (Java) | N draw calls (C++) | 1 fused draw call |
| Ring buffer | No | No | Yes (ref-counted slots) |
| Multi-output fan-out | No | No | Yes (preview + N CPU sinks) |
| Language | Java | C++ with JNI | C++ with JNI |
| Compute shaders | No | No | Possible future use |
