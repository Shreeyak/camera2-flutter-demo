import 'package:flutter/foundation.dart' show VoidCallback;

/// Bundled camera-action callbacks passed to camera UI widgets.
class CameraCallbacks {
  const CameraCallbacks({
    required this.onIsoChanged,
    required this.onExposureTimeNsChanged,
    required this.onFocusChanged,
    required this.onZoomChanged,
    required this.onToggleAf,
  });

  final void Function(int iso) onIsoChanged;
  final void Function(int ns) onExposureTimeNsChanged;
  final void Function(double dist) onFocusChanged;
  final void Function(double ratio) onZoomChanged;
  final VoidCallback onToggleAf;
}
