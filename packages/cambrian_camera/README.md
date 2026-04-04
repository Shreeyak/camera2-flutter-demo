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
    final deg = await CambrianCamera.getDisplayRotation();
    setState(() => _displayRotationDeg = deg);
  }

  int get quarterTurns => quarterTurnsFromDisplayRotation(_displayRotationDeg);
}
```

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

## Capture

```dart
final path = await camera.takePicture();
print('Image saved to: $path');
```

## Cleanup

```dart
await camera.close();
```
