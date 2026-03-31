import 'messages.g.dart';

// Private sentinel used by [CameraSettings.copyWith] to distinguish
// "caller did not pass this argument" from "caller explicitly passed null".
class _Unset {
  const _Unset();
}

const _unset = _Unset();

/// ISP-level camera settings mapped to per-request Camera2 CaptureRequest keys.
/// All fields are nullable; null means "do not change / use current value."
class CameraSettings {
  const CameraSettings({
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

  /// Sensor sensitivity (e.g. 100–3200).
  final int? iso;

  /// Exposure duration in nanoseconds.
  final int? exposureTimeNs;

  /// Focus distance in diopters (0 = infinity).
  final double? focusDistanceDiopters;

  /// Zoom ratio (1.0 = no zoom).
  final double? zoomRatio;

  /// true = continuous auto-focus; false = manual focus.
  final bool? afEnabled;

  /// true = lock auto white-balance.
  final bool? awbLocked;

  /// Camera2 CONTROL_NOISE_REDUCTION_MODE_* constant.
  final int? noiseReductionMode;

  /// Camera2 CONTROL_EDGE_MODE_* constant.
  final int? edgeMode;

  /// Exposure compensation in AE steps.
  final int? evCompensation;

  CamSettings toCam() => CamSettings(
        iso: iso,
        exposureTimeNs: exposureTimeNs,
        focusDistanceDiopters: focusDistanceDiopters,
        zoomRatio: zoomRatio,
        afEnabled: afEnabled,
        awbLocked: awbLocked,
        noiseReductionMode: noiseReductionMode,
        edgeMode: edgeMode,
        evCompensation: evCompensation,
      );

  /// Returns a copy with the given fields replaced.
  ///
  /// Pass `null` explicitly to reset a field to "auto" (unset).
  /// Omitting a parameter preserves the current value.
  ///
  /// Example — reset ISO to auto while keeping other settings:
  /// ```dart
  /// settings.copyWith(iso: null)
  /// ```
  CameraSettings copyWith({
    Object? iso = _unset,
    Object? exposureTimeNs = _unset,
    Object? focusDistanceDiopters = _unset,
    Object? zoomRatio = _unset,
    Object? afEnabled = _unset,
    Object? awbLocked = _unset,
    Object? noiseReductionMode = _unset,
    Object? edgeMode = _unset,
    Object? evCompensation = _unset,
  }) =>
      CameraSettings(
        iso: identical(iso, _unset) ? this.iso : iso as int?,
        exposureTimeNs: identical(exposureTimeNs, _unset)
            ? this.exposureTimeNs
            : exposureTimeNs as int?,
        focusDistanceDiopters: identical(focusDistanceDiopters, _unset)
            ? this.focusDistanceDiopters
            : focusDistanceDiopters as double?,
        zoomRatio:
            identical(zoomRatio, _unset) ? this.zoomRatio : zoomRatio as double?,
        afEnabled:
            identical(afEnabled, _unset) ? this.afEnabled : afEnabled as bool?,
        awbLocked:
            identical(awbLocked, _unset) ? this.awbLocked : awbLocked as bool?,
        noiseReductionMode: identical(noiseReductionMode, _unset)
            ? this.noiseReductionMode
            : noiseReductionMode as int?,
        edgeMode:
            identical(edgeMode, _unset) ? this.edgeMode : edgeMode as int?,
        evCompensation: identical(evCompensation, _unset)
            ? this.evCompensation
            : evCompensation as int?,
      );
}

/// C++ pipeline processing parameters.
/// Applied fire-and-forget: the next frame picks up any changes.
class ProcessingParams {
  const ProcessingParams({
    this.blackR = 0.0,
    this.blackG = 0.0,
    this.blackB = 0.0,
    this.gamma = 1.0,
    this.histBlackPoint = 0.0,
    this.histWhitePoint = 1.0,
    this.autoStretch = false,
    this.autoStretchLow = 0.01,
    this.autoStretchHigh = 0.99,
    this.brightness = 0.0,
    this.saturation = 1.0,
  });

  /// Per-channel black level subtraction in [0.0, 0.5].
  final double blackR;
  final double blackG;
  final double blackB;

  /// Gamma correction exponent in [0.1, 4.0]. 1.0 = identity.
  final double gamma;

  /// Manual histogram stretch: black point fraction in [0, 1].
  final double histBlackPoint;

  /// Manual histogram stretch: white point fraction in [0, 1].
  final double histWhitePoint;

  /// If true, auto-compute histogram stretch per-frame.
  final bool autoStretch;

  /// Lower percentile clip for auto-stretch (e.g. 0.01 = 1%).
  final double autoStretchLow;

  /// Upper percentile clip for auto-stretch (e.g. 0.99 = 99%).
  final double autoStretchHigh;

  /// Brightness offset in [-1.0, +1.0]. 0.0 = no change.
  final double brightness;

  /// Saturation multiplier in [0, 3]. 1.0 = identity.
  final double saturation;

  CamProcessingParams toCam() => CamProcessingParams(
        blackR: blackR,
        blackG: blackG,
        blackB: blackB,
        gamma: gamma,
        histBlackPoint: histBlackPoint,
        histWhitePoint: histWhitePoint,
        autoStretch: autoStretch,
        autoStretchLow: autoStretchLow,
        autoStretchHigh: autoStretchHigh,
        brightness: brightness,
        saturation: saturation,
      );

  ProcessingParams copyWith({
    double? blackR,
    double? blackG,
    double? blackB,
    double? gamma,
    double? histBlackPoint,
    double? histWhitePoint,
    bool? autoStretch,
    double? autoStretchLow,
    double? autoStretchHigh,
    double? brightness,
    double? saturation,
  }) =>
      ProcessingParams(
        blackR: blackR ?? this.blackR,
        blackG: blackG ?? this.blackG,
        blackB: blackB ?? this.blackB,
        gamma: gamma ?? this.gamma,
        histBlackPoint: histBlackPoint ?? this.histBlackPoint,
        histWhitePoint: histWhitePoint ?? this.histWhitePoint,
        autoStretch: autoStretch ?? this.autoStretch,
        autoStretchLow: autoStretchLow ?? this.autoStretchLow,
        autoStretchHigh: autoStretchHigh ?? this.autoStretchHigh,
        brightness: brightness ?? this.brightness,
        saturation: saturation ?? this.saturation,
      );
}
