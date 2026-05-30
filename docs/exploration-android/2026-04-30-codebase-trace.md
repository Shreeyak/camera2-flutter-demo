# Codebase Trace — Synthesis (cambrian_camera)

**Date:** 2026-04-30
**Inputs:** Three parallel haiku subagent reports (`docs/exploration/2026-04-30-subagent-{1,2,3}-*.md`)
**Source of truth:** Live source under `lib/`, `packages/cambrian_camera/{lib,pigeons,android}/`. Subagents were forbidden from reading anything under `docs/`. The "Drift from docs" section below is the only place where existing project documentation (`docs/architecture.md`, `docs/usage-guide.md`) was consulted, and only by the synthesis pass.

This document is the consolidated reference. The three subagent reports are the deep dives — read them when you need full prose context, citations, and goal-specific detail.

---

## Reading map

| Question | Where to look |
|---|---|
| How does a frame travel from the camera sensor to a C++ sink? | [Subagent 1 §"Shared infrastructure"](2026-04-30-subagent-1-frame-flow-and-endpoints.md) |
| Where is the data structure / lock / thread for endpoint X? | [Subagent 1 §"Per-endpoint deep dives"](2026-04-30-subagent-1-frame-flow-and-endpoints.md) |
| How does a slider tap reach the GPU shader? | [Subagent 2 §"Outbound (Dart → hardware)"](2026-04-30-subagent-2-settings-flow.md) |
| How does the hardware-reported ISO get back to the UI? | [Subagent 2 §"Inbound (hardware → Dart)"](2026-04-30-subagent-2-settings-flow.md) |
| What state-management pattern does the demo app use? | [Subagent 3 §"State management"](2026-04-30-subagent-3-app-architecture.md) |
| Where is `CambrianCamera.open` called and what subscribes to its streams? | [Subagent 3 §"Plugin integration points"](2026-04-30-subagent-3-app-architecture.md) |

---

## How the three goals interlock

The three subagent reports describe three projections of the same machine:

```
Frame data flow (Subagent 1)              Settings flow (Subagent 2)
   │                                          │
   │  GL thread reads uniforms                │  Dart thread writes uniforms
   │  every frame to apply                    │  (latest-value-wins serializer
   │  brightness/contrast/saturation/         │   for ISP; fire-and-forget for
   │  black/gamma to each pixel               │   ProcessingParams)
   │                                          │
   ▼                                          ▼
        ┌──────────────────────────────┐
        │   GpuRenderer::uniformMu_    │  ← the lock that bridges
        │   GL uniforms (5 floats +    │     the two flows
        │     blackBalance_[3])        │
        └──────────────────────────────┘
                       │
                       │  Same uniforms also drive
                       │  setCropOutput → uCropScale/uCropOffset,
                       │  reaching every endpoint.
                       ▼
                  Per-endpoint fan-out
                  (Subagent 1)

Demo app (Subagent 3)
   │
   │  StatefulWidget owns _camera, calls updateSettings/setProcessingParams,
   │  subscribes to toneMappedTexture / frameResultStream / errorStream /
   │  recordingStateStream.
   │  Triggers every flow in Subagent 1 and Subagent 2.
   ▼
The "edge of the world" — every other piece of code is plugin-internal.
```

The lock that makes the whole thing safe is small: **one mutex (`uniformMu_`)** for shader uniforms, **one atomic exchange flag (`captureRequested_`)** for the still-capture rendezvous, **per-consumer condvar mailboxes** for sink dispatch, **per-PBO `GLsync` fences** for GPU→CPU DMA. The complexity is in the choreography, not in the primitive count.

---

## Subagent disagreements resolved

**None.** The three reports do not contradict each other on any concrete fact. Where they overlap (e.g. both Subagent 1 and Subagent 2 describe `setProcessingParams` reaching the C++ side), they cite the same files and lines and tell consistent stories. The synthesis records this as a positive finding — the doc-blind, code-only methodology produced internally consistent results across three independent agents.

---

## Citation verification (sample)

The following 7 citations were spot-checked by reading the cited file at the cited line. **All 7 resolve correctly:**

| Citation | Claim | Verified |
|---|---|---|
| `lib/main.dart:62` | `class CameraApp extends StatelessWidget` | ✓ |
| `packages/cambrian_camera/lib/src/camera_settings_serializer.dart:11` | `class CameraSettingsSerializer` | ✓ |
| `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:43` | `private val glThread = HandlerThread("GpuPipeline-GL")` | ✓ |
| `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1019` | `fun updateSettings(incoming: CamSettings)` | ✓ |
| `packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:80` | `memcpy(frame->data.data(), rgba, size)` (the 1 unavoidable copy) | ✓ |
| `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:484` | Y-flip mirror blit (`glBlitFramebuffer` with inverted dst-Y) | ✓ |
| `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:698` | `std::lock_guard<std::mutex> lk(uniformMu_)` | ✓ |

7/7 = 100% verified. Subagent citations are reliable.

---

## Drift from docs

Drift items below quote `docs/architecture.md` verbatim and cite the conflicting code line found by the subagents.

### Drift 1 — "256-entry LUT" claim is stale

> *Quote (docs/architecture.md, "Key invariants" bullet 6):*
> "**LUT rebuilt atomically.** When `ProcessingParams` change, the 256-entry LUT is rebuilt and swapped; no partial updates visible to the frame loop."

**Code reality:** No LUT exists. `ProcessingParams` updates write direct GL uniforms under `GpuRenderer::uniformMu_`:

- `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:695` — `void GpuRenderer::setAdjustments(...)`
- `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:698` — `std::lock_guard<std::mutex> lk(uniformMu_);`
- `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:699-705` — assigns `brightness_`, `contrast_`, `saturation_`, `blackBalance_[3]`, `gamma_` directly.

The 256-entry arrays at `GpuRenderer.cpp:1290-1306` are per-channel histogram bins for the `sampleCenterPatch` trimmed-mean computation, not a per-pixel processing LUT. The actual atomic-update guarantee comes from the mutex; uniforms are written within `uniformMu_` and read by the GL thread the same way each frame.

**Recommended fix to `docs/architecture.md`:** Replace the LUT bullet with: "Shader uniforms are mutex-protected. `ProcessingParams` updates lock `GpuRenderer::uniformMu_` and write the five (plus `blackBalance_[3]`) GL uniform fields atomically; the GL thread reads them under the same lock before each draw."

---

### Drift 2 — Subagent coverage gap (NOT drift): `rotAndFlipMatrix`

`docs/architecture.md` describes a fixed 90° rotation + vertical flip applied as a UV swap in the shader:

> "where `texMatrix` is `SurfaceTexture.getTransformMatrix()` (HAL orientation correction…) and `rotAndFlipMatrix` is the constant UV swap `(u, v) → (v, u)` — algebraically equivalent to a 90° image rotation followed by a vertical flip (`v → 1 − v`). The composed matrix is uploaded as `uTexMatrix` on every frame."

**This is accurate.** Verified at `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:77` (declaration) and `:416` (`Matrix.multiplyMM(combinedMatrix, 0, texMatrix, 0, rotAndFlipMatrix, 0)`).

Subagent 1's report describes only the *Y-flip mirror FBO* mechanism (a separate concern that fixes the GL bottom-up vs JPEG top-down row-order mismatch on the readback path); it does not document the shader-level UV-swap rotation. This is a **coverage gap** in Subagent 1, not drift in the doc. Future readers should consult `docs/architecture.md` §"Fixed output transform" for the rotAndFlipMatrix story.

---

### Drift 3 — `params_mutex_` is named `uniformMu_`

Note: the plan that drove this exercise referenced a `params_mutex_` as a candidate name. The actual code-derived name is `uniformMu_`. `docs/architecture.md` does not name the mutex explicitly, so this isn't doc drift — but if any internal note uses `params_mutex_`, replace with `uniformMu_`. Cite: `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:251` (declaration).

---

## Consolidated Diagram inputs

The structured data below is the **rendering-ready merge** of the three subagent appendices (deduplicated by `id`, with cross-goal symbols listed once). Feed any sub-section of this directly to the Excalidraw MCP. The recommended top-tier diagrams are listed in §"Recommended diagrams" at the bottom of this document.

### Symbols (merged)

