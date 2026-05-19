// ignore_for_file: one_member_abstracts
//
// Cross-platform Pigeon contract for the cambrian_camera plugin.
//
// Fields here are intended to map cleanly onto both AVFoundation (iOS) and
// Camera2 (Android). Where the platforms diverge, each per-field doc names
// the asymmetry and the platform-side conversion lives in the plugin layer
// (PigeonValueMapping.swift on iOS; CameraController.kt on Android).
//
// Platform-conditional methods (e.g. iOS-only calibration; see
// `calibrateWhiteBalance` / `calibrateBlackBalance` below) are declared
// in this shared contract; the unsupported platform's Kotlin plugin
// throws `FlutterError("not_implemented", ...)`. The Dart-side
// `CambrianCamera` controller branches on `Platform.isIOS` before
// invoking these, so the unsupported-platform throws are unreachable
// in normal use. Spec source:
// `docs/superpowers/specs/2026-05-18-phase-3-design.md` §6 (fallback
// shape — Pigeon 22's separate-file pattern produced unavoidable
// Swift-module collisions on `PigeonError` / `CamRgbSample`).
import 'package:pigeon/pigeon.dart'
    show
        ConfigurePigeon,
        PigeonOptions,
        DartOptions,
        KotlinOptions,
        SwiftOptions,
        HostApi,
        FlutterApi,
        async;

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartOptions: DartOptions(),
    kotlinOut: 'android/src/main/kotlin/com/cambrian/camera/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.cambrian.camera'),
    swiftOut: 'ios/cambrian_camera/Sources/cambrian_camera/Messages.g.swift',
    swiftOptions: SwiftOptions(),
    copyrightHeader: 'pigeons/copyright.txt',
  ),
)
// ---------------------------------------------------------------------------
// Data classes  (prefixed Cam* to avoid conflict with public API classes)
// ---------------------------------------------------------------------------
class CamSize {
  CamSize({required this.width, required this.height});
  int width;
  int height;
}

class CamSettings {
  CamSettings({
    this.isoMode,
    this.iso,
    this.exposureMode,
    this.exposureTimeNs,
    this.focusMode,
    this.focusDistanceDiopters,
    this.wbMode,
    this.wbGainR,
    this.wbGainG,
    this.wbGainB,
    this.zoomRatio,
    this.noiseReductionMode,
    this.edgeMode,
    this.evCompensation,
    this.enableNaturalStream,
    this.naturalStreamHeight,
    this.cropOutputSize,
  });

  /// "auto" | "manual" | null (don't change).
  String? isoMode;

  /// Sensor sensitivity value when isoMode == "manual".
  int? iso;

  /// "auto" | "manual" | null (don't change).
  String? exposureMode;

  /// Exposure duration in nanoseconds when exposureMode == "manual".
  int? exposureTimeNs;

  /// "auto" | "manual" | null (don't change).
  String? focusMode;

  /// Focus distance in diopters when focusMode == "manual".
  double? focusDistanceDiopters;

  /// "auto" | "locked" | "manual" | null (don't change).
  String? wbMode;

  /// Red gain multiplier when wbMode == "manual".
  double? wbGainR;

  /// Green gain multiplier when wbMode == "manual".
  double? wbGainG;

  /// Blue gain multiplier when wbMode == "manual".
  double? wbGainB;

  /// Zoom ratio (1.0 = no zoom). Null = don't change.
  double? zoomRatio;

  /// Camera2 NOISE_REDUCTION_MODE_* constant. Null = don't change.
  int? noiseReductionMode;

  /// Camera2 EDGE_MODE_* constant. Null = don't change.
  int? edgeMode;

  /// Exposure compensation in AE steps. Null = don't change.
  /// NOTE: has no effect when isoMode == "manual" or exposureMode == "manual"
  /// because CONTROL_AE_MODE is set to OFF in that case.
  int? evCompensation;

  /// Enable GPU natural (unprocessed/passthrough) stream. Null = don't change.
  bool? enableNaturalStream;

  /// Requested height of the GPU natural stream in pixels. Null = don't change. 0 = use default.
  int? naturalStreamHeight;

