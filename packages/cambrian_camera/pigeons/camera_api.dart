// ignore_for_file: one_member_abstracts
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
  dartOut: 'lib/src/messages.g.dart',
  dartOptions: DartOptions(),
  kotlinOut:
      'android/src/main/kotlin/com/cambrian/camera/Messages.g.kt',
  kotlinOptions: KotlinOptions(package: 'com.cambrian.camera'),
  swiftOut: 'ios/Classes/Messages.g.swift',
  swiftOptions: SwiftOptions(),
  copyrightHeader: 'pigeons/copyright.txt',
))

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
}

class CamProcessingParams {
  CamProcessingParams({
    required this.blackR,
    required this.blackG,
    required this.blackB,
    required this.gamma,
    required this.histBlackPoint,
    required this.histWhitePoint,
    required this.autoStretch,
    required this.autoStretchLow,
    required this.autoStretchHigh,
    required this.brightness,
    required this.saturation,
  });

  double blackR;
  double blackG;
  double blackB;
  double gamma;
  double histBlackPoint;
  double histWhitePoint;
  bool autoStretch;
  double autoStretchLow;
  double autoStretchHigh;
  double brightness;
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
    required this.estimatedMemoryBytes,
    required this.streamWidth,
    required this.streamHeight,
    required this.rawTextureId,
  });

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
  int estimatedMemoryBytes;
  /// Width of the YUV stream used by the C++ pipeline (pixels).
  int streamWidth;
  /// Height of the YUV stream used by the C++ pipeline (pixels).
  int streamHeight;
  /// Flutter texture ID for the raw (pre-processing) preview.
  int rawTextureId;
}

class CamStateUpdate {
  CamStateUpdate({required this.state});

  /// One of: "closed", "opening", "streaming", "recovering", "error"
  String state;
}

/// Typed error codes for camera errors delivered via [CameraFlutterApi.onError].
///
/// Values are serialized as integer indices — do NOT reorder or insert in the
/// middle; only append before [unknown] to preserve wire compatibility.
enum CamErrorCode {
  cameraDevice,        // ERROR_CAMERA_DEVICE — fatal hardware failure
  cameraService,       // ERROR_CAMERA_SERVICE — camera service error
  cameraDisconnected,  // camera lost unexpectedly (system reclaim, USB)
  configurationFailed, // session configuration or rebind failed
  permissionDenied,    // CAMERA permission denied or revoked — fatal
  cameraDisabled,      // ERROR_CAMERA_DISABLED — disabled by policy — fatal
  maxCamerasInUse,     // ERROR_MAX_CAMERAS_IN_USE — too many open — fatal
  cameraInUse,         // ERROR_CAMERA_IN_USE — another app holds the camera
  cameraAccessError,   // CameraAccessException (transient access failure)
  maxRetriesExceeded,  // auto-recovery gave up after max retries — fatal
  previewSurfaceLost,  // Flutter SurfaceProducer was invalidated
  pipelineError,       // C++ processing pipeline error
  settingsConflict,    // invalid settings combination (e.g. mixed manual/auto ISO+exposure)
  unknown,             // catch-all; keep last
}

class CamError {
  CamError({
    required this.code,
    required this.message,
    required this.isFatal,
  });

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

  void setProcessingParams(int handle, CamProcessingParams params);

  @async
  String takePicture(int handle);

  @async
  int? getNativePipelineHandle(int handle);

  @async
  void close(int handle);
}

// ---------------------------------------------------------------------------
// Flutter API  (Kotlin → Dart)
// ---------------------------------------------------------------------------

@FlutterApi()
abstract class CameraFlutterApi {
  void onStateChanged(int handle, CamStateUpdate state);
  void onError(int handle, CamError error);
  void onFrameResult(int handle, CamFrameResult result);
}