```yaml
# === Layer L1: Dart public API ===
- id: cambrian-camera
  kind: class
  label: CambrianCamera (plugin facade)
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:1

- id: update-settings-dart
  kind: function
  label: CambrianCamera.updateSettings
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:312

- id: set-processing-params-dart
  kind: function
  label: CambrianCamera.setProcessingParams
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:348

- id: sample-center-patch-dart
  kind: function
  label: CambrianCamera.sampleCenterPatch
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:384

- id: calibrate-wb
  kind: function
  label: CambrianCamera.calibrateWhiteBalance
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:404

- id: calibrate-bb
  kind: function
  label: CambrianCamera.calibrateBlackBalance
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:449

- id: serializer
  kind: class
  label: CameraSettingsSerializer (latest-value-wins)
  cite: packages/cambrian_camera/lib/src/camera_settings_serializer.dart:11

- id: serializer-pending
  kind: mailbox
  label: serializer._pending + _inFlight
  cite: packages/cambrian_camera/lib/src/camera_settings_serializer.dart:17

- id: frame-result-stream
  kind: stream
  label: camera.frameResultStream
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:293

- id: tone-mapped-texture-stream
  kind: stream
  label: camera.toneMappedTexture
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:1

- id: error-stream
  kind: stream
  label: camera.errorStream
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:1

- id: recording-state-stream
  kind: stream
  label: camera.recordingStateStream
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:1

# === Layer L2: Pigeon contract ===
- id: pigeon-update-settings
  kind: pigeon-stub
  label: HostApi.updateSettings
  cite: packages/cambrian_camera/pigeons/camera_api.dart:320

- id: pigeon-set-processing-params
  kind: pigeon-stub
  label: HostApi.setProcessingParams
  cite: packages/cambrian_camera/pigeons/camera_api.dart:325

- id: pigeon-on-frame-result
  kind: pigeon-stub
  label: FlutterApi.onFrameResult
  cite: packages/cambrian_camera/pigeons/camera_api.dart:386

# === Layer L4: Kotlin Camera2 controller ===
- id: kotlin-update-settings
  kind: function
  label: CameraController.updateSettings
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1019

- id: build-capture-request
  kind: function
  label: buildCaptureRequest
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2335

- id: camera2-capture-request
  kind: class
  label: Camera2 CaptureRequest (ISP keys)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2347

- id: repeating-capture-callback
  kind: callback
  label: CaptureSession.CaptureCallback
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2730

- id: applied-settings
  kind: mailbox
  label: appliedSettings (last-accepted ISP state)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:256

- id: last-capture-snapshot
  kind: mailbox
  label: lastCaptureSnapshot (TotalCaptureResult cache for AE seed)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:251

- id: frame-result-throttle
  kind: function
  label: FrameResult throttle (every 10th capture result, ~3 Hz)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2811

- id: kotlin-capture-image
  kind: function
  label: CameraController.captureImage (GPU path)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1531

- id: kotlin-capture-natural
  kind: function
  label: CameraController.captureNaturalPicture (hardware ISP path)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1

- id: kotlin-set-processing-params
  kind: function
  label: CameraController.setProcessingParams (Kotlin handler)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1384

# === Layer L4: GL pipeline (Kotlin side) ===
- id: gl-thread
  kind: thread
  label: GL thread (HandlerThread "GpuPipeline-GL")
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:43

- id: gpu-pipeline
  kind: class
  label: GpuPipeline (Kotlin owner of GL thread + EGL setup)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:1

- id: on-frame-available
  kind: callback
  label: SurfaceTexture.OnFrameAvailableListener
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:396

- id: rot-and-flip-matrix
  kind: texture
  label: rotAndFlipMatrix (UV swap, 90°+vflip applied uniformly to all sinks)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:77

- id: gpu-set-adjustments
  kind: function
  label: GpuPipeline.setAdjustments (Kotlin → JNI bridge)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:336

- id: gpu-set-crop-output
  kind: function
  label: GpuPipeline.setCropOutput
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:300

# === Layer L6: C++ pipeline ===
- id: jni-boundary
  kind: jni-boundary
  label: JNI boundary (CameraBridge.cpp)
  cite: packages/cambrian_camera/android/src/main/cpp/src/CameraBridge.cpp:1

- id: oes-texture
  kind: texture
  label: OES external texture (SurfaceTexture-backed)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:140

- id: tone-map-shader
  kind: function
  label: Tone-mapping fragment shader (kFragSrc)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:42

- id: passthrough-shader
  kind: function
  label: Passthrough shader (raw stream)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:124

- id: draw-and-readback
  kind: function
  label: GpuRenderer::drawAndReadback (per-frame)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:326

- id: cpp-set-adjustments
  kind: function
  label: GpuRenderer::setAdjustments (writes uniforms under uniformMu_)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:695

- id: fbo-fullres
  kind: fbo
  label: fbo_ — full-res tone-mapped FBO (RGBA, GPU-resident, GL-thread owned)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:193

- id: fbo-tracker
  kind: fbo
  label: trackerFbo_ — 480p downsample FBO (RGBA, GL-thread owned)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:197

- id: fbo-raw
  kind: fbo
  label: rawFbo_ — passthrough raw FBO (allocated only if rawW_>0)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:228

- id: fbo-fullres-readback
  kind: fbo
  label: fullResReadbackFbo_ — Y-flip mirror of fbo_ for readback
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:234

- id: fbo-raw-readback
  kind: fbo
  label: rawReadbackFbo_ — Y-flip mirror of rawFbo_ for readback
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:239

- id: pbo-fullres
  kind: pbo
  label: fullResPbo_[2] — double-buffered async readback (mapped, callback-scoped)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:201

- id: pbo-tracker
  kind: pbo
  label: trackerPbo_[2]
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:202

- id: pbo-raw
  kind: pbo
  label: rawPbo_[2]
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:241

- id: pbo-index
  kind: atomic
  label: pboIndex_ (swing buffer index, 0 or 1)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:203

- id: fence-fullres
  kind: atomic
  label: fullResFence_[2] (GLsync, GPU-side fence per PBO)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:210

- id: fence-tracker
  kind: atomic
  label: trackerFence_[2] (GLsync)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:211

- id: fence-raw
  kind: atomic
  label: rawFence_[2] (GLsync)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:212

- id: egl-preview-surface
  kind: surface
  label: EGL window surface (Flutter SurfaceProducer / preview)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:184

- id: egl-encoder-surface
  kind: surface
  label: EGL encoder surface (MediaCodec input, when recording)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:186

- id: egl-raw-surface
  kind: surface
  label: EGL raw preview surface (when raw enabled)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:244

- id: image-pipeline
  kind: class
  label: ImagePipeline (consumer fan-out)
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:1

- id: deliver-fullres
  kind: function
  label: ImagePipeline::deliverFullResRgba (GL-thread entry from GpuRenderer)
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:52

- id: deliver-tracker
  kind: function
  label: ImagePipeline::deliverTrackerRgba
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:96

- id: deliver-raw
  kind: function
  label: ImagePipeline::deliverRawRgba
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:121

- id: memcpy-pbo-to-shared
  kind: function
  label: memcpy PBO → SharedFrame.data (THE 1 unavoidable copy per frame)
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:80

- id: shared-frame
  kind: struct
  label: SharedFrame (shared_ptr<Frame>; Frame.data = std::vector<uint8_t>; ref-counted, valid until last shared_ptr drops)
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:37

- id: processing-stage-fullres
  kind: mailbox
  label: ProcessingStage<FULL_RES> (1-slot drop-on-busy hook mailbox)
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:141

- id: consumer-fullres
  kind: mailbox
  label: Consumer mailbox (per FULL_RES sink, 1-slot drop-on-busy)
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:121

- id: consumer-tracker
  kind: mailbox
  label: Consumer mailbox (per TRACKER sink, 1-slot drop-on-busy)
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:121

- id: consumer-raw
  kind: mailbox
  label: Consumer mailbox (per RAW sink, 1-slot drop-on-busy)
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:121

- id: sink-frame
  kind: struct
  label: SinkFrame (raw pointer view into SharedFrame.data; valid only during user callback)
  cite: packages/cambrian_camera/android/src/main/cpp/include/cambrian_camera_native.h:29

- id: capture-to-file
  kind: function
  label: ImagePipeline::captureToFile (still-capture rendezvous)
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:413

# === GL uniforms (settings outbound terminus) ===
- id: uniform-brightness
  kind: texture
  label: GL uniform uBrightness
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:49

- id: uniform-contrast
  kind: texture
  label: GL uniform uContrast
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:50

- id: uniform-saturation
  kind: texture
  label: GL uniform uSaturation
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:51

- id: uniform-black-balance
  kind: texture
  label: GL uniform uBlackBalance (vec3)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:52

- id: uniform-gamma
  kind: texture
  label: GL uniform uGamma
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:53

# === Recording / encoder ===
- id: video-recorder
  kind: class
  label: VideoRecorder (MediaCodec surface-input + MediaMuxer)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/VideoRecorder.kt:37

- id: drain-thread
  kind: thread
  label: VideoEncoderDrain thread (MediaCodec output → MediaMuxer)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/VideoRecorder.kt:250

# === Self-heal ===
- id: rebind-flag
  kind: atomic
  label: consecutiveSwapFailures_ (preview rebind latch)
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:166

# === Threads (cross-cutting) ===
- id: background-handler
  kind: thread
  label: backgroundHandler (Camera2 ops, post-from-Pigeon)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:199

- id: main-handler
  kind: thread
  label: mainHandler (FlutterApi callbacks, Dart-bound emissions)
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2829

- id: dart-isolate
  kind: thread
  label: Dart main isolate (UI + plugin Dart facade)
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:1

# === Demo app (lib/) ===
- id: camera-app
  kind: class
  label: CameraApp (root StatelessWidget)
  cite: lib/main.dart:62

- id: camera-screen
  kind: class
  label: CameraScreen (StatefulWidget)
  cite: lib/main.dart:79

- id: camera-screen-state
  kind: class
  label: _CameraScreenState (single state container — all UI state lives here)
  cite: lib/main.dart:86

- id: bottom-bar
  kind: class
  label: BottomBar (animates between actions and settings chips)
  cite: lib/widgets/bottom_bar.dart:9

- id: gpu-controls-sidebar
  kind: class
  label: GpuControlsSidebar (WB/BB calibrate + GPU sliders)
  cite: lib/widgets/gpu_controls_sidebar.dart:43

- id: camera-control-overlay
  kind: class
  label: CameraControlOverlay (active-setting dial overlay)
  cite: lib/widgets/camera_control_overlay.dart:17

- id: camera-ruler-dial
  kind: class
  label: CameraRulerDial (iOS-style horizontal ruler)
  cite: lib/widgets/camera_ruler_dial/camera_ruler_dial.dart:29

- id: calibration-overlay
  kind: class
  label: CalibrationOverlay (fullscreen patch outline + confirm)
  cite: lib/widgets/calibration_overlay.dart:52

- id: recording-hud
  kind: class
  label: RecordingHud (elapsed-time + recording indicator)
  cite: lib/widgets/recording_hud.dart:45
```

