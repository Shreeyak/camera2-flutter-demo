import 'dart:async';

import 'package:flutter/widgets.dart';

import 'camera_settings.dart';
import 'camera_settings_serializer.dart';
import 'camera_state.dart';
import 'cambrian_camera_preview.dart';
import 'frame_result.dart' show FrameResult;
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
/// // Adjust settings — only send what changed, omitted fields are preserved
/// camera.updateSettings(CameraSettings(iso: AutoValue.manual(400)));
/// camera.updateSettings(CameraSettings(focus: AutoValue.auto()));
/// camera.updateSettings(CameraSettings(
///   whiteBalance: WhiteBalance.manual(gainR: 1.82, gainG: 1.0, gainB: 1.45),
/// ));
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
    CameraState initialState = CameraState.closed,
  }) : _handle = handle,
       _hostApi = hostApi,
       _capabilities = capabilities,
       _currentState = initialState,
       _stateController = StreamController<CameraState>.broadcast(),
       _errorController = StreamController<CameraError>.broadcast(),
       _frameResultController = StreamController<FrameResult>.broadcast() {
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

  /// All live [CambrianCamera] instances, keyed by handle.
  ///
  /// Entries are added in [CambrianCamera._] (constructor) and removed in
  /// [close]. [_FlutterApiDispatcher] uses this map to route every Kotlin→Dart
  /// callback to the correct instance by handle. The map must be empty when all
  /// cameras are closed; leaks here prevent stream controllers from being GC'd.
  static final Map<int, CambrianCamera> _instances = {};

  /// Ensures [_FlutterApiDispatcher] is registered exactly once per isolate.
  ///
  /// Pigeon's [CameraFlutterApi.setUp] binds a single handler on the binary
  /// messenger. A new Flutter isolate gets its own messenger, so this flag is
  /// isolate-local — each isolate that creates a camera registers its own
  /// dispatcher automatically on the first [open] or constructor call.
  static bool _flutterApiSetup = false;
  static void _ensureFlutterApiSetup() {
    if (_flutterApiSetup) return;
    _flutterApiSetup = true;
    CameraFlutterApi.setUp(_FlutterApiDispatcher());
  }

  // ---------------------------------------------------------------------------
  // Instance state
  // ---------------------------------------------------------------------------

  /// Opaque handle identifying this camera in platform channel calls.
  /// Also serves as the Flutter [Texture] widget's texture ID.
  final int _handle;
  final CameraHostApi _hostApi;
  // Non-final: set to CameraCapabilities.empty() at construction, then updated
  // with real values from getCapabilities() before open() resolves.
  CameraCapabilities _capabilities;
  final StreamController<CameraState> _stateController;
  final StreamController<CameraError> _errorController;
  final StreamController<FrameResult> _frameResultController;
  late final CameraSettingsSerializer _serializer;

  /// The most recent camera lifecycle state. Used as [StreamBuilder.initialData]
  /// to avoid a race where the streaming event fires before the widget subscribes.
  CameraState _currentState;

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

    // The handle returned by the platform is also used as the texture ID.
    final handle = await api.open(cameraId, settings?.toCam());

    // Register the instance immediately after open() so that any state/error
    // callbacks fired during the getCapabilities round-trip are not dropped.
    final camera = CambrianCamera._(
      handle: handle,
      hostApi: api,
      capabilities: CameraCapabilities.empty(), // replaced below
      initialState: CameraState.streaming,
    );

    try {
      final caps = await api.getCapabilities(handle);
      camera._capabilities = CameraCapabilities.fromPigeon(caps);
      return camera;
    } catch (_) {
      await camera.close();
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Flutter texture ID for the processed (post-pipeline) preview stream.
  ///
  /// Prefer [buildPreview] over constructing a [Texture] widget manually.
  int get processedStreamTextureId => _handle;

  /// Device capabilities (resolution list, ISO/exposure ranges, etc.).
  CameraCapabilities get capabilities => _capabilities;

  /// The most recent camera lifecycle state.
  ///
  /// Use this as [StreamBuilder.initialData] so the preview widget renders
  /// correctly when it is first built after [open] resolves.
  CameraState get state => _currentState;

  /// Broadcasts camera lifecycle state changes.
  ///
  /// The stream is a broadcast stream; multiple listeners are allowed.
  Stream<CameraState> get stateStream => _stateController.stream;

  /// Broadcasts camera errors.
  ///
  /// [CameraError.isFatal] == false: informational, library is recovering.
  /// [CameraError.isFatal] == true: requires [close] and possible reopen.
  Stream<CameraError> get errorStream => _errorController.stream;

  /// Broadcasts actual sensor values reported by the camera hardware.
  ///
  /// Emits approximately 3 times per second (throttled in native code to every
  /// 10th capture result). Use this to display live ISO, exposure time, focus
  /// distance, and white-balance gains in the UI.
  Stream<FrameResult> get frameResultStream => _frameResultController.stream;

  /// Schedules an ISP-level settings update.
  ///
  /// Only include the fields you want to change — `null` fields are ignored
  /// and their previous values are preserved on the Kotlin side. Auto-capable
  /// settings use sealed types: [AutoValue.auto] / [AutoValue.manual] for
  /// ISO, exposure, and focus; [WhiteBalance.auto] / [WhiteBalance.locked] /
  /// [WhiteBalance.manual] for white balance.
  ///
  /// Uses latest-value-wins: rapid calls do not pile up stale requests.
  /// The change takes effect on the next Camera2 capture request.
  Future<void> updateSettings(CameraSettings settings) async {
    _serializer.send(settings);
  }

  /// Updates C++ pipeline processing parameters immediately.
  ///
  /// The returned [Future] completes when the platform channel round-trip
  /// finishes. Callers may await it to observe channel errors, or ignore it
  /// for fire-and-forget semantics. No queuing is applied; the new parameters
  /// are picked up on the next processed frame.
  Future<void> setProcessingParams(ProcessingParams params) =>
      _hostApi.setProcessingParams(_handle, params.toCam());

  /// Captures a high-quality still image and returns its file path.
  ///
  /// Uses a dedicated JPEG ImageReader pre-allocated at session setup time.
  /// Does not interrupt the streaming pipeline.
  Future<String> takePicture() => _hostApi.takePicture(_handle);

  /// Returns the native `IImagePipeline*` pointer as an int64, or null if the
  /// pipeline is not yet initialized.
  ///
  /// Application C++ code can use this pointer to register consumer sinks
  /// via the `cambrian_camera_native.h` API.
  Future<int?> getNativePipelineHandle() =>
      _hostApi.getNativePipelineHandle(_handle);

  /// Returns a widget that displays the camera preview.
  ///
  /// Internally wraps a Flutter [Texture] widget. Shows [placeholder] while
  /// the camera is not yet streaming (e.g. during opening or recovery).
  Widget buildPreview({BoxFit fit = BoxFit.contain, Widget? placeholder}) =>
      CambrianCameraPreview(camera: this, fit: fit, placeholder: placeholder);

  /// Closes the camera and releases all native resources.
  ///
  /// After this call the instance must not be used again.
  Future<void> close() async {
    try {
      await _hostApi.close(_handle);
    } finally {
      _instances.remove(_handle);
      _serializer.dispose();
      // Close streams after removing from instances map to prevent callbacks
      // arriving after the streams are closed.
      await _stateController.close();
      await _errorController.close();
      await _frameResultController.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Callbacks invoked by [_FlutterApiDispatcher]
  // ---------------------------------------------------------------------------

  void _onStateChanged(CamStateUpdate update) {
    _currentState = CameraState.fromString(update.state);
    _stateController.add(_currentState);
  }

  void _onError(CamError error) {
    _errorController.add(CameraError.fromPigeon(error));
  }

  void _onFrameResult(CamFrameResult result) {
    _frameResultController.add(FrameResult(
      iso: result.iso,
      exposureTimeNs: result.exposureTimeNs,
      focusDistanceDiopters: result.focusDistanceDiopters,
      wbGainR: result.wbGainR,
      wbGainG: result.wbGainG,
      wbGainB: result.wbGainB,
    ));
  }
}

/// Routes Kotlin→Dart callbacks to the correct [CambrianCamera] instance.
///
/// A single [_FlutterApiDispatcher] is registered per isolate (via
/// [CambrianCamera._ensureFlutterApiSetup]). It looks up the target instance
/// in [CambrianCamera._instances] by handle and forwards the event. Callbacks
/// that arrive after [close] (handle already removed) are silently dropped —
/// this can happen if the platform fires a trailing event during teardown.
class _FlutterApiDispatcher extends CameraFlutterApi {
  @override
  void onStateChanged(int handle, CamStateUpdate state) {
    CambrianCamera._instances[handle]?._onStateChanged(state);
  }

  @override
  void onError(int handle, CamError error) {
    CambrianCamera._instances[handle]?._onError(error);
  }

  @override
  void onFrameResult(int handle, CamFrameResult result) {
    CambrianCamera._instances[handle]?._onFrameResult(result);
  }
}
