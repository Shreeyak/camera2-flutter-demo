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
      initialData: camera.state,
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
    //
    // Use the largest supported JPEG size for natural aspect ratio.
    // supportedSizes is sorted descending by area; first entry gives the
    // correct camera stream aspect ratio for processed preview sizing.
    final size = camera.capabilities.supportedSizes.isNotEmpty
        ? camera.capabilities.supportedSizes.first
        : const CameraSize(1280, 960);
    return FittedBox(
      fit: fit,
      child: SizedBox(
        width: size.width.toDouble(),
        height: size.height.toDouble(),
        child: Texture(textureId: camera.processedStreamTextureId),
      ),
    );
  }
}
