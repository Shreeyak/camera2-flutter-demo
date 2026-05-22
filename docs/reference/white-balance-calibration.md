# White Balance Calibration

## Overview

White balance calibration computes per-channel gain multipliers — one for red and one for blue, with green held as a fixed reference — that cause a known neutral surface (white or mid-grey) to appear neutral in the output image. The gains are applied at the earliest point in the imaging pipeline, before any display processing, so they describe the sensor's physical color response rather than an aesthetic preference.

The algorithm is a closed-loop proportional controller: it measures the current output, computes a correction, applies it to the hardware, waits for the pipeline to settle, and repeats until the neutral surface reads as neutral.

---

## Pipeline Architecture

Frames pass through three stages before reaching the calibration sampler:

```
Sensor (raw Bayer)
    │
    ▼
[Stage 1] Hardware color correction
    │  Multiplicative per-channel gains (R, G, B) applied to linear-light
    │  data before demosaicing and encoding.
    │  These are the gains that calibration computes.
    │
    ▼
[Stage 2] Hardware decode to RGB
    │  The corrected signal is decoded to an RGB image.
    │  Values are display-referred, gamma-encoded sRGB (γ ≈ 2.2).
    │  NOT linear light.
    │
    ▼
[Stage 3] Display processing shader
    │  Applies, in order: black-level subtraction, brightness, contrast,
    │  saturation, and gamma correction.
    │  Output: gamma-encoded RGBA in a GPU framebuffer.
    │
    ▼
[Framebuffer] ← calibration sampler reads here
```

> **Android / this implementation:** Stage 1 gains are set via `CaptureRequest.COLOR_CORRECTION_GAINS` as an `RggbChannelVector(gainR, gainGeven, gainGodd, gainB)` with `CONTROL_AWB_MODE = OFF` and `COLOR_CORRECTION_MODE = TRANSFORM_MATRIX`. The two green slots are set to the same value — the RGGB Bayer pattern has two green photosites per 2×2 tile, and most sensors have symmetric green response. Stage 3 is a GLSL ES 3.0 fragment shader running on the device GPU. The framebuffer is a GL FBO backed by an RGBA texture.

**Critical constraint:** Stage 3 must be at identity during calibration. The sampler reads from the post-shader framebuffer; any active display adjustments contaminate the feedback signal, causing the loop to converge to gains that compensate for the current shader state rather than the sensor's raw response. Those gains become incorrect the moment the display settings change.

---

## Patch Sampling

The sampler reads the center **96 × 96** pixel block from the framebuffer and computes a **15% trimmed mean** per channel:

1. Build a 256-bin histogram per channel in one O(n) pass over the 9 216 pixels.
2. Discard the lowest and highest 1 382 values (15% of 9 216) from each histogram.
3. Average the remaining values and normalize to [0.0, 1.0].
4. Return `(r, g, b)`, each in [0.0, 1.0], in gamma-encoded sRGB.

Trimming suppresses hot pixels, specular highlights, and sensor dust that would otherwise skew the mean.

> **Android / this implementation:** The sampler binds the full-resolution processed FBO, calls `glReadPixels` with `GL_RGBA / GL_UNSIGNED_BYTE`, then runs the histogram on the CPU. The pixel byte layout is R=0, G=1, B=2, A=3. The 96×96 block is centered at `((width − 96) / 2, (height − 96) / 2)`.

---

## Linearization

Framebuffer values are gamma-encoded. All gain ratio calculations must be done in linear light, because Stage 1 gains operate in linear sensor space. Convert using the sRGB inverse EOTF:

```
linearize(v):
    if v ≤ 0.04045:  return v / 12.92
    else:             return ((v + 0.055) / 1.055) ^ 2.4
```

Apply before any ratio computation. Skip channels whose encoded value is below 0.001 to avoid division by zero (0.001 encoded ≈ 3.3 × 10⁻⁵ linear).

---

## Error Metric

Green is the fixed reference. Error is the maximum per-channel deviation from green, normalized by green:

```
error(r, g, b) = max(|r − g|, |b − g|) / clamp(g, 0.001, 1.0)
```

Zero when the patch is exactly neutral. Convergence threshold: **0.01** (1% deviation — imperceptible under normal viewing conditions).

---

## Seeding