### Edges (merged, deduplicated)

```yaml
# === Frame flow: Camera2 → OES → fbo_ → readback path ===
- from: on-frame-available
  to: gl-thread
  label: post drawAndReadback to GL handler
  mechanism: async-callback
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:396

- from: oes-texture
  to: fbo-fullres
  label: tone-map shader render (uTexMatrix = texMatrix × rotAndFlipMatrix)
  mechanism: gl-blit
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:366

- from: fbo-fullres
  to: egl-preview-surface
  label: blit + eglSwapBuffers (no Y-flip — preview path)
  mechanism: eglSwapBuffers
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:419

- from: fbo-fullres
  to: egl-encoder-surface
  label: blit + eglSwapBuffers (no Y-flip — encoder path) when recording
  mechanism: eglSwapBuffers
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:451

- from: fbo-fullres
  to: fbo-fullres-readback
  label: glBlitFramebuffer with inverted dst-Y (Y-flip mirror)
  mechanism: gl-blit
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:484

- from: fbo-fullres-readback
  to: pbo-fullres
  label: async glReadPixels to PBO[writeIdx]
  mechanism: gl-blit
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:491

- from: pbo-fullres
  to: fence-fullres
  label: glFenceSync inserted after readback
  mechanism: atomic-store
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:493

- from: fence-fullres
  to: pbo-fullres
  label: next-frame glClientWaitSync (8 ms timeout) before glMapBufferRange
  mechanism: atomic-load
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:533

- from: pbo-fullres
  to: deliver-fullres
  label: GL callback with mapped pointer (GL thread → C++ pipeline)
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:562

- from: deliver-fullres
  to: shared-frame
  label: allocate SharedFrame (heap)
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:75

- from: deliver-fullres
  to: memcpy-pbo-to-shared
  label: THE single memcpy from PBO → vector
  mechanism: memcpy
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:80

- from: deliver-fullres
  to: processing-stage-fullres
  label: route to hook stage if hookActive (drop-on-busy)
  mechanism: move-into-mailbox
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:92

- from: processing-stage-fullres
  to: consumer-fullres
  label: publishToFullResConsumers after in-place hook
  mechanism: shared_ptr-copy
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:191

- from: deliver-fullres
  to: consumer-fullres
  label: direct fan-out (no hook fast path)
  mechanism: shared_ptr-copy
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:92

- from: consumer-fullres
  to: sink-frame
  label: dispatch thread wakes; std::move pending; build SinkFrame view
  mechanism: move-into-mailbox
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:249

- from: sink-frame
  to: jni-boundary
  label: invoke user SinkCallback (data valid only during call)
  mechanism: async-callback
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:259

# === Tracker / Raw paths (parallel, same shape) ===
- from: fbo-fullres
  to: fbo-tracker
  label: Y-inverted downsample blit
  mechanism: gl-blit
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:406

- from: fbo-tracker
  to: pbo-tracker
  label: glReadPixels (already Y-flipped via downsample blit)
  mechanism: gl-blit
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:491

- from: oes-texture
  to: fbo-raw
  label: passthrough shader (no tone mapping)
  mechanism: gl-blit
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:610

- from: fbo-raw
  to: fbo-raw-readback
  label: Y-flip mirror blit
  mechanism: gl-blit
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:651

- from: fbo-raw-readback
  to: pbo-raw
  label: glReadPixels
  mechanism: gl-blit
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:658

- from: fbo-raw
  to: egl-raw-surface
  label: blit + eglSwapBuffers (raw preview)
  mechanism: eglSwapBuffers
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:629

- from: pbo-tracker
  to: deliver-tracker
  label: GL callback with mapped pointer
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:96

- from: pbo-raw
  to: deliver-raw
  label: GL callback with mapped pointer
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:121

- from: deliver-tracker
  to: consumer-tracker
  label: shared_ptr fan-out to TRACKER sinks
  mechanism: shared_ptr-copy
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:115

- from: deliver-raw
  to: consumer-raw
  label: shared_ptr fan-out to RAW sinks
  mechanism: shared_ptr-copy
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:140

# === Capture rendezvous ===
- from: kotlin-capture-image
  to: capture-to-file
  label: JNI captureToFile (sets captureRequested_ flag, waits CV)
  mechanism: jni
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1579

- from: deliver-fullres
  to: capture-to-file
  label: exchange(false) clears flag, hands frame via captureCV_
  mechanism: atomic-load
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:86

# === Settings outbound (Dart → hardware) ===
- from: camera-screen-state
  to: update-settings-dart
  label: slider/chip → updateSettings(CameraSettings(iso=Manual(N)))
  mechanism: sync-call
  cite: lib/main.dart:287

- from: update-settings-dart
  to: serializer
  label: enqueue
  mechanism: sync-call
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:315

- from: serializer
  to: serializer-pending
  label: in-flight replacement (no queueing)
  mechanism: mutex-protected-write
  cite: packages/cambrian_camera/lib/src/camera_settings_serializer.dart:26

- from: serializer
  to: pigeon-update-settings
  label: dispatch when slot is free
  mechanism: pigeon
  cite: packages/cambrian_camera/lib/src/camera_settings_serializer.dart:35

- from: pigeon-update-settings
  to: kotlin-update-settings
  label: cross-language Pigeon call
  mechanism: pigeon
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1019

- from: kotlin-update-settings
  to: applied-settings
  label: merge incoming with appliedSettings (auto-contagion, latch-from-AE)
  mechanism: mutex-protected-write
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1033

- from: kotlin-update-settings
  to: build-capture-request
  label: build CaptureRequest from merged settings
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1112

- from: build-capture-request
  to: camera2-capture-request
  label: set ISP keys (SENSOR_SENSITIVITY, LENS_FOCUS_DISTANCE, COLOR_CORRECTION_GAINS, etc.)
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2347

- from: set-processing-params-dart
  to: pigeon-set-processing-params
  label: fire-and-forget (no serializer)
  mechanism: pigeon
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:351

- from: pigeon-set-processing-params
  to: kotlin-set-processing-params
  label: Pigeon call
  mechanism: pigeon
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1384

- from: kotlin-set-processing-params
  to: gpu-set-adjustments
  label: forward to GpuPipeline (Kotlin)
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1391

- from: gpu-set-adjustments
  to: cpp-set-adjustments
  label: nativeGpuSetAdjustments (JNI)
  mechanism: jni
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:347

- from: cpp-set-adjustments
  to: uniform-brightness
  label: write brightness_ under uniformMu_
  mechanism: mutex-protected-write
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:699

- from: cpp-set-adjustments
  to: uniform-contrast
  label: write contrast_ under uniformMu_
  mechanism: mutex-protected-write
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:700

- from: cpp-set-adjustments
  to: uniform-saturation
  label: write saturation_ under uniformMu_
  mechanism: mutex-protected-write
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:701

- from: cpp-set-adjustments
  to: uniform-black-balance
  label: write blackBalance_[3] under uniformMu_
  mechanism: mutex-protected-write
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:702

- from: cpp-set-adjustments
  to: uniform-gamma
  label: write gamma_ under uniformMu_
  mechanism: mutex-protected-write
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:705

# === Settings inbound (FrameResult, hardware → Dart) ===
- from: repeating-capture-callback
  to: last-capture-snapshot
  label: extract ISO, exposure, focus, WB gains every result
  mechanism: mutex-protected-write
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2776

- from: repeating-capture-callback
  to: frame-result-throttle
  label: emit on every 10th result (~3 Hz at 30 fps)
  mechanism: sync-call
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2811

- from: frame-result-throttle
  to: pigeon-on-frame-result
  label: mainHandler.post → flutterApi.onFrameResult
  mechanism: pigeon
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2829

- from: pigeon-on-frame-result
  to: frame-result-stream
  label: _frameResultController.add
  mechanism: stream-emit
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:72

- from: frame-result-stream
  to: camera-screen-state
  label: _onFrameResult updates UI in auto modes
  mechanism: stream-emit
  cite: lib/main.dart:621

# === Calibration loops ===
- from: calibrate-wb
  to: sample-center-patch-dart
  label: read 96×96 trimmed-mean RGB
  mechanism: sync-call
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:444

- from: calibrate-wb
  to: update-settings-dart
  label: WhiteBalance.manual(gainR, gainG, gainB) per iteration
  mechanism: sync-call
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:432

- from: calibrate-bb
  to: sample-center-patch-dart
  label: read residual RGB after each iteration
  mechanism: sync-call
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:470

- from: calibrate-bb
  to: set-processing-params-dart
  label: ProcessingParams(blackR/G/B = accumulated offsets)
  mechanism: sync-call
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:470

# === Demo app widget tree (representative; full set in Subagent 3) ===
- from: camera-app
  to: camera-screen
  label: home: const CameraScreen()
  mechanism: sync-call
  cite: lib/main.dart:74

- from: camera-screen
  to: camera-screen-state
  label: createState
  mechanism: sync-call
  cite: lib/main.dart:81

- from: camera-screen-state
  to: bottom-bar
  label: rendered in build
  mechanism: sync-call
  cite: lib/main.dart:949

- from: camera-screen-state
  to: gpu-controls-sidebar
  label: rendered when _sidebarOpen
  mechanism: sync-call
  cite: lib/main.dart:858

- from: camera-screen-state
  to: camera-control-overlay
  label: rendered when _activeSetting != null
  mechanism: sync-call
  cite: lib/main.dart:921

- from: camera-control-overlay
  to: camera-ruler-dial
  label: dial for active param
  mechanism: sync-call
  cite: lib/widgets/camera_control_overlay.dart:77

- from: camera-screen-state
  to: cambrian-camera
  label: holds _camera; calls open/close/pause/resume/updateSettings/...
  mechanism: pigeon
  cite: lib/main.dart:92

- from: tone-mapped-texture-stream
  to: camera-screen-state
  label: _buildCameraPreview StreamBuilder
  mechanism: stream-emit
  cite: lib/main.dart:985
```

