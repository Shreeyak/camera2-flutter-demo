import 'dart:async';

import 'package:flutter/widgets.dart';

import 'camera_settings.dart';
import 'camera_settings_serializer.dart';
import 'camera_state.dart';
import 'cambrian_camera_preview.dart';
import 'messages.g.dart';

/// The main entry point for the Cambrian camera library.
///
/// Usage:
/// ```dart
/// final camera = await CambrianCamera.open();
/// // Show preview
/// camera.buildPreview()
/// // Listen for state changes
/// camera.stateStream.listen((state) { ... });
/// // Adjust settings
/// camera.updateSettings(CameraSettings(iso: 400));
/// camera.setProcessingParams(ProcessingParams(brightness: 0.2));
/// // Capture a still image
/// final path = await camera.takePicture();
/// // Clean up
/// await camera.close();
/// ```
///
/// The library manages camera lifecycle automatically, including error recovery
/// with exponential backoff. The [stateStream] emits [CameraState.recovering]
/// during auto-recovery so the UI can show feedback.
class CambrianCamera {
  CambrianCamera._({
    required int handle,
    required CameraHostApi hostApi,
    required CameraCapabilities capabilities,
  })  : _handle = handle,
        _hostApi = hostApi,
        _capabilities = capabilities,
        _stateController = StreamController<CameraState>.broadcast(),
        _errorController = StreamController<CameraError>.broadcast() {
    // Register in the global instance map so FlutterApi callbacks can be
    // routed to the correct camera by handle.
    _instances[handle] = this;
    _ensureFlutterApiSetup();

    // CameraSettings use a latest-value-wins serializer because each update
    // requires a Camera2 setRepeatingRequest round-trip.
    _serializer = CameraSettingsSerializer(
      onSend: (s) => _hostApi.updateSettings(_handle, s.toCam()),
    );
  }

  // ---------------------------------------------------------------------------
  // Static state
  // ---------------------------------------------------------------------------

  /// All live camera instances, keyed by handle.
  /// Used by [_FlutterApiDispatcher] to route callbacks.
  static final Map<int, CambrianCamera> _instances = {};

  /// Ensures the FlutterApi dispatcher is registered exactly once.
  static bool _flutterApiSetup = false;
  static void _ensureFlutterApiSetup() {
    if (_flutterApiSetup) return;
    _flutterApiSetup = true;
    CameraFlutterApi.setUp(_FlutterApiDispatcher());
  }

  // ---------------------------------------------------------------------------
  // Instance state
  // ---------------------------------------------------------------------------

  /// Opaque handle identifying this camera in MethodChannel calls.
  /// Also serves as the Flutter [Texture] widget's textureId.
  final int _handle;
  final CameraHostApi _hostApi;
  final CameraCapabilities _capabilities;
  final StreamController<CameraState> _stateController;
  final StreamController<CameraError> _errorController;
  late final CameraSettingsSerializer _serializer;

  // ---------------------------------------------------------------------------
  // Factory
  // ---------------------------------------------------------------------------

  /// Opens the camera and returns once it is ready to stream.
  ///
  /// [cameraId] selects a specific device; pass null to use the default camera.
  /// [settings] apply initial ISP settings before streaming starts.
  ///
  /// Throws [PlatformException] if the camera cannot be opened (e.g. permission
  /// denied). After opening, errors are delivered via [errorStream].
  static Future<CambrianCamera> open({
    String? cameraId,
    CameraSettings? settings,
  }) async {
    final api = CameraHostApi();
    // Ensure Flutter→Dart callbacks are wired before we open.
    _ensureFlutterApiSetup();

    // The handle returned by the platform is also used as the textureId.
    final handle = await api.open(cameraId, settings?.toCam());
    final caps = await api.getCapabilities(handle);

    return CambrianCamera._(
      handle: handle,
      hostApi: api,
      capabilities: CameraCapabilities.fromPigeon(caps),
    );
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// The Flutter [Texture] widget ID for displaying the camera preview.
  ///
  /// This is the same value as the internal platform handle.
  int get textureId => _handle;

  /// Device capabilities (resolution list, ISO/exposure ranges, etc.).
  CameraCapabilities get capabilities => _capabilities;

  /// Broadcasts camera lifecycle state changes.
  ///
  /// The stream is a broadcast stream; multiple listeners are allowed.
  Stream<CameraState> get stateStream => _stateController.stream;

  /// Broadcasts camera errors.
  ///
  /// [CameraError.isFatal] == false: informational, library is recovering.
  /// [CameraError.isFatal] == true: requires [close] and possible reopen.
  Stream<CameraError> get errorStream => _errorController.stream;

  /// Schedules an ISP-level settings update.
  ///
  /// Uses latest-value-wins: rapid calls do not pile up stale requests.
  /// The change takes effect on the next Camera2 capture request.
  Future<void> updateSettings(CameraSettings settings) async {
    _serializer.send(settings);
  }

  /// Updates C++ pipeline processing parameters immediately.
  ///
  /// This is fire-and-forget: the call is non-blocking and the new parameters
  /// are picked up on the next processed frame. No queuing is applied.
  void setProcessingParams(ProcessingParams params) {
    // Direct pass-through — no serialization needed since C++ applies
    // params atomically at the start of the next frame.
    _hostApi.setProcessingParams(_handle, params.toCam());
  }

  /// Captures a high-quality still image and returns its file path.
  ///
  /// Uses a dedicated JPEG ImageReader pre-allocated at session setup time.
  /// Does not interrupt the streaming pipeline.
  Future<String> takePicture() => _hostApi.takePicture(_handle);

  /// Returns the native `IImagePipeline*` pointer as an int64.
  ///
  /// Application C++ code can use this pointer to register consumer sinks
  /// via the `cambrian_camera_native.h` API.
  Future<int> getNativePipelineHandle() =>
      _hostApi.getNativePipelineHandle(_handle);

  /// Returns a widget that displays the camera preview.
  ///
  /// Internally wraps a Flutter [Texture] widget. Shows [placeholder] while
  /// the camera is not yet streaming (e.g. during opening or recovery).
  Widget buildPreview({
    BoxFit fit = BoxFit.contain,
    Widget? placeholder,
  }) =>
      CambrianCameraPreview(
        camera: this,
        fit: fit,
        placeholder: placeholder,
      );

  /// Closes the camera and releases all native resources.
  ///
  /// After this call the instance must not be used again.
  Future<void> close() async {
    await _hostApi.close(_handle);
    _instances.remove(_handle);
    _serializer.dispose();
    // Close streams after removing from instances map to prevent callbacks
    // arriving after the streams are closed.
    await _stateController.close();
    await _errorController.close();
  }

  // ---------------------------------------------------------------------------
  // Callbacks invoked by [_FlutterApiDispatcher]
  // ---------------------------------------------------------------------------

  void _onStateChanged(CamStateUpdate update) {
    _stateController.add(CameraState.fromString(update.state));
  }

  void _onError(CamError error) {
    _errorController.add(CameraError.fromPigeon(error));
  }
}

/// Routes Kotlin→Dart callbacks to the correct [CambrianCamera] instance
/// using the handle as a key.
///
/// There is one global dispatcher (registered once) that dispatches to
/// whatever cameras are currently open.
class _FlutterApiDispatcher extends CameraFlutterApi {
  @override
  void onStateChanged(int handle, CamStateUpdate state) {
    CambrianCamera._instances[handle]?._onStateChanged(state);
  }

  @override
  void onError(int handle, CamError error) {
    CambrianCamera._instances[handle]?._onError(error);
  }
}
