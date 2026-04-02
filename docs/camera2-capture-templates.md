# Camera2 Capture Request Templates

Camera2 provides six built-in templates via `CameraDevice.createCaptureRequest(int templateType)`. Each template pre-fills a `CaptureRequest.Builder` with settings tuned for a specific use case.

## Template Overview

| Template Constant | `CAPTURE_INTENT` value | Typical use |
|---|---|---|
| `TEMPLATE_PREVIEW` | `PREVIEW` | Repeating preview / viewfinder |
| `TEMPLATE_STILL_CAPTURE` | `STILL_CAPTURE` | Single high-quality JPEG |
| `TEMPLATE_RECORD` | `VIDEO_RECORD` | Continuous video recording |
| `TEMPLATE_VIDEO_SNAPSHOT` | `VIDEO_SNAPSHOT` | Still image taken during video |
| `TEMPLATE_ZERO_SHUTTER_LAG` | `ZERO_SHUTTER_LAG` | ZSL pipeline (reprocessing) |
| `TEMPLATE_MANUAL` | `MANUAL` | Full app control, all 3A off |

## Settings Comparison

| Setting | `PREVIEW` | `STILL_CAPTURE` | `RECORD` | `VIDEO_SNAPSHOT` | `ZERO_SHUTTER_LAG` | `MANUAL` |
|---|---|---|---|---|---|---|
| `CONTROL_MODE` | `AUTO` | `AUTO` | `AUTO` | `AUTO` | `AUTO` | **`OFF`** |
| `CONTROL_AE_MODE` | `ON` | `ON` | `ON` | `ON` | `ON` | **`OFF`** |
| `CONTROL_AF_MODE` | `CONTINUOUS_PICTURE` | **`AUTO`** | **`CONTINUOUS_VIDEO`** | **`CONTINUOUS_VIDEO`** | `CONTINUOUS_PICTURE` | **`OFF`** |
| `CONTROL_AWB_MODE` | `AUTO` | `AUTO` | `AUTO` | `AUTO` | `AUTO` | **`OFF`** |
| `NOISE_REDUCTION_MODE` | `FAST` | **`HIGH_QUALITY`** | `FAST` | `FAST` | **`ZERO_SHUTTER_LAG`** | `FAST` |
| `EDGE_MODE` | `FAST` | **`HIGH_QUALITY`** | `FAST` | `FAST` | **`ZERO_SHUTTER_LAG`** | `FAST` |
| `HOT_PIXEL_MODE` | `FAST` | **`HIGH_QUALITY`** | `FAST` | `FAST` | **`ZERO_SHUTTER_LAG`** | `FAST` |
| `COLOR_ABERRATION_MODE` | `FAST` | **`HIGH_QUALITY`** | `FAST` | `FAST` | **`ZERO_SHUTTER_LAG`** | `FAST` |

## Key Distinctions

### `PREVIEW` vs `ZERO_SHUTTER_LAG`
These are the most similar templates. The only differences are:

- `CAPTURE_INTENT`: `PREVIEW` → `ZERO_SHUTTER_LAG`
- All post-processing modes (`NOISE_REDUCTION`, `EDGE`, `HOT_PIXEL`, `COLOR_ABERRATION`): `FAST` → `ZERO_SHUTTER_LAG`

`ZERO_SHUTTER_LAG` mode is **not** "no processing" — it means *reprocessing-compatible* processing. The HAL keeps output in a state that can be fed back into a reprocess request (`ImageWriter` + `CameraConstrainedHighSpeedCaptureSession`), rather than optimizing purely for display latency.

### `STILL_CAPTURE`
All post-processing modes flip to `HIGH_QUALITY`. This can stall the pipeline but produces the best image quality. AF mode switches to `AUTO` (single-shot) rather than continuous.

### `RECORD` and `VIDEO_SNAPSHOT`
Both use `CONTINUOUS_VIDEO` AF mode. `VIDEO_SNAPSHOT` must not stall the video pipeline, so post-processing stays at `FAST` despite capturing a still.

### `MANUAL`
`CONTROL_MODE` is set to `OFF`, which disables all three 3A routines (AE, AF, AWB). The app is responsible for setting `SENSOR_EXPOSURE_TIME`, `SENSOR_SENSITIVITY`, `SENSOR_FRAME_DURATION`, `LENS_FOCUS_DISTANCE`, and `COLOR_CORRECTION_GAINS` directly.

## Post-processing Mode Meanings

| Mode value | Meaning |
|---|---|
| `FAST` | Non-blocking; safe for real-time/preview use |
| `HIGH_QUALITY` | Best output; may introduce pipeline stalls |
| `ZERO_SHUTTER_LAG` | Reprocess-safe; compatible with ZSL reprocessing pipelines |
| `OFF` | Processing disabled entirely |

## References

- [`CameraDevice` API reference](https://developer.android.com/reference/android/hardware/camera2/CameraDevice)
- [`CaptureRequest` keys](https://developer.android.com/reference/android/hardware/camera2/CaptureRequest)
- [AOSP camera3.h HAL spec](https://android.googlesource.com/platform/hardware/libhardware/+/refs/heads/master/include/hardware/camera3.h)
