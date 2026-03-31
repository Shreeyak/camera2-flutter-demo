import 'package:flutter/widgets.dart';
import 'messages.g.dart';

/// Lifecycle states of the camera.
enum CameraState {
  /// Camera is not open.
  closed,

  /// Camera is initializing (opening device, configuring session).
  opening,

  /// Camera is configured and actively streaming frames.
  streaming,

  /// An error occurred; the library is attempting automatic recovery.
  /// The app may show a "reconnecting…" indicator.
  recovering,

  /// A fatal error occurred. The app must call [CambrianCamera.close] and
  /// optionally reopen the camera.
  error;

  static CameraState fromString(String s) => switch (s) {
        'closed' => closed,
        'opening' => opening,
        'streaming' => streaming,
        'recovering' => recovering,
        'error' => error,
        _ => error,
      };
}

/// Identifies the type of camera error.
///
/// Values are the Pigeon-generated [CamErrorCode] enum serialized as integer
/// indices over the wire — do NOT reorder; only append before [CamErrorCode.unknown].
typedef CameraErrorCode = CamErrorCode;

/// Describes a camera error.
///
/// Non-fatal errors ([isFatal] == false) are informational: the library is
/// recovering automatically. Fatal errors require the app to close the camera.
class CameraError {
  const CameraError({
    required this.code,
    required this.message,
    required this.isFatal,
  });

  factory CameraError.fromPigeon(CamError e) => CameraError(
        code: e.code,
        message: e.message,
        isFatal: e.isFatal,
      );

  final CameraErrorCode code;
  final String message;
  final bool isFatal;

  @override
  String toString() => 'CameraError($code, fatal=$isFatal): $message';
}

/// A camera resolution expressed as integer pixel dimensions.
@immutable
class CameraSize {
  const CameraSize(this.width, this.height);
  final int width;
  final int height;

  @override
  String toString() => '${width}x$height';
}

/// Device capabilities reported after [CambrianCamera.open].
@immutable
class CameraCapabilities {
  const CameraCapabilities({
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

  /// Empty placeholder used during the open() factory before getCapabilities completes.
  factory CameraCapabilities.empty() => const CameraCapabilities(
        supportedSizes: [],
        isoMin: 0,
        isoMax: 0,
        exposureTimeMinNs: 0,
        exposureTimeMaxNs: 0,
        focusMin: 0,
        focusMax: 0,
        zoomMin: 1,
        zoomMax: 1,
        evCompMin: 0,
        evCompMax: 0,
        evCompensationStep: 0,
        estimatedMemoryBytes: 0,
        streamWidth: 0,
        streamHeight: 0,
        rawTextureId: 0,
      );

  factory CameraCapabilities.fromPigeon(CamCapabilities c) =>
      CameraCapabilities(
        supportedSizes: c.supportedSizes
            .map((s) => CameraSize(s.width, s.height))
            .toList(),
        isoMin: c.isoMin,
        isoMax: c.isoMax,
        exposureTimeMinNs: c.exposureTimeMinNs,
        exposureTimeMaxNs: c.exposureTimeMaxNs,
        focusMin: c.focusMin,
        focusMax: c.focusMax,
        zoomMin: c.zoomMin,
        zoomMax: c.zoomMax,
        evCompMin: c.evCompMin,
        evCompMax: c.evCompMax,
        evCompensationStep: c.evCompensationStep,
        estimatedMemoryBytes: c.estimatedMemoryBytes,
        streamWidth: c.streamWidth,
        streamHeight: c.streamHeight,
        rawTextureId: c.rawTextureId,
      );

  final List<CameraSize> supportedSizes;
  final int isoMin;
  final int isoMax;
  final int exposureTimeMinNs;
  final int exposureTimeMaxNs;
  final double focusMin;
  final double focusMax;
  final double zoomMin;
  final double zoomMax;
  final int evCompMin;
  final int evCompMax;
  final double evCompensationStep;

  /// Estimated native memory usage in bytes (input ring + preview buffer).
  /// Increases as consumers are registered via the C++ API.
  final int estimatedMemoryBytes;

  /// Width of the YUV stream delivered to the C++ pipeline (pixels).
  final int streamWidth;

  /// Height of the YUV stream delivered to the C++ pipeline (pixels).
  final int streamHeight;

  /// Flutter texture ID for the raw (pre-processing) preview.
  final int rawTextureId;
}
