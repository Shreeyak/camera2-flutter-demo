# Cambrian Camera

A Flutter plugin for Camera2-backed camera control with C++ post-processing.

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

For device rotation, use `getDisplayRotation()` with `WidgetsBindingObserver`:

```dart
import 'package:cambrian_camera/cambrian_camera.dart' show quarterTurnsFromDisplayRotation;

class _MyState extends State<MyWidget> with WidgetsBindingObserver {
  int _displayRotationDeg = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    CambrianCamera.getDisplayRotation().then((deg) {
      setState(() => _displayRotationDeg = deg);
    });
  }

  int get quarterTurns => quarterTurnsFromDisplayRotation(_displayRotationDeg);
}
```

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

```dart
final path = await camera.takePicture();
print('Image saved to: $path');
```

## Error Recovery

Transient camera errors (disconnection, session failure) are handled automatically via a full teardown and re-open with exponential backoff (500ms → 8s, up to 5 retries). The `stateStream` transitions through `recovering` during this process; unrecoverable failures emit a fatal `CameraError` with `isFatal: true`.

## Cleanup

```dart
await camera.close();
```
