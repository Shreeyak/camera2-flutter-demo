# Cambrian Camera

A Flutter plugin for Camera2-backed camera control with C++ post-processing.
The iOS implementation is backed by the CameraKit Swift engine; Android uses
Camera2 + an OpenGL ES / libjpeg-turbo pipeline.

## Platform Setup

### iOS (Swift Package Manager)

The iOS plugin ships as a Swift package, not a CocoaPod. The host app must have
Flutter's SPM support enabled:

```bash
flutter config --enable-swift-package-manager
```

- **Deployment target: iOS 26.0+.** The plugin's `Package.swift` declares
  `platforms: [.iOS("26.0")]` and the vendored CameraKit engine requires
  `.iOS(.v26)`. Set `IPHONEOS_DEPLOYMENT_TARGET = 26.0` in the host app's
  Xcode project (all build configurations) or the SPM resolve will fail.
- **First build, not `pub get`, wires the native side.** `flutter build` (or
  `flutter run`) triggers Flutter's iOS-platform plugin migration that links
  the plugin's Swift package. Running only `flutter pub get` resolves the Dart
  dependency but does **not** generate the SPM linkage — a common "it compiled
  the Dart but Xcode can't find the plugin" gotcha.
- **Plugin class name convention.** Flutter derives the iOS plugin class from
  the package name: `<PascalCase(package)> + "Plugin"`. Here `cambrian_camera`
  → `CambrianCameraPlugin`. A mismatch surfaces at runtime as
  `MissingPluginException`.
- **Privacy strings.** Add `NSCameraUsageDescription` and (if saving to the
  photo library) `NSPhotoLibraryAddUsageDescription` to the host app's
  `Info.plist`. Recording also needs `NSMicrophoneUsageDescription`.

### Android

No manual native setup is required. The plugin's NDK build compiles the C++
pipeline (OpenGL ES + libjpeg-turbo) automatically — `libjpeg-turbo` is
fetched and built from source by CMake. The module targets `arm64-v8a` and
`minSdk 33`.

### Updating the vendored CameraKit engine (iOS)

CameraKit lives under `ios/cambrian_camera/CameraKit/`, vendored via
`git subtree`. It is produced by the `eva-swift-stitch` repository and pulled
in as released versions. To consume a new CameraKit release, pull the subtree
from the producer's release branch/tag rather than editing the vendored copy
in place — local edits here are overwritten on the next subtree pull. See
`eva-swift-stitch` `CLAUDE.md` §10 for the producer-side release mechanism.

## Example App (HITL Harness)

`packages/cambrian_camera/example` is a hardware-in-the-loop verification
harness: one button per host method plus live panels fed by every FlutterApi
stream (state, error, frame-result, recording-state, textures). It is the
fastest way to exercise the full plugin contract on a physical device.

```bash
cd packages/cambrian_camera/example
flutter run -d <device-udid>
```

## Quick Start

```dart
import 'package:cambrian_camera/cambrian_camera.dart';
import 'package:flutter/widgets.dart';

final camera = await CambrianCamera.open();
```

## Displaying the Preview

The library exposes texture streams as data primitives via `toneMappedTexture` and `rawTexture`. Your app builds widgets from these primitives:

```dart
StreamBuilder<CameraTextureInfo>(
  stream: camera.toneMappedTexture,
  builder: (context, snap) {
    if (!snap.hasData) return const SizedBox.expand();
    final t = snap.data!;
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(
        width: t.width.toDouble(),
        height: t.height.toDouble(),
        child: Texture(textureId: t.textureId),
      ),
    );
  },
)
```

Preview, video recording, and `captureImage` all receive the same pixels, with the fixed
rotation + vertical flip applied inside the GPU shader (see `GpuPipeline.rotAndFlipMatrix`).
Wrap the `Texture` widget in a `SizedBox` using the `CameraTextureInfo.width` / `height`
dimensions and let `FittedBox` handle scaling — no additional per-orientation rotation is
needed in the app. `captureNaturalPicture` is unaffected and continues to tag saved JPEGs
with EXIF orientation as before.

## Device Capabilities

After `open()`, `camera.capabilities` exposes hardware ranges for building UI controls: ISO, exposure time, focus distance, zoom, EV compensation, and supported resolutions. Check `capabilities.rawStreamWidth > 0` to confirm the raw stream is active.

## Camera Settings

Update ISP-level settings (ISO, exposure, focus, white balance):

```dart
// Only send what changed; omitted fields keep their previous values
camera.updateSettings(CameraSettings(iso: AutoValue.manual(400)));
camera.updateSettings(CameraSettings(focus: AutoValue.auto()));
```

Listen for actual hardware sensor values:

```dart
camera.frameResultStream.listen((result) {
  print('ISO: ${result.iso}, Exposure: ${result.exposureTimeNs}ns');
});
```

## GPU Pipeline Parameters

All parameters are in `[-1.0, 1.0]` with `0.0` as identity (no effect). Changes take effect on the next rendered frame.

```dart
camera.setProcessingParams(ProcessingParams(
  brightness: 0.1,   // additive offset; -1 = black, +1 = white
  contrast:   0.3,   // pivot around mid-grey; -1 = flat, +1 = maximum contrast
  saturation: 0.5,   // -1 = greyscale, 0 = natural, +1 = boosted
));
```