### Sequences (the canonical flows worth diagramming)

```yaml
- name: FULL_RES sink delivery (canonical hot path)
  steps:
    - actor: oes-texture; op: new frame from SurfaceTexture; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:142
    - actor: gl-thread; op: updateTexImage + compose uTexMatrix = texMatrix × rotAndFlipMatrix; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:416
    - actor: draw-and-readback; op: render OES → fbo_ via tone-map shader; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:366
    - actor: draw-and-readback; op: blit fbo_ → fullResReadbackFbo_ with inverted dst-Y; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:484
    - actor: draw-and-readback; op: glReadPixels → fullResPbo_[writeIdx]; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:491
    - actor: draw-and-readback; op: glFenceSync inserted; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:493
    - actor: gl-thread; op: NEXT frame — glClientWaitSync on fullResFence_[readIdx] (8 ms timeout); cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:533
    - actor: gl-thread; op: glMapBufferRange fullResPbo_[readIdx] → mapped pointer; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:558
    - actor: deliver-fullres; op: callback into ImagePipeline (GL thread); cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:562
    - actor: memcpy-pbo-to-shared; op: SINGLE memcpy from mapped PBO into SharedFrame.data; cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:80
    - actor: deliver-fullres; op: capture rendezvous — exchange(captureRequested_,false) and notify CV if set; cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:86
    - actor: deliver-fullres; op: route to processing stage if hookActive, else fan out direct; cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:92
    - actor: consumer-fullres; op: dispatch thread wakes via condvar, std::move pending → local SharedFrame; cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:249
    - actor: sink-frame; op: build SinkFrame view; invoke user SinkCallback (mutex released BEFORE callback); cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:259
    - actor: gl-thread; op: glUnmapBuffer after callback returns; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:564

- name: Encoder feed (recording active)
  steps:
    - actor: draw-and-readback; op: switch eglMakeCurrent to encoder surface; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:451
    - actor: draw-and-readback; op: blit fbo_ → default framebuffer (encoder window); cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:456
    - actor: draw-and-readback; op: eglSwapBuffers presents frame to MediaCodec; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:461
    - actor: draw-and-readback; op: switch eglMakeCurrent back to pbuffer; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:464
    - actor: drain-thread; op: poll encoder output buffers, write to MediaMuxer; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/VideoRecorder.kt:250

- name: ISO slider tap → CaptureRequest
  steps:
    - actor: camera-ruler-dial; op: drag delivers onChanged(newIso); cite: lib/widgets/camera_ruler_dial/camera_ruler_dial.dart:32
    - actor: camera-screen-state; op: _onIsoChanged guards on _aeSeeded, calls camera.updateSettings; cite: lib/main.dart:540
    - actor: update-settings-dart; op: enqueue via serializer; cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:312
    - actor: serializer; op: dispatch (or replace _pending if in-flight); cite: packages/cambrian_camera/lib/src/camera_settings_serializer.dart:24
    - actor: pigeon-update-settings; op: cross-language to Kotlin; cite: packages/cambrian_camera/pigeons/camera_api.dart:320
    - actor: kotlin-update-settings; op: merge with appliedSettings; auto-contagion check; latch-from-last-AE if needed; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1019
    - actor: build-capture-request; op: set CONTROL_AE_MODE=OFF, SENSOR_SENSITIVITY=N; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2347
    - actor: camera2-capture-request; op: setRepeatingRequest applied next frame; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1114

- name: ProcessingParams update → shader uniforms (fire-and-forget)
  steps:
    - actor: set-processing-params-dart; op: ProcessingParams(brightness, contrast, ...); cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:348
    - actor: pigeon-set-processing-params; op: Pigeon call (no serializer); cite: packages/cambrian_camera/pigeons/camera_api.dart:325
    - actor: kotlin-set-processing-params; op: persist to SharedPreferences, forward to GpuPipeline; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1384
    - actor: gpu-set-adjustments; op: nativeGpuSetAdjustments JNI call; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:347
    - actor: cpp-set-adjustments; op: lock uniformMu_, write 5 float uniforms; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:698
    - actor: cpp-set-adjustments; op: release mutex; next GPU frame reads new values; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:706

- name: FrameResult emission (hardware → UI, every 10th result ~3 Hz)
  steps:
    - actor: repeating-capture-callback; op: onCaptureCompleted on backgroundHandler; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2730
    - actor: last-capture-snapshot; op: extract ISO, exposure, focus, WB gains; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2776
    - actor: frame-result-throttle; op: skip unless captureResultCount % 10 == 0; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2811
    - actor: pigeon-on-frame-result; op: mainHandler.post → flutterApi.onFrameResult; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2829
    - actor: frame-result-stream; op: _frameResultController.add on Dart isolate; cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:72
    - actor: camera-screen-state; op: _onFrameResult updates _values in auto modes; cite: lib/main.dart:621

- name: captureImage GPU still capture
  steps:
    - actor: camera-screen-state; op: tap CAPTURE; camera.captureImage(); cite: lib/main.dart:693
    - actor: kotlin-capture-image; op: validate state, resolve output path on backgroundHandler; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1531
    - actor: capture-to-file; op: captureRequested_.store(true, release); wait captureCV_ (500 ms timeout); cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:422
    - actor: deliver-fullres; op: NEXT frame — captureRequested_.exchange(false, acq_rel) → store SharedFrame, notify CV; cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:86
    - actor: capture-to-file; op: encode SharedFrame.data to JPEG/PNG (fpng for PNG); cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:484
    - actor: kotlin-capture-image; op: write EXIF metadata, return path on mainHandler; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:1586

- name: White balance calibration loop
  steps:
    - actor: calibrate-wb; op: snapshot initial gains, take patchBefore via sampleCenterPatch; cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:423
    - actor: calibrate-wb; op: while wbError(sample) >= 0.01 and iter<10; cite: packages/cambrian_camera/lib/src/calibration.dart:73
    - actor: calibrate-wb; op: gainR *= sample.g/sample.r; gainB *= sample.g/sample.b; cite: packages/cambrian_camera/lib/src/calibration.dart:94
    - actor: update-settings-dart; op: WhiteBalance.manual(gainR, gainG, gainB); cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:432
    - actor: calibrate-wb; op: sleep 200 ms for Camera2 to apply; resample; cite: packages/cambrian_camera/lib/src/calibration.dart:55
    - actor: calibrate-wb; op: return WbCalibrationResult(gains, patchBefore, patchAfter)

- name: Preview rebind self-heal
  steps:
    - actor: draw-and-readback; op: eglSwapBuffers fails (EGL_BAD_SURFACE); cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:434
    - actor: rebind-flag; op: consecutiveSwapFailures_++; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp:434
    - actor: gl-thread; op: needsPreviewRebind() returns true at threshold; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:432
    - actor: gpu-pipeline; op: invoke onPreviewRebindNeeded callback (CameraController hooks here); cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:435
    - actor: gpu-pipeline; op: rebindPreviewSurface(newSurface) on GL thread; cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:328
    - actor: rebind-flag; op: clearRebindFlag → counter = 0; cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:153

- name: Demo app initialization (camera open)
  steps:
    - actor: camera-screen-state; op: initState calls _openCamera(); cite: lib/main.dart:171
    - actor: camera-screen-state; op: Permission.camera.request(); cite: lib/main.dart:216
    - actor: cambrian-camera; op: CambrianCamera.open(settings: _kInitialSettings); cite: lib/main.dart:222
    - actor: camera-screen-state; op: read camera.capabilities; cite: lib/main.dart:233
    - actor: camera-screen-state; op: subscribe frameResultStream / errorStream / recordingStateStream; cite: lib/main.dart:261
    - actor: tone-mapped-texture-stream; op: emit on stateChange to streaming → texture surfaces in StreamBuilder; cite: lib/main.dart:985
```

