import 'package:flutter/widgets.dart'
    show
        AsyncSnapshot,
        BoxFit,
        BuildContext,
        FittedBox,
        RotatedBox,
        SizedBox,
        State,
        StatefulWidget,
        StreamBuilder,
        Texture,
        Widget,
        WidgetsBindingObserver;

import 'cambrian_camera_controller.dart';
import 'camera_state.dart';
import 'rotation_observer_mixin.dart';

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
class CambrianCameraPreview extends StatefulWidget {
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
  State<CambrianCameraPreview> createState() => _CambrianCameraPreviewState();
}

class _CambrianCameraPreviewState extends State<CambrianCameraPreview>
    with WidgetsBindingObserver, CameraRotationObserverMixin<CambrianCameraPreview> {
  @override
  CambrianCamera get rotationCamera => widget.camera;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<CameraState>(
      stream: widget.camera.stateStream,
      initialData: widget.camera.state,
      builder: (BuildContext context, AsyncSnapshot<CameraState> snapshot) {
        if (snapshot.data == CameraState.streaming) {
          return _buildTexture();
        }
        return widget.placeholder ?? const SizedBox.expand();
      },
    );
  }

  Widget _buildTexture() {
    // FittedBox applies the [fit] to the Texture so aspect ratio is preserved
    // regardless of the widget's constraints.
    //
    // Use the actual GPU texture dimensions reported by the native side so the
    // SizedBox aspect ratio always matches the processed stream content.
    final caps = widget.camera.capabilities;
    return FittedBox(
      fit: widget.fit,
      child: RotatedBox(
        quarterTurns: quarterTurns,
        child: SizedBox(
          width: caps.streamWidth.toDouble(),
          height: caps.streamHeight.toDouble(),
          child: Texture(textureId: widget.camera.processedStreamTextureId),
        ),
      ),
    );
  }
}
