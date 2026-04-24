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

  /// Camera session is paused (Dart-initiated). The [CameraDevice] is still
  /// held open for fast resume. Call [CambrianCamera.resume] to restart.
  paused,

  /// Camera is fully released because the app moved to the background
  /// (process [onStop]). The device is closed so other apps can use it.
  /// The library will automatically reopen when the app returns to the
  /// foreground, or when Dart calls [CambrianCamera.resume].
  suspended,

  /// A fatal error occurred. The app must call [CambrianCamera.close] and
  /// optionally reopen the camera.
  error;

  static CameraState fromString(String s) => switch (s) {
        'closed' => closed,
        'opening' => opening,
        'streaming' => streaming,
        'recovering' => recovering,
        'paused' => paused,
        'suspended' => suspended,
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
    required this.sensorStreamWidth,
    required this.sensorStreamHeight,
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
        sensorStreamWidth: 0,
        sensorStreamHeight: 0,
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
        sensorStreamWidth: c.sensorStreamWidth,
        sensorStreamHeight: c.sensorStreamHeight,
      );

  /// All supported YUV_420_888 stream resolutions, sorted descending by area.
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

  /// Width of the camera session's YUV stream (the actual sensor output
  /// before any GPU crop). Unlike [streamWidth], this does NOT change when
  /// [CamSettings.cropOutputSize] is active — it always reports the
  /// Camera2 session's configured output dimensions.
  final int sensorStreamWidth;

  /// Height of the camera session's YUV stream. See [sensorStreamWidth].
  final int sensorStreamHeight;
}

/// Describes a GPU texture stream ready for display.
///
/// Use with Flutter's [Texture] widget:
/// ```dart
/// Texture(textureId: info.textureId)
/// ```
/// [width] and [height] are the native pixel dimensions of the texture.
/// The texture is delivered in a fixed GPU-applied orientation (rotation +
/// vertical flip, see `GpuPipeline.rotAndFlipMatrix`); no additional wrapper
/// rotation is required for the on-screen preview to match stored files.
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

/// Converts a display rotation in degrees (CW from portrait: 0, 90, 180, 270)
/// to a `RotatedBox.quarterTurns` value.
///
/// The plugin no longer exposes a `getDisplayRotation` API; obtain the degrees
/// from Flutter (`MediaQuery.orientationOf(context)`, `SystemChrome`, or your
/// own source) if you want to re-orient the GPU-delivered preview. Note that
/// the GPU pipeline already applies a fixed rotation + vertical flip to every
/// stream (see `GpuPipeline.rotAndFlipMatrix`), so preview, video, and
/// `captureImage` match one another without any `RotatedBox` wrapping. The
/// table below is retained for consumers that re-introduce
/// orientation-tracked previews using a non-flipped reference frame.
///
///   0°  (portrait)          → 1 turn  (90° CW)
///   90° (landscape-left)    → 2 turns (180°)
///   180° (reverse-portrait) → 3 turns (90° CCW)
///   270° (landscape-right)  → 0 turns
int quarterTurnsFromDisplayRotation(int displayRotationDeg) => switch (displayRotationDeg) {
  90  => 2,   // landscape-left — 180° from landscape-right GPU output
  180 => 3,   // reverse-portrait
  270 => 0,   // landscape-right — matches GPU output directly
  _   => 1,   // portrait
};
