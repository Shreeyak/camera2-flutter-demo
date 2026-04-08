import 'dart:convert' show jsonEncode;
import 'dart:developer' as developer;

/// Debug-only service extension that exposes camera state as JSON.
///
/// Registered only in debug builds. Integration tests (or Dart DevTools)
/// can query `ext.test.cameraState` to verify state without parsing logcat.
///
/// Response format:
/// ```json
/// {
///   "isStreaming": true,
///   "isRecording": false,
///   "iso": 1600,
///   "exposureTimeNs": 33333333,
///   "aeSeeded": true,
///   "isoAuto": true,
///   "exposureAuto": true,
///   "afEnabled": true
/// }
/// ```
class TestChannel {
  static bool _registered = false;

  /// Registers the camera state service extension.
  ///
  /// [getState] is a callback that returns the current camera state as a Map.
  /// Safe to call multiple times — subsequent calls are ignored.
  static void register(Map<String, dynamic> Function() getState) {
    if (_registered) return;
    _registered = true;

    assert(() {
      developer.registerExtension('ext.test.cameraState', (method, params) async {
        final state = getState();
        return developer.ServiceExtensionResponse.result(jsonEncode(state));
      });
      return true;
    }());
  }
}