Before starting the loop, read the current Stage 1 gains from the hardware and use them as the initial `(gainR, gainG, gainB)`. This ensures the loop starts from a coherent state and avoids a jarring color shift on the first iteration.

If no hardware gains are available, seed from `(1.0, 1.0, 1.0)`. The loop will still converge but may require extra iterations and will momentarily push incorrect gains to the hardware before recovering.

> **Android / this implementation:** Read the current gains from `CaptureResult.COLOR_CORRECTION_GAINS` (available in the per-frame metadata). The result is an `RggbChannelVector`; use `red`, `(greenEven + greenOdd) / 2`, and `blue`. These are populated by the driver whether AWB is running automatically or gains are set manually.

---

## Calibration Loop

```
// 1. Push identity to Stage 3.
savedDisplayParams ← currentDisplayParams
apply identity:
    blackBalance = (0, 0, 0)
    brightness = 0,  contrast = 0,  saturation = 0,  gamma = 1
wait one settle period   // allow the pipeline to flush before first sample

// 2. Sample initial state.
patchBefore ← sampleCenterPatch()
lastSample  ← patchBefore
gainR ← initialGainR
gainG ← initialGainG   // never updated — green is the fixed reference
gainB ← initialGainB

// 3. Iterative correction.
try:
    for i in 0 ..< 10:
        if error(lastSample) < 0.01:
            break

        lr ← linearize(lastSample.r)
        lg ← linearize(lastSample.g)
        lb ← linearize(lastSample.b)

        if lastSample.r > 0.001:  gainR ← gainR × (lg / lr)
        if lastSample.b > 0.001:  gainB ← gainB × (lg / lb)

        apply (gainR, gainG, gainB) to Stage 1 hardware
        wait one settle period
        lastSample ← sampleCenterPatch()

except:
    apply (initialGainR, initialGainG, initialGainB) to Stage 1   // restore on failure
    apply savedDisplayParams
    rethrow

// 4. Commit and record.
apply (gainR, gainG, gainB) to Stage 1   // always commit — handles the already-neutral case
patchAfter ← sampleCenterPatch()

// 5. Restore Stage 3.
apply savedDisplayParams

return { gains: (gainR, gainG, gainB), patchBefore, patchAfter }
```

> **Android / this implementation:** `setProcessingParams(ProcessingParams())` applies identity Stage 3 params (constructor defaults: `blackR/G/B = 0`, `brightness = 0`, `contrast = 0`, `saturation = 0`, `gamma = 1.0`). The controller does not hold the current `ProcessingParams` in memory; the caller must supply `savedDisplayParams` before invoking calibration. Stage 1 gains are applied via `updateSettings(CameraSettings(whiteBalance: WhiteBalance.manual(...)))`.

### Why the loop converges

If a white surface has true linear sensor response `(r₀, g₀, b₀)` and the current Stage 1 gains are `(gainR, gainG, gainB)`, then the linear-light values behind the encoded FBO are approximately:

```
r_linear = r₀ × gainR
g_linear = g₀ × gainG
```

After one correction step:

```
gainR_new = gainR × (g_linear / r_linear)
           = gainR × (g₀ × gainG) / (r₀ × gainR)
           = gainG × (g₀ / r₀)
```

On the next frame, `r_linear = r₀ × gainR_new = g₀ × gainG = g_linear`. Red equals green — error = 0. On an ideal pipeline this converges in one iteration. Realistic sensor noise and mild nonlinearities mean 1–3 iterations are typical.

---

## Constants

| Constant | Value | Meaning |
|---|---|---|
| Patch size | 96 × 96 px | Center block sampled from framebuffer |
| Trim fraction | 15% | Discarded from each histogram tail (1 382 of 9 216 pixels) |
| Convergence threshold | 0.01 | Max normalized per-channel error |
| Max iterations | 10 | Hard cap (≤ 2 s at 200 ms/iter) |
| Settle period | 200 ms | Wait per iteration (≈ 6 frames at 30 fps) |

---

## Files (this implementation)

| File | Role |
|---|---|
| `packages/cambrian_camera/lib/src/calibration.dart` | `wbStep`, `wbError` math |
| `packages/cambrian_camera/lib/src/cambrian_camera_controller.dart` | `calibrateWhiteBalance` loop |
| `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp` | `sampleCenterPatch`, GLSL fragment shader |
