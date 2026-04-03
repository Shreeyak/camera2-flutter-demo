import 'package:flutter/widgets.dart'
    show
        AsyncSnapshot,
        BoxFit,
        BuildContext,
        FittedBox,
        Key,
        RotatedBox,
        SizedBox,
        State,
        StatefulWidget,
        StreamBuilder,
        Texture,
        Widget,
        WidgetsBinding,
        WidgetsBindingObserver;

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
    with WidgetsBindingObserver {
  /// Display rotation in degrees CW from portrait: 0, 90, 180, or 270.
  int _displayRotationDeg = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetchRotation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-fetches display rotation on every metrics change (fires for all four
  /// rotation transitions, including landscape-left ↔ landscape-right which
  /// [MediaQuery.orientation] cannot distinguish).
  @override
  void didChangeMetrics() {
    _fetchRotation();
  }

  Future<void> _fetchRotation() async {
    final deg = await widget.camera.getDisplayRotation();
    if (mounted) setState(() => _displayRotationDeg = deg);
  }

  /// Maps display rotation degrees to [RotatedBox.quarterTurns].
  ///
  /// GPU pipeline always outputs landscape-right frames (ROTATION_270
  /// perspective). Display#getRotation() is CCW from natural (portrait), so:
  ///   0°  (portrait)         → 3 turns (90° CCW)
  ///   90° (landscape-left)   → 2 turns (180°)
  ///   180° (reverse-portrait)→ 1 turn  (90° CW)
  ///   270° (landscape-right) → 0 turns (no rotation — matches GPU output)
  int get _quarterTurns => switch (_displayRotationDeg) {
    90  => 2,   // ROTATION_90  = landscape-left  (device rotated 90° CCW)
    180 => 1,   // ROTATION_180 = reverse-portrait
    270 => 0,   // ROTATION_270 = landscape-right (device rotated 90° CW)
    _   => 3,   // ROTATION_0   = portrait
  };

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
    // Use the largest supported JPEG size for natural aspect ratio.
    // supportedSizes is sorted descending by area; first entry gives the
    // correct camera stream aspect ratio for processed preview sizing.
    final size = widget.camera.capabilities.supportedSizes.isNotEmpty
        ? widget.camera.capabilities.supportedSizes.first
        : const CameraSize(1280, 960);
    return FittedBox(
      fit: widget.fit,
      child: RotatedBox(
        quarterTurns: _quarterTurns,
        child: SizedBox(
          width: size.width.toDouble(),
          height: size.height.toDouble(),
          child: Texture(textureId: widget.camera.processedStreamTextureId),
        ),
      ),
    );
  }
}
