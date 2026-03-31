# camera2_flutter_demo

A Flutter demo app for the `cambrian_camera` plugin — a Camera2-backed camera library with a C++ ISP pipeline.

## Quick Start

```bash
flutter pub get
flutter run                    # prompts for device
flutter run -d <device_id>    # specific device
```

## Project Structure

- `lib/` — Flutter/Dart app (entry point: `main.dart`)
- `packages/cambrian_camera/` — Camera plugin
  - `lib/` — Dart API (`CambrianCamera`, `CameraSettings`, `ProcessingParams`, `FrameResult`)
  - `android/src/main/kotlin/` — Kotlin Camera2 implementation
  - `android/src/main/cpp/` — C++ ISP pipeline (JNI bridge + `ImagePipeline`)
- `android/` — Host app Android config
- `ios/` — Host app iOS config

## Building

```bash
flutter build apk            # Android APK
flutter build appbundle      # Android App Bundle
flutter analyze              # Dart linter
dart format lib/             # Format Dart code
```

## Plugin API Highlights

Full reference: [`docs/cambrian-camera-usage-guide.md`](docs/cambrian-camera-usage-guide.md)

| API | Description |
|-----|-------------|
| `CambrianCamera.open()` | Open camera, returns when streaming |
| `camera.buildPreview()` | Live preview widget |
| `camera.updateSettings()` | ISP settings (ISO, exposure, focus, WB, zoom) |
| `camera.stateStream` | Lifecycle state changes (`streaming`, `recovering`, …) |
| `camera.errorStream` | Camera errors with fatal/recoverable flag |
| `camera.frameResultStream` | Actual sensor values at ~3 Hz (ISO, exposure, focus, WB gains) |
| `camera.takePicture()` | JPEG still capture |
| `camera.getNativePipelineHandle()` | C++ consumer registration |

## Diagnostic Logging

All logs use the `CambrianCamera` tag and are controlled by two flags in
`CambrianCameraConfig.kt`. Both default to `true` — set to `false`
before shipping.

### `verboseDiagnostics`

Frame-flow and capture-result diagnostics. Periodic logs use a **every-60-frames**
cadence (frame #1, then #60, #120, …).

| Trigger | Log message |
|---------|-------------|
| Session start | `startCaptureSession format=<RGBA/YUV> size=WxH` |
| Repeating request set | `setRepeatingRequest target=<surface> initialIso=… initialExposureNs=…` |
| RGBA frame received (×60) | `stream frame#N RGBA WxH stride=S` |
| YUV frame received (×60) | `stream frame#N YUV WxH` |
| Capture result (×60) | `capture result#N target=<surface> aeMode=… aeState=… iso=… exposureNs=…` |
| Settings update | `updateSettings request target=<surface> iso=… exposureNs=…` |
| YUV surface rebind start | `Rebinding YUV preview surface via createCaptureSession` |
| YUV surface rebind done | `YUV preview rebind complete target=<surface>` |

### `verboseSettings`

Full ISP settings dump on every `updateSettings` call. Fires at slider rates
(can be 30+ times/second while dragging), so disable before shipping.

| Trigger | Log message |
|---------|-------------|
| Any `updateSettings` call | `updateSettings: iso=… exposureNs=… focus=…dpt zoom=…x af=… awbLocked=… ev=…` (only non-null fields shown) |
