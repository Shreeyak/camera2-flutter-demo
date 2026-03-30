import 'package:flutter/widgets.dart';

import 'cambrian_camera_controller.dart';
import 'camera_state.dart';

/// Displays the camera preview using a Flutter [Texture] widget.
///
/// Shows [placeholder] while the camera is not yet streaming (e.g. during
/// opening, recovery, or error states). Defaults to an empty [SizedBox] if no
/// placeholder is provided.
///
/// Example:
/// ```dart
/// camera.buildPreview(
///   fit: BoxFit.cover,
///   placeholder: Center(child: CircularProgressIndicator()),
/// )
/// ```
class CambrianCameraPreview extends StatelessWidget {
  const CambrianCameraPreview({
    super.key,
    required this.camera,
    this.fit = BoxFit.contain,
    this.placeholder,
  });

  final CambrianCamera camera;

  /// How the preview image should be inscribed into the available space.
  final BoxFit fit;

  /// Widget shown while the camera is not streaming. Defaults to an empty box.
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CameraState>(
      stream: camera.stateStream,
      builder: (context, snapshot) {
        // Only show the live texture when the camera is actively streaming.
        if (snapshot.data == CameraState.streaming) {
          return _buildTexture();
        }
        return placeholder ?? const SizedBox.expand();
      },
    );
  }

  Widget _buildTexture() {
    // FittedBox applies the [fit] to the Texture so aspect ratio is preserved
    // regardless of the widget's constraints.
    return FittedBox(
      fit: fit,
      child: SizedBox(
        // Use camera resolution for correct aspect ratio.
        // Falls back to 1×1 if capabilities have no supported sizes.
        width: camera.capabilities.supportedSizes.isNotEmpty
            ? camera.capabilities.supportedSizes.first.width.toDouble()
            : 1,
        height: camera.capabilities.supportedSizes.isNotEmpty
            ? camera.capabilities.supportedSizes.first.height.toDouble()
            : 1,
        child: Texture(textureId: camera.textureId),
      ),
    );
  }
}