### Threads

```yaml
- name: Dart main isolate
  owns:
    - update-settings-dart
    - set-processing-params-dart
    - sample-center-patch-dart
    - calibrate-wb
    - calibrate-bb
    - serializer
    - serializer-pending
    - frame-result-stream
    - tone-mapped-texture-stream
    - error-stream
    - recording-state-stream
    - camera-screen-state
    - camera-app
    - camera-screen
  cite: packages/cambrian_camera/lib/src/cambrian_camera_controller.dart:1

- name: Android main thread (mainHandler)
  owns:
    - main-handler
    - pigeon-on-frame-result
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:2829

- name: backgroundHandler (Camera2 ops)
  owns:
    - background-handler
    - kotlin-update-settings
    - kotlin-set-processing-params
    - kotlin-capture-image
    - kotlin-capture-natural
    - applied-settings
    - last-capture-snapshot
    - repeating-capture-callback
    - frame-result-throttle
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:199

- name: GL thread (HandlerThread "GpuPipeline-GL")
  owns:
    - gl-thread
    - draw-and-readback
    - on-frame-available
    - oes-texture
    - rot-and-flip-matrix
    - fbo-fullres
    - fbo-tracker
    - fbo-raw
    - fbo-fullres-readback
    - fbo-raw-readback
    - pbo-fullres
    - pbo-tracker
    - pbo-raw
    - pbo-index
    - fence-fullres
    - fence-tracker
    - fence-raw
    - egl-preview-surface
    - egl-encoder-surface
    - egl-raw-surface
    - tone-map-shader
    - passthrough-shader
    - cpp-set-adjustments
    - gpu-set-adjustments
    - gpu-set-crop-output
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/GpuPipeline.kt:43

- name: Processing stage thread (one per role with hook installed)
  owns:
    - processing-stage-fullres
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:168

- name: Consumer dispatch thread (one per registered sink, per role)
  owns:
    - consumer-fullres
    - consumer-tracker
    - consumer-raw
    - sink-frame
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp:240

- name: VideoEncoderDrain thread
  owns:
    - drain-thread
    - video-recorder
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/VideoRecorder.kt:250
```