  /// Center-crop the GPU output to this exact pixel size.
  ///
  /// When set, the GPU fragment shader samples from the centered
  /// sub-rectangle of the configured stream, and the output FBO/PBO/preview
  /// buffers are resized to these dims. All downstream consumers — preview
  /// surface, raw stream, 480p C++ sink, `captureImage()`, video recording —
  /// receive frames at the cropped dims. The camera session stays at full
  /// sensor resolution (no Camera2 reconfigure, no `SCALER_CROP_REGION`).
  ///
  /// Null = "don't change the current crop" (matches the latest-value-wins
  /// semantics of the other CamSettings fields). To CLEAR an active crop,
  /// send `cropOutputSize` equal to the current sensor stream dims. The
  /// Kotlin side detects that output == source and removes the crop,
  /// restoring full-sensor output without a Camera2 session restart.
  /// The initial state before any crop has been set is "no crop".
  ///
  /// Constraints (enforced on the Kotlin side; caller receives
  /// `FlutterError("invalid_crop", ...)` on violation):
  ///   - `0 < width  <= streamWidth`
  ///   - `0 < height <= streamHeight`
  ///   - `width  % 2 == 0` (GPU/PBO/encoder alignment)
  ///   - `height % 2 == 0`
  ///
  /// Aspect ratio is NOT constrained: cropping a 4160×3120 stream to
  /// 1920×1080 is a valid request and produces a symmetric
  /// letterbox-style center crop.
  ///
  /// **Interaction with `zoomRatio`:** zoom and crop compose
  /// multiplicatively. The ISP delivers a zoomed full-resolution frame to
  /// the GPU, which then center-crops it. Effective zoom from the caller's
  /// perspective is approximately `zoomRatio × (streamWidth / cropWidth)`.
  ///
  /// **Interaction with `captureNaturalPicture()`:** that method
  /// intentionally ignores `cropOutputSize` and always returns the
  /// full-sensor hardware JPEG. Use `captureImage()` if you want the
  /// cropped image.
  CamSize? cropOutputSize;
}

class CamProcessingParams {
  CamProcessingParams({
    required this.blackR,
    required this.blackG,
    required this.blackB,
    required this.gamma,
    required this.brightness,
    required this.contrast,
    required this.saturation,
  });

  double blackR;
  double blackG;
  double blackB;
  double gamma;
  double brightness;
  double contrast;
  double saturation;
}

class CamCapabilities {
  CamCapabilities({
    required this.supportedSizes,
    required this.isoMin,
    required this.isoMax,
    required this.exposureTimeMinNs,
    required this.exposureTimeMaxNs,
    required this.focusMin,
    required this.focusMax,
    required this.zoomMin,
    required this.zoomMax,
    required this.evCompMin,
    required this.evCompMax,
    required this.evCompensationStep,
    required this.naturalStreamTextureId,
    required this.naturalStreamWidth,
    required this.naturalStreamHeight,
    required this.streamWidth,
    required this.streamHeight,
    required this.sensorStreamWidth,
    required this.sensorStreamHeight,
    required this.streamPixelFormat,
  });

  /// All supported YUV_420_888 stream resolutions, sorted descending by area.
  List<CamSize> supportedSizes;
  int isoMin;
  int isoMax;
  int exposureTimeMinNs;
  int exposureTimeMaxNs;
  double focusMin;
  double focusMax;
  double zoomMin;
  double zoomMax;
  int evCompMin;
  int evCompMax;
  double evCompensationStep;

  /// Flutter texture ID for the GPU natural stream (passthrough, no color adjustments).
  /// 0 if natural stream is disabled.
  int naturalStreamTextureId;

  /// Actual computed width of the GPU natural stream (pixels). 0 if natural stream is disabled.
  int naturalStreamWidth;

  /// Requested height of the GPU natural stream (pixels). 0 if natural stream is disabled.
  int naturalStreamHeight;

  /// Width of the GPU processed stream texture (pixels). Matches the largest 4:3 YUV size.
  int streamWidth;

  /// Height of the GPU processed stream texture (pixels).
  int streamHeight;

  /// Width of the camera session's YUV stream (the actual sensor output
  /// before any GPU crop). Unlike [streamWidth], this does NOT change when
  /// [CamSettings.cropOutputSize] is active — it always reports the
  /// Camera2 session's configured output size.
  int sensorStreamWidth;

