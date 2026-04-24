import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/widgets.dart';

import 'calibration.dart'
    show
        BbCalibrationResult,
        RgbSample,
        WbCalibrationResult,
        bbError,
        bbStep,
        kBbMaxIterations,
        kBbTolerance,
        kCalibrationSettleMs,
        kWbMaxIterations,
        kWbTolerance,
        wbError,
        wbStep;
import 'camera_settings.dart';
import 'camera_settings_serializer.dart';
import 'camera_state.dart';
import 'frame_result.dart' show FrameResult;
import 'messages.g.dart';

/// The main entry point for the Cambrian camera library.
///
/// Usage:
/// ```dart
/// final camera = await CambrianCamera.open(
///   settings: CameraSettings(
///     iso: AutoValue.auto(),
///     focus: AutoValue.auto(),
///     enableRawStream: true,        // Enable dual-stream preview
///     rawStreamHeight: 720,          // Request 720p height
///   ),
/// );
/// // Listen for state changes
/// camera.stateStream.listen((state) { ... });
/// // Get preview textures (streams)
/// camera.toneMappedTexture.listen((info) { /* render processed stream */ });
/// camera.rawTexture.listen((info) { /* render raw stream */ });
/// // Adjust settings — only send what changed, omitted fields are preserved
/// camera.updateSettings(CameraSettings(iso: AutoValue.manual(400)));
/// camera.updateSettings(CameraSettings(focus: AutoValue.auto()));
/// camera.updateSettings(CameraSettings(
///   whiteBalance: WhiteBalance.manual(gainR: 1.82, gainG: 1.0, gainB: 1.45),
/// ));
/// camera.setProcessingParams(ProcessingParams(brightness: 0.2));
/// // Capture a still image
/// final path = await camera.captureNaturalPicture();
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
    required bool enableRawStream,
    CameraState initialState = CameraState.closed,
  }) : _handle = handle,
       _hostApi = hostApi,
       _capabilities = capabilities,
       _enableRawStream = enableRawStream,
       _currentState = initialState,
       _stateController = StreamController<CameraState>.broadcast(),
       _errorController = StreamController<CameraError>.broadcast(),
       _frameResultController = StreamController<FrameResult>.broadcast(),
       _recordingStateController =
           StreamController<RecordingState>.broadcast(),
       _capabilitiesController =
           StreamController<CameraCapabilities>.broadcast() {
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

  /// Whether the raw (pre-processing) GPU stream was requested via [open].
  final bool _enableRawStream;

  final CameraHostApi _hostApi;
  // Non-final: set to CameraCapabilities.empty() at construction, then updated
  // with real values from getCapabilities() before open() resolves.
  CameraCapabilities _capabilities;
  final StreamController<CameraState> _stateController;
  final StreamController<CameraError> _errorController;
  final StreamController<FrameResult> _frameResultController;
  final StreamController<RecordingState> _recordingStateController;
  final StreamController<CameraCapabilities> _capabilitiesController;
  late final CameraSettingsSerializer _serializer;

  /// The most recent camera lifecycle state. Used as [StreamBuilder.initialData]
  /// to avoid a race where the streaming event fires before the widget subscribes.
  CameraState _currentState;

  /// Whether [close] has been called on this camera instance.
  bool _closed = false;

  // ---------------------------------------------------------------------------
  // Factory
  // ---------------------------------------------------------------------------

  /// Opens the camera and returns once it is ready to stream.
  ///
  /// [cameraId] selects a specific device; pass null to use the default camera.
  /// [settings] apply initial ISP settings before streaming starts.
  ///
  /// To enable the GPU raw (passthrough) preview stream, set [CameraSettings.enableRawStream]
  /// to true in the settings. The [CameraSettings.rawStreamHeight] field controls the
  /// requested height of the raw stream; 0 uses a default.
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

    // Extract raw stream settings, defaulting to false if not specified.
    final enableRawStream = settings?.enableRawStream ?? false;

    // The handle returned by the platform is also used as the texture ID.
    final handle = await api.open(cameraId, settings?.toCam());

    // Register the instance immediately after open() so that any state/error
    // callbacks fired during the getCapabilities round-trip are not dropped.
    final camera = CambrianCamera._(
      handle: handle,
      hostApi: api,
      capabilities: CameraCapabilities.empty(), // replaced below
      enableRawStream: enableRawStream,
      initialState: CameraState.streaming,
    );

    try {
      final caps = await api.getCapabilities(handle);
      camera._capabilities = CameraCapabilities.fromPigeon(caps);
      if (kDebugMode) {
        debugPrint(
          'CC/Dart: opened handle=$handle ${caps.streamWidth}×${caps.streamHeight}',
        );
      }
      return camera;
    } catch (e) {
      if (kDebugMode) debugPrint('CC/Dart: open failed: $e');
      await camera.close();
      rethrow;
    }
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Emits a [CameraTextureInfo] each time the tone-mapped (color-processed)
  /// stream becomes ready for display.
  ///
  /// Emits the current state immediately if already streaming, then continues
  /// with future state changes. This ensures late subscribers don't miss the
  /// streaming transition event.
  Stream<CameraTextureInfo> get toneMappedTexture => _toneMappedTextureStream();

  Stream<CameraTextureInfo> _toneMappedTextureStream() async* {
    if (_currentState == CameraState.streaming) {
      yield CameraTextureInfo(
        textureId: _handle,
        width: _capabilities.streamWidth,
        height: _capabilities.streamHeight,
      );
    }
    yield* stateStream
        .where((s) => s == CameraState.streaming)
        .map(
          (_) => CameraTextureInfo(
            textureId: _handle,
            width: _capabilities.streamWidth,
            height: _capabilities.streamHeight,
          ),
        );
  }

  /// Emits a [CameraTextureInfo] each time the raw (unprocessed) stream
  /// becomes ready for display. Only emits if [enableRawStream] was true
  /// when [open] was called.
  ///
  /// Emits the current state immediately if already streaming, then continues
  /// with future state changes. This ensures late subscribers don't miss the
  /// streaming transition event.
  Stream<CameraTextureInfo> get rawTexture => _rawTextureStream();

  Stream<CameraTextureInfo> _rawTextureStream() async* {
    if (_currentState == CameraState.streaming &&
        _enableRawStream &&
        _capabilities.rawStreamTextureId != 0) {
      yield CameraTextureInfo(
        textureId: _capabilities.rawStreamTextureId,
        width: _capabilities.rawStreamWidth,
        height: _capabilities.rawStreamHeight,
      );
    }
    yield* stateStream
        .where(
          (s) =>
              s == CameraState.streaming &&
              _enableRawStream &&
              _capabilities.rawStreamTextureId != 0,
        )
        .map(
          (_) => CameraTextureInfo(
            textureId: _capabilities.rawStreamTextureId,
            width: _capabilities.rawStreamWidth,
            height: _capabilities.rawStreamHeight,
          ),
        );
  }

  /// Device capabilities (resolution list, ISO/exposure ranges, etc.).
  CameraCapabilities get capabilities => _capabilities;

  /// The most recent camera lifecycle state.
  ///
  /// Use this as [StreamBuilder.initialData] so the preview widget renders
  /// correctly when it is first built after [open] resolves.
  CameraState get state => _currentState;

  /// Whether [close] has been called on this camera instance.
  bool get isClosed => _closed;

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

  /// Broadcasts recording state changes.
  ///
  /// Emits a typed [RecordingState] value derived from the wire string sent by
  /// the platform. Unknown wire values default to [RecordingState.error].
  Stream<RecordingState> get recordingStateStream =>
      _recordingStateController.stream;

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
    if (kDebugMode)
      debugPrint('CC/Dart: updateSettings handle=$_handle $settings');
    _serializer.send(settings);
  }

  /// Changes the camera stream resolution and reconfigures the capture session.
  ///
  /// [width] and [height] must be one of the sizes in [capabilities.supportedSizes].
  /// The camera will briefly transition through [CameraState.recovering] while the
  /// session is rebuilt, then back to [CameraState.streaming].
  ///
  /// Must not be called while recording. Throws [PlatformException] on failure.
  Future<void> setResolution(int width, int height) async {
    if (_closed) return;
    if (kDebugMode) debugPrint('CC/Dart: setResolution handle=$_handle ${width}x$height');
    await _hostApi.setResolution(_handle, width, height);
    if (_closed) return;
    // Re-fetch capabilities so streamWidth/streamHeight reflect the new resolution.
    final caps = await _hostApi.getCapabilities(_handle);
    if (_closed) return;
    _capabilities = CameraCapabilities.fromPigeon(caps);
    // The Kotlin "streaming" state event fires before setResolution() returns its
    // Pigeon reply, so toneMappedTexture emits with stale capabilities. Re-emit
    // the streaming state now that _capabilities has been updated.
    if (_currentState == CameraState.streaming) {
      _stateController.add(CameraState.streaming);
    }
  }

  /// Updates C++ pipeline processing parameters immediately.
  ///
  /// The returned [Future] completes when the platform channel round-trip
  /// finishes. Callers may await it to observe channel errors, or ignore it
  /// for fire-and-forget semantics. No queuing is applied; the new parameters
  /// are picked up on the next processed frame.
  Future<void> setProcessingParams(ProcessingParams params) {
    if (kDebugMode)
      debugPrint('CC/Dart: setProcessingParams handle=$_handle $params');
    return _hostApi.setProcessingParams(_handle, params.toCam());
  }

  /// Returns processing params persisted from a previous session, or null if none exist.
  ///
  /// Call after [open] to initialize slider UI with the user's last-known values
  /// instead of overwriting persisted state with defaults.
  Future<ProcessingParams?> getPersistedProcessingParams() async {
    final cam = await _hostApi.getPersistedProcessingParams(_handle);
    if (cam == null) return null;
    return ProcessingParams(
      blackR: cam.blackR,
      blackG: cam.blackG,
      blackB: cam.blackB,
      gamma: cam.gamma,
      brightness: cam.brightness,
      contrast: cam.contrast,
      saturation: cam.saturation,
    );
  }

  /// Samples the center 96×96 pixel patch of the most recent GPU-processed frame.
  ///
  /// Returns the trimmed-mean R, G, B as [RgbSample] with values in [0.0, 1.0].
  /// The top and bottom 15% of pixel values per channel are discarded before
  /// averaging to suppress hot pixels and specular outliers.
  ///
  /// Throws [PlatformException] with code `"patch_not_ready"` if the GPU
  /// pipeline has not yet rendered a frame. Callers must not assume a fallback
  /// value — treat this as a hard error and abort any calibration in progress.
  ///
  /// Most callers should use [calibrateWhiteBalance] or [calibrateBlackBalance]
  /// instead of calling this directly.
  Future<RgbSample> sampleCenterPatch() async {
    final cam = await _hostApi.sampleCenterPatch(_handle);
    return (r: cam.r, g: cam.g, b: cam.b);
  }

  /// Runs the iterative white balance calibration loop.
  ///
  /// Samples the trimmed-mean RGB of a 96×96 pixel patch at the center of the
  /// processed frame. Takes a snapshot before any corrections ([patchBefore]) and
  /// another after convergence ([patchAfter]) — useful for before/after display in
  /// the UI. Between samples, applies proportional R/G/B gain corrections via
  /// [updateSettings] until the patch error falls below [kWbTolerance] or
  /// [kWbMaxIterations] is reached.
  ///
  /// The app does not need to call [sampleCenterPatch] directly — this method
  /// owns both patch reads and returns them in [WbCalibrationResult].
  ///
  /// [initialGainR], [initialGainG], [initialGainB] seed the first loop
  /// iteration. Pass the current AWB values from [FrameResult] when available;
  /// defaults to 1.0.
  Future<WbCalibrationResult> calibrateWhiteBalance({
    double initialGainR = 1.0,
    double initialGainG = 1.0,
    double initialGainB = 1.0,
  }) async {
    var gainR = initialGainR;
    final gainG = initialGainG;
    var gainB = initialGainB;

    // Snapshot the entry-point settings so they can be restored if the loop
    // throws before reaching the final committed updateSettings call.
    final originalSettings = CameraSettings(
      whiteBalance: WhiteBalance.manual(
        gainR: initialGainR,
        gainG: initialGainG,
        gainB: initialGainB,
      ),
    );

    final patchBefore = await sampleCenterPatch();
    var lastSample = patchBefore;

    try {
      for (var i = 0; i < kWbMaxIterations; i++) {
        if (wbError(lastSample) < kWbTolerance) break;
        final gains = wbStep((r: gainR, g: gainG, b: gainB), lastSample);
        gainR = gains.r;
        gainB = gains.b;
        await updateSettings(
          CameraSettings(
            whiteBalance: WhiteBalance.manual(
              gainR: gainR,
              gainG: gainG,
              gainB: gainB,
            ),
          ),
        );
        await Future<void>.delayed(
          const Duration(milliseconds: kCalibrationSettleMs),
        );
        lastSample = await sampleCenterPatch();
      }
    } catch (_) {
      await updateSettings(originalSettings);
      rethrow;
    }

    // Always apply final gains — handles the already-neutral case where the
    // loop exits on the first iteration without ever calling updateSettings.
    await updateSettings(
      CameraSettings(
        whiteBalance: WhiteBalance.manual(
          gainR: gainR,
          gainG: gainG,
          gainB: gainB,
        ),
      ),
    );
    final patchAfter = await sampleCenterPatch();
    return (
      gains: (r: gainR, g: gainG, b: gainB),
      patchBefore: patchBefore,
      patchAfter: patchAfter,
    );
  }

  /// Runs the iterative black balance calibration loop.
  ///
  /// Samples the trimmed-mean RGB of a 96×96 pixel patch at the center of the
  /// processed frame. Takes a snapshot before any corrections ([patchBefore]) and
  /// another after convergence ([patchAfter]) — useful for before/after display in
  /// the UI. Between samples, accumulates per-channel black-level offsets and applies
  /// them via [setProcessingParams] until the patch error falls below
  /// [kBbTolerance] or [kBbMaxIterations] is reached.
  ///
  /// The app does not need to call [sampleCenterPatch] directly — this method
  /// owns both patch reads and returns them in [BbCalibrationResult].
  ///
  /// [params] is the current [ProcessingParams]; non-black fields are preserved
  /// across each iteration's [setProcessingParams] call.
  Future<BbCalibrationResult> calibrateBlackBalance({
    required ProcessingParams params,
  }) async {
    var accR = 0.0, accG = 0.0, accB = 0.0;

    // Snapshot the caller-supplied params so the original black offsets can be
    // restored if the loop throws after partial mutations.
    final originalParams = params;

    final patchBefore = await sampleCenterPatch();
    var lastSample = patchBefore;

    try {
      for (var i = 0; i < kBbMaxIterations; i++) {
        if (bbError(lastSample) < kBbTolerance) break;
        final offsets = bbStep((r: accR, g: accG, b: accB), lastSample);
        accR = offsets.r;
        accG = offsets.g;
        accB = offsets.b;
        await setProcessingParams(
          params.copyWith(blackR: accR, blackG: accG, blackB: accB),
        );
        await Future<void>.delayed(
          const Duration(milliseconds: kCalibrationSettleMs),
        );
        lastSample = await sampleCenterPatch();
      }
    } catch (_) {
      await setProcessingParams(originalParams);
      rethrow;
    }

    final patchAfter = await sampleCenterPatch();
    return (
      offsets: (r: accR, g: accG, b: accB),
      patchBefore: patchBefore,
      patchAfter: patchAfter,
    );
  }

  /// Captures a still image using Camera2's hardware ISP and returns its file path.
  ///
  /// **Important:** This method bypasses the GPU post-processing pipeline. The resulting
  /// image reflects raw ISP output — no LUT, color transforms (saturation, contrast,
  /// brightness, black-level, gamma) or other adjustments applied by the GPU pipeline
  /// are present. Use this when you need the highest-fidelity hardware-encoded JPEG.
  ///
  /// For a post-processed image matching what the user sees on screen, use [captureImage].
  ///
  /// Uses a dedicated JPEG ImageReader pre-allocated at session setup time.
  /// Does not interrupt the streaming pipeline.
  Future<String> captureNaturalPicture() => _hostApi.captureNaturalPicture(_handle);

  /// Captures the GPU post-processed frame (what the user sees on screen) and saves to disk.
  ///
  /// Reads the next full-resolution RGBA frame from the C++ pipeline after the call
  /// (typically about one frame interval; may wait up to the native timeout),
  /// then encodes and saves it.
  ///
  /// **Format** is inferred from [fileName]'s extension:
  /// - `.jpg` / `.jpeg` → JPEG (quality 90)
  /// - `.png` or absent / unrecognised extension → PNG (lossless)
  ///
  /// **Default directory** is the app-specific Pictures folder
  /// (`getExternalFilesDir(DIRECTORY_PICTURES)`). No extra storage permissions are
  /// required on Android 13+.
  ///
  /// **EXIF metadata** (ISO, exposure time, focal length, aperture, white-balance gains,
  /// orientation, and capture timestamp) is written automatically.
  ///
  /// Returns the absolute file path of the saved image.
  Future<String> captureImage({String? outputDirectory, String? fileName}) =>
      _hostApi.captureImage(_handle, outputDirectory, fileName);

  /// Starts recording to an MP4 file. Returns (contentUri, displayName).
  ///
  /// [outputDirectory] is a MediaStore RELATIVE_PATH (e.g. "Movies/MyApp/").
  /// If null, defaults to "Movies/CambrianCamera/".
  /// [bitrate] is in bits per second (default 50 Mbps). [fps] is frame rate (default 30).
  ///
  /// Recording state changes are delivered via [recordingStateStream].
  /// Throws [PlatformException] if recording cannot be started.
  Future<(String, String)> startRecording({
    String? outputDirectory,
    String? fileName,
    int? bitrate,
    int? fps,
  }) async {
    final raw = await _hostApi.startRecording(
      _handle,
      outputDirectory,
      fileName,
      bitrate,
      fps,
    );
    // Split on the first '|' only — the display name may itself contain '|'.
    final separatorIndex = raw.indexOf('|');
    final uri = raw.substring(
      0,
      separatorIndex == -1 ? raw.length : separatorIndex,
    );
    if (kDebugMode)
      debugPrint('CC/Dart: startRecording handle=$_handle → $uri');
    if (separatorIndex == -1) return (raw, '');
    return (uri, raw.substring(separatorIndex + 1));
  }

  /// Stops recording and finalizes the MP4. Returns the content URI of the finalized file.
  ///
  /// Recording state changes are delivered via [recordingStateStream].
  /// Throws [PlatformException] if no recording is in progress.
  Future<String> stopRecording() async {
    final uri = await _hostApi.stopRecording(_handle);
    if (kDebugMode) debugPrint('CC/Dart: stopRecording handle=$_handle → $uri');
    return uri;
  }

  /// Returns the native `IImagePipeline*` pointer as an int64, or null if the
  /// pipeline is not yet initialized.
  ///
  /// Application C++ code can use this pointer to register consumer sinks
  /// via the `cambrian_camera_native.h` API.
  Future<int?> getNativePipelineHandle() =>
      _hostApi.getNativePipelineHandle(_handle);

  /// Pauses the camera: releases Camera2 resources but keeps the instance alive.
  ///
  /// Call [resume] to restart streaming with the same configuration.
  /// No-op if the camera is not currently streaming.
  Future<void> pause() async {
    if (_closed) return;
    await _hostApi.pause(_handle);
  }

  /// Resumes a paused camera. No-op if not in the paused state.
  Future<void> resume() async {
    if (_closed) return;
    await _hostApi.resume(_handle);
  }

  /// Closes the camera and releases all native resources.
  ///
  /// After this call the instance must not be used again.
  /// Safe to call multiple times; subsequent calls are no-ops.
  Future<void> close() async {
    if (_closed) return;
    if (kDebugMode) debugPrint('CC/Dart: close handle=$_handle');
    // Set before the try block intentionally: prevents concurrent/reentrant second
    // calls from reaching the native layer even if _hostApi.close() throws.
    _closed = true;
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
      await _recordingStateController.close();
      await _capabilitiesController.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Callbacks invoked by [_FlutterApiDispatcher]
  // ---------------------------------------------------------------------------

  void _onStateChanged(CamStateUpdate update) {
    _currentState = CameraState.fromString(update.state);
    if (kDebugMode) debugPrint('CC/Dart: state=$_currentState');
    _stateController.add(_currentState);
  }

  void _onError(CamError error) {
    if (kDebugMode) {
      debugPrint(
        'CC/Dart: error=${error.code} fatal=${error.isFatal}: ${error.message}',
      );
    }
    _errorController.add(CameraError.fromPigeon(error));
  }

  void _onFrameResult(CamFrameResult result) {
    _frameResultController.add(
      FrameResult(
        iso: result.iso,
        exposureTimeNs: result.exposureTimeNs,
        focusDistanceDiopters: result.focusDistanceDiopters,
        wbGainR: result.wbGainR,
        wbGainG: result.wbGainG,
        wbGainB: result.wbGainB,
      ),
    );
  }

  void _onRecordingStateChanged(String state) {
    if (kDebugMode)
      debugPrint('CC/Dart: recordingState=$state handle=$_handle');
    _recordingStateController.add(RecordingState.fromString(state));
  }

  /// Emits the latest [CameraCapabilities] whenever the effective post-GPU
  /// output dimensions change — e.g. after [updateSettings] sets a new
  /// `cropOutputSize` or after `setResolution` resolves to a new camera
  /// stream size.
  Stream<CameraCapabilities> get capabilitiesStream =>
      _capabilitiesController.stream;

  void _onCapabilitiesChanged(CamCapabilities caps) {
    final dartCaps = CameraCapabilities.fromPigeon(caps);
    _capabilities = dartCaps;
    if (kDebugMode) {
      debugPrint(
        'CC/Dart: capabilitiesChanged stream=${dartCaps.streamWidth}x${dartCaps.streamHeight}',
      );
    }
    _capabilitiesController.add(dartCaps);
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

  @override
  void onRecordingStateChanged(int handle, String state) {
    CambrianCamera._instances[handle]?._onRecordingStateChanged(state);
  }

  @override
  void onCapabilitiesChanged(int handle, CamCapabilities capabilities) {
    CambrianCamera._instances[handle]?._onCapabilitiesChanged(capabilities);
  }
}