### Sync primitives

```yaml
- name: serializer._pending + _inFlight (Dart)
  kind: mailbox
  guards: [in-flight CameraSettings, latest-value-wins replacement]
  cite: packages/cambrian_camera/lib/src/camera_settings_serializer.dart:17

- name: appliedSettings (Kotlin)
  kind: mailbox
  guards: [last-accepted ISP state for merge + replay]
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:256

- name: lastCaptureSnapshot (Kotlin)
  kind: mailbox
  guards: [most-recent TotalCaptureResult fields used for AE seed on switch-to-manual]
  cite: packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt:251

- name: uniformMu_ (C++)
  kind: mutex
  guards: [brightness_, contrast_, saturation_, blackBalance_[3], gamma_]
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:251

- name: fullResConsumersMu_
  kind: mutex
  guards: [FULL_RES sink list — addSink/removeSink/iterate]
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:129

- name: trackerConsumersMu_
  kind: mutex
  guards: [TRACKER sink list]
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:133

- name: rawConsumersMu_
  kind: mutex
  guards: [RAW sink list]
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:137

- name: captureRequested_
  kind: atomic
  guards: [still-capture rendezvous flag — exchange(false) hands ownership]
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:149

- name: captureResultMu_ + captureCV_
  kind: condvar
  guards: [capturedFrame_ rendezvous between deliverFullResRgba and captureToFile]
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:150

- name: pboIndex_
  kind: atomic
  guards: [PBO swing buffer (write index, read = 1 - write)]
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:203

- name: fullResFence_[2]
  kind: atomic
  guards: [GPU→CPU DMA completion for fullResPbo_[2] (GLsync per slot)]
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:210

- name: trackerFence_[2]
  kind: atomic
  guards: [GLsync for tracker PBOs]
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:211

- name: rawFence_[2]
  kind: atomic
  guards: [GLsync for raw PBOs]
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:212

- name: consecutiveSwapFailures_
  kind: atomic
  guards: [preview rebind latch — incremented on EGL_BAD_SURFACE, cleared on rebind]
  cite: packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h:166

- name: ProcessingStage::running + mu + cv
  kind: condvar
  guards: [hook stage worker pending slot — drop-on-busy semantics]
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:49

- name: Consumer::mu + cv
  kind: condvar
  guards: [per-sink dispatch thread mailbox — drop-on-busy semantics]
  cite: packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h:122

# Demo app — none
- name: (demo app)
  kind: affinity
  guards: [Dart isolate-only; no application-level mutexes/atomics. Stream subscriptions, setState, and StreamBuilder are sufficient.]
  cite: lib/main.dart:1
```