  /// Height of the camera session's YUV stream. See [sensorStreamWidth].
  int sensorStreamHeight;

  /// Pixel format of the lane buffers exposed via the texture bridge.
  /// Values: "BGRA8" (iOS default + Android post-D-2P-09 swizzle),
  /// "RGBA16F" (iOS opt-out via OpenConfiguration.lanesEightBit: false),
  /// "RGBA8" (Android pre-D-2P-09 — should not be observed in shipped builds).
  /// Informational for non-Texture-widget consumers that read buffers raw.
  String streamPixelFormat;
}

/// Lean payload for the active stream-configuration change callback.
///
/// Emitted on the active selection changing (after [CameraHostApi.setResolution]
/// resolves or after [CamSettings.cropOutputSize] is set/cleared) — distinct
/// from the heavier [CamCapabilities] which is a one-time bootstrap surface
/// retrieved via [CameraHostApi.getCapabilities].
///
/// The texture-ID fields ([naturalTextureId], [previewTextureId]) are stable
/// across the open session — they are minted at [CameraHostApi.open] time and
/// carried on every change emission so a Dart consumer never needs a
/// separate getCapabilities round-trip after a configuration change.
class CamStreamConfiguration {
  CamStreamConfiguration({
    required this.captureWidth,
    required this.captureHeight,
    this.cropWidth,
    this.cropHeight,
    required this.naturalTextureId,
    required this.previewTextureId,
  });

  /// Width of the active capture stream (sensor output before any GPU crop).
  int captureWidth;

  /// Height of the active capture stream.
  int captureHeight;

  /// Width of the active GPU center crop. Null = no crop (full capture).
  int? cropWidth;

  /// Height of the active GPU center crop. Null = no crop (full capture).
  int? cropHeight;

  /// Flutter texture ID for the natural-stream lane. Stable across the open session.
  int naturalTextureId;

  /// Flutter texture ID for the processed (post-color-pipeline) preview lane.
  /// Stable across the open session.
  int previewTextureId;
}

class CamStateUpdate {
  CamStateUpdate({required this.state});

  /// One of: "closed", "opening", "streaming", "recovering", "paused", "error",
  /// "interrupted".
  ///
  /// - "paused" — pipeline gate closed (explicit `pause()` or app scenePhase
  ///   inactive); resumes on `resume()` / scenePhase active.
  /// - "interrupted" — iOS-only — AVCaptureSession was interrupted by a
  ///   routine iOS event (Control Center claim, Split View / Stage Manager
  ///   peer, phone call). Auto-resumes when the system clears the
  ///   interruption; not an error.
  /// - "error" — fatal or recoverable hardware/configuration error; see
  ///   `onError` for code + isFatal.
  ///
  /// Android never emits "interrupted" (no equivalent route on the platform).
  /// All other values are emitted on both platforms.
  String state;
}

/// Typed error codes for camera errors delivered via [CameraFlutterApi.onError].
///
/// Values are serialized as integer indices — do NOT reorder or insert in the
/// middle; only append before [unknown] to preserve wire compatibility.
enum CamErrorCode {
  cameraDevice, // ERROR_CAMERA_DEVICE — fatal hardware failure
  cameraService, // ERROR_CAMERA_SERVICE — camera service error
  cameraDisconnected, // camera lost unexpectedly (system reclaim, USB)
  configurationFailed, // session configuration or rebind failed
  permissionDenied, // CAMERA permission denied or revoked — fatal
  cameraDisabled, // ERROR_CAMERA_DISABLED — disabled by policy — fatal
  maxCamerasInUse, // ERROR_MAX_CAMERAS_IN_USE — too many open — fatal
  cameraInUse, // ERROR_CAMERA_IN_USE — another app holds the camera
  cameraAccessError, // CameraAccessException (transient access failure)
  maxRetriesExceeded, // auto-recovery gave up after max retries — fatal
  previewSurfaceLost, // Flutter SurfaceProducer was invalidated
  pipelineError, // C++ processing pipeline error
  settingsConflict, // invalid settings combination (e.g. mixed manual/auto ISO+exposure)
  frameStall, // GPU pipeline stopped receiving frames
  captureFailure, // HAL reported repeated capture failures
  fpsDegraded, // sustained FPS drop below acceptable threshold
  aeConvergenceTimeout, // auto-exposure failed to converge within timeout
  recordingTruncated, // recording stopped but EOS drain timed out — file may be truncated
  unknown, // catch-all; keep last
}