**Black balance** subtracts a per-channel offset from every pixel before other adjustments.
Use it to correct the sensor's black level — the non-zero signal the hardware outputs even
in complete darkness, which causes shadows to appear grey or colour-shifted rather than true black:

```dart
camera.setProcessingParams(ProcessingParams(
  blackR: 0.05,  // per-channel offset in [0.0, 0.5]; 0.0 = no correction
  blackG: 0.04,
  blackB: 0.06,
));
```

Black balance is applied first in the pipeline, before brightness/contrast/saturation, which
is the correct order — you remove the sensor's DC offset before stretching or shifting the signal.

## Video Recording

Start and stop recording to an MP4 file in the device's MediaStore:

```dart
// Start — returns (contentUri, displayName)
final (uri, name) = await camera.startRecording();

// Optional: custom directory and/or file name
final (uri, name) = await camera.startRecording(
  outputDirectory: 'Movies/MyApp/',  // MediaStore RELATIVE_PATH; defaults to Movies/CambrianCamera/
  fileName: 'my_clip',               // .mp4 appended automatically if omitted
);

// Stop — finalizes the file and makes it visible in the gallery
await camera.stopRecording();
```

While recording is active, Camera2 switches from `TEMPLATE_PREVIEW` to `TEMPLATE_RECORD`
for video-optimised capture settings, and the AE target fps range changes from a fixed
`[30, 30]` (preview) to `[15, 30]` (recording). The variable lower bound gives AE
headroom to extend exposure in dark scenes rather than underexposing, while the upper
bound keeps the container frame rate at 30 fps. It reverts to `TEMPLATE_PREVIEW` and
`[30, 30]` automatically when recording stops.

`CONTROL_AE_ANTIBANDING_MODE_AUTO` is set on all capture requests to protect against the
moving horizontal band artifact caused by rolling shutter interacting with artificial light
flicker (50/60 Hz mains). AE constrains its exposure choices to safe multiples of the
detected flicker period.

Monitor recording state changes via the stream:

```dart
camera.recordingStateStream.listen((state) {
  // RecordingState.recording — encoding in progress
  // RecordingState.idle     — stopped; file is finalized and visible in gallery
  // RecordingState.error    — start or stop failed
});
```

The file is written to disk continuously from the moment `startRecording()` returns
(via a MediaCodec drain thread). It is marked `IS_PENDING` in MediaStore until
`stopRecording()` completes, after which it becomes visible in the gallery.

## Capture

Two capture methods are available:

```dart
// Hardware ISP JPEG (no GPU post-processing — highest quality):
final naturalPath = await camera.captureNaturalPicture();
print('Natural image saved to: $naturalPath');

// GPU post-processed frame (what the user sees on screen):
final processedPngPath = await camera.captureImage(); // PNG (default)
print('Processed PNG saved to: $processedPngPath');

final processedJpegPath = await camera.captureImage(fileName: 'shot.jpg'); // JPEG
print('Processed JPEG saved to: $processedJpegPath');
```

## Calibration

White- and black-balance calibration share one Dart API but run on different
backends per platform:

```dart
final wb = await camera.calibrateWhiteBalance();  // WbCalibrationResult
final bb = await camera.calibrateBlackBalance(params: ProcessingParams());
```

- **iOS** delegates to the CameraKit engine's single-shot gray-world
  calibration host method. The engine commits the gains/offsets internally and
  returns them in the result so the caller can re-apply via
  `WhiteBalance.manual` / `ProcessingParams.copyWith`. The `initialGain*` /
  `params` arguments are ignored on iOS — the engine starts from auto and owns
  the processing-parameters state.
- **Android** runs an iterative Dart loop (sample center patch → apply
  proportional correction → repeat) until the patch error converges.

Cross-platform implementers: the **result type is unified**, but on iOS
calibration is a single host-method round-trip while on Android it is a
multi-iteration loop driven from Dart. Don't assume the iOS `gains` came from
the same iterative process — re-apply the returned values, don't recompute.

## Error Recovery

Transient camera errors (disconnection, session failure) are handled automatically via a full teardown and re-open with exponential backoff (500ms → 8s, up to 5 retries). The `stateStream` transitions through `recovering` during this process; unrecoverable failures emit a fatal `CameraError` with `isFatal: true`.

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| `MissingPluginException` on iOS | Plugin class name mismatch or the plugin wasn't registered. Confirm `CambrianCameraPlugin` and that you ran `flutter build`/`run` (not just `pub get`) to wire SPM. |
| `cannot find type 'CameraEngine'` (Xcode) | SPM linkage is broken or the CameraKit subtree is missing. Check `ios/cambrian_camera/Package.swift` and that `ios/cambrian_camera/CameraKit/` is populated. |
| SPM resolve fails on iOS build | Host app deployment target below 26.0. Set `IPHONEOS_DEPLOYMENT_TARGET = 26.0` in every Xcode build config. |
| Blank / black preview on iOS | Known texture-bridge issue under investigation — see `docs/plans/2026-05-20-ios-texture-bridge-blank-preview-debug.md`. Host methods other than the preview lane still function. |
| `calibration_in_progress` error | An `updateSettings` or `setResolution` was called while a calibration was running. Debounce control changes in Dart while a calibration `Future` is pending. |
| Camera permission stays denied after granting | Missing `NSCameraUsageDescription` in `Info.plist`, or a stale per-bundle-ID permission cache (delete and reinstall the app to reset). |

## Cleanup

```dart
await camera.close();
```