---

## Recommended diagrams (and which Sequences feed each)

The structured data above is sized for the eight diagrams that give the most understanding-per-render. Pair each diagram with the sequence(s) that drive it:

| # | Diagram | Sequence(s) to feed Excalidraw |
|---|---|---|
| 1 | Layer architecture L1–L6 | (synthesize from the section comments in the Symbols list) |
| 2 | FULL_RES sink delivery (canonical hot path) | "FULL_RES sink delivery" |
| 3 | Buffer ownership lifecycle | (use Symbols + Edges in the FULL_RES path; don't filter by sequence) |
| 4 | Threading model | (use Threads section directly) |
| 5 | Per-endpoint fan-out | "FULL_RES sink delivery" + "Encoder feed" + "captureImage" + "Preview rebind self-heal" |
| 6 | Settings flow OUT (one diagram per category) | "ISO slider tap → CaptureRequest", "ProcessingParams update → shader uniforms" |
| 7 | Settings flow IN (FrameResult) | "FrameResult emission" |
| 8 | GPU FBO topology + Y-flip | (use the FBO/PBO/Surface symbols + the gl-blit edges between them) |

For each diagram, feeding the Excalidraw MCP the relevant `Symbols` (filtered by id), the `Edges` (filtered by `from`/`to` in that subset), and one `Sequences` entry should be enough to render without re-reading source.

---

## Summary

- 4,259 lines of code-derived prose + structured data across the four exploration documents.
- 7/7 spot-checked citations correct.
- 1 confirmed drift (`docs/architecture.md` LUT claim — code uses direct uniforms under `uniformMu_`).
- 1 coverage gap in Subagent 1 (`rotAndFlipMatrix` UV swap mechanism not documented; `docs/architecture.md` is correct on this point).
- 0 Mermaid blocks emitted.
- 0 reads from `docs/` by any subagent (verified — only the synthesis pass read docs).
- 0 contradictions between subagents.

The four documents together are sufficient input for the Excalidraw MCP to render the eight recommended diagrams without any model needing to re-open source files.
