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
enum CameraErrorCode {
  /// Hardware camera device error.
  cameraDevice,

  /// Android camera service error.
  cameraService,

  /// Camera was disconnected (USB disconnect, system reclaim).
  cameraDisconnected,

  /// Camera2 session configuration failed.
  configurationFailed,

  /// Camera permission was denied or revoked. Fatal.
  permissionDenied,

  /// Camera disabled by system policy. Fatal.
  cameraDisabled,

  /// Too many cameras open in the system. Fatal.
  maxCamerasInUse,

  /// Preview surface was invalidated (Flutter surface recycled).
  previewSurfaceLost,

  /// An error in the C++ processing pipeline.
  pipelineError,

  /// Unrecognised error code.
  unknown;

  static CameraErrorCode fromString(String s) => switch (s) {
        'camera_device' => cameraDevice,
        'camera_service' => cameraService,
        'camera_disconnected' => cameraDisconnected,
        'configuration_failed' => configurationFailed,
        'permission_denied' => permissionDenied,
        'camera_disabled' => cameraDisabled,
        'max_cameras_in_use' => maxCamerasInUse,
        'preview_surface_lost' => previewSurfaceLost,
        'pipeline_error' => pipelineError,
        _ => unknown,
      };
}

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
        code: CameraErrorCode.fromString(e.code),
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
    required this.supportsRgba8888,
    required this.estimatedMemoryBytes,
    required this.streamWidth,
    required this.streamHeight,
  });

  factory CameraCapabilities.fromPigeon(CamCapabilities c) =>
      CameraCapabilities(
        supportedSizes: c.supportedSizes
            .whereType<CamSize>()
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
        supportsRgba8888: c.supportsRgba8888,
        estimatedMemoryBytes: c.estimatedMemoryBytes,
        streamWidth: c.streamWidth,
        streamHeight: c.streamHeight,
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

  /// true if the device outputs RGBA_8888 directly (no YUV conversion needed).
  final bool supportsRgba8888;

  /// Estimated native memory usage in bytes (input ring + preview buffer).
  /// Increases as consumers are registered via the C++ API.
  final int estimatedMemoryBytes;

  /// Width of the YUV stream delivered to the C++ pipeline (pixels).
  final int streamWidth;

  /// Height of the YUV stream delivered to the C++ pipeline (pixels).
  final int streamHeight;
}