class CamError {
  CamError({required this.code, required this.message, required this.isFatal});

  CamErrorCode code;
  String message;
  bool isFatal;
}

/// Actual sensor values reported by the hardware after each captured frame.
///
/// All fields are nullable — null means the hardware did not report that value.
/// Delivered via [CameraFlutterApi.onFrameResult] at ~3 Hz (every 10th frame).
class CamFrameResult {
  CamFrameResult({
    this.iso,
    this.exposureTimeNs,
    this.focusDistanceDiopters,
    this.wbGainR,
    this.wbGainG,
    this.wbGainB,
  });

  /// Actual sensor sensitivity (ISO) used for this frame.
  int? iso;

  /// Actual exposure duration in nanoseconds used for this frame.
  int? exposureTimeNs;

  /// Actual focus distance in diopters (1/metres). 0.0 = infinity.
  double? focusDistanceDiopters;

  /// Red channel gain from COLOR_CORRECTION_GAINS.
  double? wbGainR;

  /// Green channel gain (average of greenEven + greenOdd).
  double? wbGainG;

  /// Blue channel gain from COLOR_CORRECTION_GAINS.
  double? wbGainB;
}

/// Mean R, G, B from a sampled image patch. All values in [0.0, 1.0].
class CamRgbSample {
  CamRgbSample({required this.r, required this.g, required this.b});
  double r;
  double g;
  double b;
}

/// Result of an iOS-engine calibration call ([CameraHostApi.calibrateWhiteBalance]
/// / [CameraHostApi.calibrateBlackBalance]).
///
/// Spec source: `docs/superpowers/specs/2026-05-18-phase-3-design.md`
/// §6.1 + CameraKit/DECISIONS.md D-2P-02. The four required fields
/// (`before`, `after`, `converged`, `iterations`) mirror the iOS
/// engine's `CalibrationResult`; for the Phase-2 single-shot iOS
/// algorithm `converged` is always true and `iterations` is always 1.
///
/// The six optional fields below carry the engine's *committed* values
/// so the Dart-side caller can populate the existing
/// `WbCalibrationResult.gains` / `BbCalibrationResult.offsets` records.
/// Dart consumers immediately re-apply those values to the camera
/// after calibration (see example app in
/// `lib/main.dart:_runWbCalibration` / `_runBbCalibration`), so they
/// must be the *real* committed values, not sentinels. The iOS adapter
/// reads them from `CameraEngine.currentSettingsSnapshot()` /
/// `currentProcessingParametersSnapshot()` immediately after the
/// engine's calibration call returns.
///
/// Field nullability mirrors which method produced the result:
///   - `calibrateWhiteBalance` populates `gainR/G/B`; black fields null.
///   - `calibrateBlackBalance` populates `blackR/G/B`; gain fields null.
///
/// Android does not invoke these methods — the Kotlin plugin's stubs
/// throw `FlutterError("not_implemented", ...)`. The Dart-side
/// `CambrianCamera.calibrateWhiteBalance` / `calibrateBlackBalance`
/// branches on `Platform.isIOS` before invoking, so on Android these
/// methods are unreachable.
class CamCalibrationResult {
  CamCalibrationResult({
    required this.before,
    required this.after,
    required this.converged,
    required this.iterations,
    this.gainR,
    this.gainG,
    this.gainB,
    this.blackR,
    this.blackG,
    this.blackB,
  });

  /// RGB sample of the center patch before the calibration was applied.
  CamRgbSample before;

  /// RGB sample of the center patch after the calibration was applied.
  CamRgbSample after;

  /// Whether the algorithm converged. Always true for the Phase-2 single-shot iOS path.
  bool converged;

  /// Iteration count. Always 1 for the Phase-2 single-shot iOS path.
  int iterations;

