import 'package:flutter/widgets.dart'
    show State, StatefulWidget, WidgetsBinding, WidgetsBindingObserver;

import 'cambrian_camera_controller.dart' show CambrianCamera;

/// Shared mixin for preview state classes that need to track display rotation.
///
/// Registers as a [WidgetsBindingObserver] and re-fetches the display rotation
/// on every [didChangeMetrics] call (fires for all four rotation transitions,
/// including landscape-left ↔ landscape-right which [MediaQuery.orientation]
/// cannot distinguish).
///
/// Implementors must provide [rotationCamera] returning the [CambrianCamera]
/// instance to query.
///
/// Usage:
/// ```dart
/// class _MyState extends State<MyWidget>
///     with WidgetsBindingObserver, CameraRotationObserverMixin<MyWidget> {
///   @override
///   CambrianCamera get rotationCamera => widget.camera;
/// }
/// ```
mixin CameraRotationObserverMixin<T extends StatefulWidget> on State<T>,
    WidgetsBindingObserver {
  /// The camera instance to query for display rotation.
  CambrianCamera get rotationCamera;

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

  @override
  void didChangeMetrics() {
    _fetchRotation();
  }

  Future<void> _fetchRotation() async {
    final deg = await rotationCamera.getDisplayRotation();
    if (mounted) setState(() => _displayRotationDeg = deg);
  }

  /// Maps display rotation degrees to [RotatedBox.quarterTurns].
  ///
  /// GPU pipeline always outputs landscape-right frames (ROTATION_270
  /// perspective). Display#getRotation() is CCW from natural (portrait), so:
  ///   0°  (portrait)          → 3 turns (90° CCW)
  ///   90° (landscape-left)    → 2 turns (180°)
  ///   180° (reverse-portrait) → 1 turn  (90° CW)
  ///   270° (landscape-right)  → 0 turns (no rotation — matches GPU output)
  int get quarterTurns => switch (_displayRotationDeg) {
    90  => 2,   // ROTATION_90  = landscape-left  (device rotated 90° CCW)
    180 => 1,   // ROTATION_180 = reverse-portrait
    270 => 0,   // ROTATION_270 = landscape-right (device rotated 90° CW)
    _   => 3,   // ROTATION_0   = portrait
  };
}
