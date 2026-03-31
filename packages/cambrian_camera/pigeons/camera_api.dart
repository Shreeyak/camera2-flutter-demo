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
}

class CamStateUpdate {
  CamStateUpdate({required this.state});

  /// One of: "closed", "opening", "streaming", "recovering", "error"
  String state;
}

class CamError {
  CamError({
    required this.code,
    required this.message,
    required this.isFatal,
  });

  String code;
  String message;
  bool isFatal;
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
}
