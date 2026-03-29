import 'package:flutter/foundation.dart' show VoidCallback;

/// Bundled camera-action callbacks passed to camera UI widgets.
///
/// This lives in the host app layer because it represents widget wiring,
/// not cross-platform camera/plugin state.
class CameraCallbacks {
  const CameraCallbacks({
    required this.onIsoChanged,
    required this.onExposureTimeNsChanged,
    required this.onFocusChanged,
    required this.onZoomChanged,
    required this.onWbLockChanged,
    required this.onToggleAf,
  });

  final void Function(int iso) onIsoChanged;
  final void Function(int ns) onExposureTimeNsChanged;
  final void Function(double dist) onFocusChanged;
  final void Function(double ratio) onZoomChanged;
  final void Function(bool locked) onWbLockChanged;
  final VoidCallback onToggleAf;
}