  /// WB-only — committed red-channel gain after `calibrateWhiteBalance`. Null for BB.
  double? gainR;

  /// WB-only — committed green-channel gain after `calibrateWhiteBalance`. Null for BB.
  double? gainG;

  /// WB-only — committed blue-channel gain after `calibrateWhiteBalance`. Null for BB.
  double? gainB;

  /// BB-only — committed red-channel black-level offset after `calibrateBlackBalance`. Null for WB.
  double? blackR;

  /// BB-only — committed green-channel black-level offset after `calibrateBlackBalance`. Null for WB.
  double? blackG;

  /// BB-only — committed blue-channel black-level offset after `calibrateBlackBalance`. Null for WB.
  double? blackB;
}

/// Destination for image-capture output on iOS Photos / Android MediaStore.
///
/// When [saveToLibrary] is true: iOS writes through PHPhotoLibrary and yields
/// a PHAsset local identifier (no filesystem path); Android writes through
/// MediaStore and yields a content URI / file path. When false: both
/// platforms write to filesystem at the [CameraHostApi.captureImage]
/// `outputDirectory` + `fileName` arguments and yield the filesystem path.
class CamPhotosDestination {
  CamPhotosDestination({this.albumName, required this.saveToLibrary});

  /// Optional album name on iOS Photos. Ignored on Android.
  String? albumName;

  /// If true, save to the platform photo library (Photos / MediaStore).
  /// If false, write to filesystem at the host method's outputDirectory + fileName.
  bool saveToLibrary;
}

/// Result of an image capture.
///
/// One of [filePath] / [phAssetLocalId] is non-null depending on the
/// [CamPhotosDestination.saveToLibrary] flag and platform:
/// - iOS + saveToLibrary == true: [phAssetLocalId] populated; [filePath] null.
/// - iOS + saveToLibrary == false (or null destination): [filePath] populated.
/// - Android (any destination): [filePath] populated; [phAssetLocalId] null.
class CamCaptureResult {
  CamCaptureResult({this.filePath, this.phAssetLocalId});
  String? filePath;
  String? phAssetLocalId;
}

// ---------------------------------------------------------------------------
// Host API  (Dart → Kotlin)
// ---------------------------------------------------------------------------

@HostApi()
abstract class CameraHostApi {
  @async
  int open(String? cameraId, CamSettings? settings);

  @async
  CamCapabilities getCapabilities(int handle);

  void updateSettings(int handle, CamSettings settings);

  @async
  void setResolution(int handle, int width, int height);

  void setProcessingParams(int handle, CamProcessingParams params);

  /// Captures a still JPEG image using Camera2's hardware ISP (Android) or
  /// the natural-lane tap (iOS). Does NOT include GPU post-processing
  /// (saturation, contrast, brightness, black balance, gamma).
  ///
  /// Returns a [CamCaptureResult] whose populated field depends on
  /// [destination] and platform — see [CamPhotosDestination] /
  /// [CamCaptureResult] for the per-platform semantics.
  @async
  CamCaptureResult captureNaturalPicture(
    int handle,
    String? outputDirectory,
    String? fileName,
    CamPhotosDestination? destination,
  );

  /// Captures the next GPU post-processed frame and saves it.
  /// Format is inferred from [fileName] extension: .jpg/.jpeg → JPEG (quality 90),
  /// .png or absent extension → PNG. [outputDirectory] null = system gallery
  /// under Pictures/CambrianCamera (via MediaStore on Android).
  ///
  /// Returns a [CamCaptureResult] whose populated field depends on
  /// [destination] and platform — see [CamPhotosDestination] /
  /// [CamCaptureResult] for the per-platform semantics.
  @async
  CamCaptureResult captureImage(
    int handle,
    String? outputDirectory,
    String? fileName,
    CamPhotosDestination? destination,
  );

  @async
  int? getNativePipelineHandle(int handle);

  @async
  String startRecording(
    int handle,
    String? outputDirectory,
    String? fileName,
    int? bitrate,
    int? fps,
  );

  @async
  String stopRecording(int handle);

  @async
  void close(int handle);

  @async
  void pause(int handle);

  @async
  void resume(int handle);

