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
    this.iso,
    this.exposureTimeNs,
    this.focusDistanceDiopters,
    this.zoomRatio,
    this.afEnabled,
    this.awbLocked,
    this.noiseReductionMode,
    this.edgeMode,
    this.evCompensation,
  });

  int? iso;
  int? exposureTimeNs;
  double? focusDistanceDiopters;
  double? zoomRatio;
  bool? afEnabled;
  bool? awbLocked;
  int? noiseReductionMode;
  int? edgeMode;
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
    required this.supportsRgba8888,
    required this.estimatedMemoryBytes,
  });

  List<CamSize?> supportedSizes;
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
  bool supportsRgba8888;
  int estimatedMemoryBytes;
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
  int getNativePipelineHandle(int handle);

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
