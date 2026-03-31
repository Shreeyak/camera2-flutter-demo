import 'camera_settings.dart';

/// Serializes [CameraSettings] updates to the platform channel.
///
/// Uses a latest-value-wins strategy: if a new value arrives while a previous
/// call is in-flight, the pending value is replaced (not queued). This ensures
/// there is no artificial latency accumulation from rapid slider scrubbing.
///
/// There is no time-based debounce — every value that is not superseded will
/// eventually be sent.
class CameraSettingsSerializer {
  CameraSettingsSerializer({required this.onSend});

  /// Callback invoked with the latest settings when a send slot is free.
  final Future<void> Function(CameraSettings) onSend;

  CameraSettings? _pending;
  bool _inFlight = false;
  bool _disposed = false;

  /// Schedules [settings] for delivery. If a call is already in-flight, the
  /// previous pending value (if any) is discarded and [settings] becomes the
  /// new pending value.
  void send(CameraSettings settings) {
    if (_disposed) return;
    if (_inFlight) {
      _pending = settings;
      return;
    }
    _dispatch(settings);
  }

  void _dispatch(CameraSettings settings) {
    _inFlight = true;
    onSend(settings).then((_) {
      if (_disposed) return;
      _inFlight = false;
      final next = _pending;
      if (next != null) {
        _pending = null;
        _dispatch(next);
      }
    }).catchError((_) {
      if (_disposed) return;
      _inFlight = false;
      // Discard the pending value so a stale setting is not sent after an error.
      // Error details are delivered via the camera error stream.
      _pending = null;
    });
  }

  /// Stops further sends. Call when the camera is closed.
  void dispose() {
    _disposed = true;
    _pending = null;
  }
}