  /// Returns persisted processing params from a previous session, or null if none exist.
  ///
  /// Dart should call this after [open] to initialize slider UI with the user's last-known
  /// values instead of sending default zeros that would overwrite the persisted state.
  CamProcessingParams? getPersistedProcessingParams(int handle);

  /// Samples the center 96×96 pixel patch of the most recent GPU-processed
  /// RGBA frame and returns the trimmed-mean R, G, B as values in [0.0, 1.0].
  ///
  /// Throws with error code "patch_not_ready" if no frame has been rendered yet.
  @async
  CamRgbSample sampleCenterPatch(int handle);

  /// **iOS-only.** Runs the iOS engine's single-shot gray-world
  /// white-balance calibration. Wraps `CameraEngine.calibrateWhiteBalance()` —
  /// CameraKit/DECISIONS.md D-2P-03, D-2P-05, D-2P-08.
  ///
  /// On Android this throws `FlutterError("not_implemented", ...)` —
  /// the Dart-side `CambrianCamera.calibrateWhiteBalance` controller
  /// method branches on `Platform.isIOS` BEFORE invoking, so the
  /// Android stub is unreachable in normal use.
  ///
  /// Throws `PigeonError(code: "calibration_in_progress", ...)` if a
  /// calibration is already in flight. Throws
  /// `PigeonError(code: "cancelled", ...)` if the in-flight task is
  /// cancelled by a lifecycle transition (close / interrupt). Throws
  /// `PigeonError(code: "handle_not_found", ...)` if `handle` is not
  /// currently registered.
  @async
  CamCalibrationResult calibrateWhiteBalance(int handle);

  /// **iOS-only.** Runs the iOS engine's single-shot black-balance
  /// calibration. Wraps `CameraEngine.calibrateBlackBalance()` —
  /// CameraKit/DECISIONS.md D-2P-03, D-2P-05, D-2P-08.
  ///
  /// On Android this throws `FlutterError("not_implemented", ...)`.
  /// Throws the same set of `PigeonError` codes as
  /// [calibrateWhiteBalance].
  @async
  CamCalibrationResult calibrateBlackBalance(int handle);

  /// Returns the current camera permission status:
  /// "notDetermined" | "denied" | "restricted" | "authorized".
  ///
  /// Callers should query this before invoking [open] so they can present
  /// a permission rationale UI rather than discovering denial as an open
  /// failure. iOS-style four-value status; Android maps PERMISSION_GRANTED
  /// → "authorized", PERMISSION_DENIED → "denied" (or "restricted" if
  /// don't-ask-again was selected).
  @async
  String cameraPermissionStatus();

  /// Triggers the system permission prompt for camera access; returns the
  /// resulting status (same four values as [cameraPermissionStatus]).
  ///
  /// No-op (returns current status) if already authorized.
  @async
  String requestCameraPermission();

  /// Status query for Photos add-only permission (iOS) or WRITE_EXTERNAL_STORAGE
  /// (Android pre-API 29) / no-op (Android API 29+, MediaStore handles it).
  @async
  String photosAddPermissionStatus();

  /// Trigger Photos add-only permission prompt (iOS) / WRITE_EXTERNAL_STORAGE
  /// (Android pre-API 29) / no-op (Android API 29+).
  @async
  String requestPhotosAddPermission();
}

// ---------------------------------------------------------------------------
// Flutter API  (Kotlin → Dart)
// ---------------------------------------------------------------------------

@FlutterApi()
abstract class CameraFlutterApi {
  void onStateChanged(int handle, CamStateUpdate state);
  void onError(int handle, CamError error);
  void onFrameResult(int handle, CamFrameResult result);

  /// Called when the recording state changes.
  /// [state] is one of: "recording", "idle", "error".
  void onRecordingStateChanged(int handle, String state);

  /// Called when the active stream configuration changes — after
  /// `cropOutputSize` is set or cleared, or after `setResolution` resolves
  /// to a new camera stream size. The payload's texture-ID fields are
  /// stable across the open session and are repeated on every change so
  /// Dart consumers do not need a separate `getCapabilities` round-trip.
  void onStreamConfigurationChanged(int handle, CamStreamConfiguration configuration);
}
