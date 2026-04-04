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
    final deg = await camera.getDisplayRotation();
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

Adjust brightness, contrast, saturation, and black level:

```dart
camera.setProcessingParams(
  ProcessingParams(
    brightness: 0.2,
    contrast: 1.5,
    saturation: 1.2,
  ),
);
```

## Capture

```dart
final path = await camera.takePicture();
print('Image saved to: $path');
```

## Cleanup

```dart
await camera.close();
```
