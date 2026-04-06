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

/// The recording state emitted by [CambrianCamera.recordingStateStream].
enum RecordingState {
  /// Recording is active.
  recording,

  /// Recording is idle (not started, or cleanly stopped).
  idle,

  /// A recording error occurred.
  error;

  /// Creates a [RecordingState] from the wire string sent by the platform.
  static RecordingState fromString(String value) => switch (value) {
        'recording' => RecordingState.recording,
        'idle' => RecordingState.idle,
        'error' => RecordingState.error,
        _ => RecordingState.error, // safe default
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
    required this.rawStreamTextureId,
    required this.rawStreamWidth,
    required this.rawStreamHeight,
    required this.streamWidth,
    required this.streamHeight,
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
        rawStreamTextureId: 0,
        rawStreamWidth: 0,
        rawStreamHeight: 0,
        streamWidth: 0,
        streamHeight: 0,
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
        rawStreamTextureId: c.rawStreamTextureId,
        rawStreamWidth: c.rawStreamWidth,
        rawStreamHeight: c.rawStreamHeight,
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

  /// Flutter texture ID for the GPU raw stream (passthrough, no color adjustments).
  /// 0 if raw stream is disabled.
  final int rawStreamTextureId;

  /// Actual computed width of the GPU raw stream (pixels). 0 if raw stream is disabled.
  final int rawStreamWidth;

  /// Requested height of the GPU raw stream (pixels). 0 if raw stream is disabled.
  final int rawStreamHeight;

  /// Width of the GPU processed stream texture (pixels). Matches the largest 4:3 YUV size.
  final int streamWidth;

  /// Height of the GPU processed stream texture (pixels).
  final int streamHeight;
}

/// Describes a GPU texture stream ready for display.
///
/// Use with Flutter's [Texture] widget:
/// ```dart
/// Texture(textureId: info.textureId)
/// ```
/// [width] and [height] are the native pixel dimensions of the texture.
/// Use [CambrianCamera.getDisplayRotation] to get the rotation needed.
@immutable
class CameraTextureInfo {
  const CameraTextureInfo({
    required this.textureId,
    required this.width,
    required this.height,
  });

  final int textureId;
  final int width;
  final int height;
}

/// Converts display rotation degrees to [RotatedBox.quarterTurns].
///
/// [displayRotationDeg] is the value returned by [CambrianCamera.getDisplayRotation]:
/// degrees clockwise from portrait: 0, 90, 180, or 270.
///
/// The GPU pipeline always outputs landscape-right frames (ROTATION_270 perspective).
/// Display rotation is clockwise from portrait, so this function accounts for the
/// difference to compute the correct number of 90° rotations:
///
///   0°  (portrait)          → 3 turns (90° CCW)
///   90° (landscape-left)    → 2 turns (180°)
///   180° (reverse-portrait) → 1 turn  (90° CW)
///   270° (landscape-right)  → 0 turns (no rotation — matches GPU output)
int quarterTurnsFromDisplayRotation(int displayRotationDeg) => switch (displayRotationDeg) {
  90  => 2,   // landscape-left (device rotated 90° CCW)
  180 => 1,   // reverse-portrait
  270 => 0,   // landscape-right (device rotated 90° CW)
  _   => 3,   // portrait
};
