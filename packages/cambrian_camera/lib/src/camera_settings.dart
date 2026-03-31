import 'messages.g.dart';

// ---------------------------------------------------------------------------
// Auto/manual sealed types
// ---------------------------------------------------------------------------

/// Represents a camera setting that supports both automatic and manual control.
///
/// Used for settings where Camera2 can auto-manage the value (e.g. ISO,
/// exposure, focus) but the user may want to override with a specific value.
///
/// - `null` in [CameraSettings] = don't change this setting.
/// - [Auto] = let Camera2 control this setting automatically.
/// - [Manual] = use the specified value.
sealed class AutoValue<T> {
  const AutoValue();
  const factory AutoValue.auto() = Auto;
  const factory AutoValue.manual(T value) = Manual;
}

/// Let Camera2 control this setting automatically.
class Auto<T> extends AutoValue<T> {
  const Auto();
}

/// Use a specific value, overriding Camera2 auto-control.
class Manual<T> extends AutoValue<T> {
  const Manual(this.value);
  final T value;
}

// ---------------------------------------------------------------------------
// White balance sealed type
// ---------------------------------------------------------------------------

/// White balance control mode.
///
/// - `null` in [CameraSettings] = don't change white balance.
/// - [WbAuto] = Camera2 AWB algorithm runs continuously.
/// - [WbLocked] = freeze AWB at current values.
/// - [WbManual] = apply user-computed R/G/B gain multipliers, bypassing AWB.
sealed class WhiteBalance {
  const WhiteBalance();
  const factory WhiteBalance.auto() = WbAuto;
  const factory WhiteBalance.locked() = WbLocked;
  const factory WhiteBalance.manual({
    required double gainR,
    required double gainG,
    required double gainB,
  }) = WbManual;
}

/// Camera2 AWB algorithm runs continuously.
class WbAuto extends WhiteBalance {
  const WbAuto();
}

/// Freeze the current AWB gains in place.
class WbLocked extends WhiteBalance {
  const WbLocked();
}

/// Apply user-computed white balance gain multipliers, bypassing Camera2 AWB.
///
/// Gains are typically computed by selecting a neutral (grey/white) patch in
/// the image and calculating correction factors relative to the green channel.
class WbManual extends WhiteBalance {
  const WbManual({
    required this.gainR,
    required this.gainG,
    required this.gainB,
  });

  /// Red channel gain multiplier.
  final double gainR;

  /// Green channel gain multiplier (usually 1.0 as the reference channel).
  final double gainG;

  /// Blue channel gain multiplier.
  final double gainB;
}

// ---------------------------------------------------------------------------
// Camera2 mode enums
// ---------------------------------------------------------------------------

/// Camera2 `CONTROL_NOISE_REDUCTION_MODE_*` values.
/// Index matches the Camera2 integer constant directly.
enum NoiseReductionMode {
  off,           // 0
  fast,          // 1
  highQuality,   // 2
  minimal,       // 3
  zeroShutterLag, // 4
}

/// Camera2 `CONTROL_EDGE_MODE_*` values.
/// Index matches the Camera2 integer constant directly.
enum EdgeMode {
  off,           // 0
  fast,          // 1
  highQuality,   // 2
  zeroShutterLag, // 3
}

// ---------------------------------------------------------------------------
// CameraSettings
// ---------------------------------------------------------------------------

/// ISP-level camera settings mapped to Camera2 CaptureRequest keys.
///
/// All fields are nullable. `null` means "don't change this setting" — the
/// Kotlin side accumulates settings, so omitted fields retain their previous
/// value across calls.
///
/// Auto-capable settings use sealed types ([AutoValue], [WhiteBalance]) to
/// make the three states explicit:
/// - `null` = don't change
/// - auto variant = let Camera2 control it
/// - manual variant = use a specific value
///
/// Non-auto settings use plain nullable types where `null` = don't change.
///
/// ## ISO + Exposure coupling
///
/// [iso] and [exposureTimeNs] share a single Camera2 flag (`CONTROL_AE_MODE`):
///
/// - **Auto is contagious:** setting either to [Auto] propagates to the other
///   automatically on the native side. You may send only one in a call:
///   ```dart
///   // Switches both iso AND exposureTimeNs to auto:
///   camera.updateSettings(CameraSettings(iso: AutoValue.auto()));
///   ```
/// - **Manual latches from last AE values:** you only need to set one field to
///   [Manual] — the partner is automatically seeded with the last sensor value
///   that Camera2's AE algorithm was using, so brightness is continuous:
///   ```dart
///   // Only iso is set; exposureTimeNs is filled from the last AE result:
///   camera.updateSettings(CameraSettings(iso: AutoValue.manual(800)));
///   ```
///   You can still provide both explicitly if you want full control:
///   ```dart
///   camera.updateSettings(CameraSettings(
///     iso: AutoValue.manual(800),
///     exposureTimeNs: AutoValue.manual(16666666), // 1/60 s
///   ));
///   ```
///   If no capture result has arrived yet (camera just opened), single-field
///   manual is rejected with [CameraErrorCode.settingsConflict].
/// - **Auto wins over manual in a mixed update:** if one field is [Auto] and
///   the other is [Manual] in the same call, both switch to auto. This handles
///   the common UI slider case where moving the ISO slider to auto emits
///   `{iso: Auto, exposure: Manual(lastValue)}` — the stale manual value on
///   the exposure slider is correctly discarded.
///
/// Quick reference:
///
/// | Intent | Expression |
/// |---|---|
/// | Slide ISO to manual — exposure continuous | `CameraSettings(iso: AutoValue.manual(800))` |
/// | Set both to specific values | `CameraSettings(iso: AutoValue.manual(800), exposureTimeNs: AutoValue.manual(...))` |
/// | Switch back to auto | `CameraSettings(iso: AutoValue.auto())` — or either field; auto wins |
/// | Mixed (one auto, one manual) | Both go to auto — auto wins |
///
/// ## EV compensation
///
/// [evCompensation] is applied by the AE algorithm and has **no effect** when
/// either [iso] or [exposureTimeNs] is manual (AE is disabled in that mode).
class CameraSettings {
  const CameraSettings({
    this.iso,
    this.exposureTimeNs,
    this.focus,
    this.whiteBalance,
    this.zoomRatio,
    this.noiseReductionMode,
    this.edgeMode,
    this.evCompensation,
  });

  /// Sensor sensitivity (e.g. 100–3200).
  ///
  /// [Auto] = Camera2 AE controls ISO. [Manual] = fixed value.
  ///
  /// Setting this to [Auto] pulls [exposureTimeNs] to auto as well. Setting
  /// this to [Manual] latches [exposureTimeNs] from the last AE capture result
  /// if [exposureTimeNs] is not also provided. If both are provided and one is
  /// [Auto], both switch to auto.
  final AutoValue<int>? iso;

  /// Exposure duration in nanoseconds.
  ///
  /// [Auto] = Camera2 AE controls shutter speed. [Manual] = fixed value.
  ///
  /// Setting this to [Auto] pulls [iso] to auto as well. Setting this to
  /// [Manual] latches [iso] from the last AE capture result if [iso] is not
  /// also provided. If both are provided and one is [Auto], both switch to auto.
  final AutoValue<int>? exposureTimeNs;

  /// Focus distance in diopters (0 = infinity).
  /// [Auto] = continuous autofocus. [Manual] = fixed distance.
  final AutoValue<double>? focus;

  /// White balance mode.
  /// [WbAuto] = Camera2 AWB. [WbLocked] = freeze current. [WbManual] = user gains.
  final WhiteBalance? whiteBalance;

  /// Zoom ratio (1.0 = no zoom). Null = don't change.
  final double? zoomRatio;

  /// Noise reduction mode applied by Camera2. Null = don't change.
  final NoiseReductionMode? noiseReductionMode;

  /// Edge enhancement mode applied by Camera2. Null = don't change.
  final EdgeMode? edgeMode;

  /// Exposure compensation in AE steps. Null = don't change.
  ///
  /// Applied by the AE algorithm — **has no effect** when [iso] or
  /// [exposureTimeNs] is manual (AE is disabled in that mode).
  final int? evCompensation;

  /// Serializes to the Pigeon transport type.
  ///
  /// Sealed types are encoded as mode strings ("auto"/"manual"/"locked")
  /// alongside their value fields. Null fields are omitted entirely —
  /// the Kotlin side interprets missing fields as "don't change."
  CamSettings toCam() {
    // ISO
    String? isoMode;
    int? isoValue;
    switch (iso) {
      case Auto():
        isoMode = 'auto';
      case Manual(:final value):
        isoMode = 'manual';
        isoValue = value;
      case null:
        break;
    }

    // Exposure
    String? exposureMode;
    int? exposureValue;
    switch (exposureTimeNs) {
      case Auto():
        exposureMode = 'auto';
      case Manual(:final value):
        exposureMode = 'manual';
        exposureValue = value;
      case null:
        break;
    }

    // Focus
    String? focusMode;
    double? focusValue;
    switch (focus) {
      case Auto():
        focusMode = 'auto';
      case Manual(:final value):
        focusMode = 'manual';
        focusValue = value;
      case null:
        break;
    }

    // White balance
    String? wbMode;
    double? wbGainR;
    double? wbGainG;
    double? wbGainB;
    switch (whiteBalance) {
      case WbAuto():
        wbMode = 'auto';
      case WbLocked():
        wbMode = 'locked';
      case WbManual(:final gainR, :final gainG, :final gainB):
        wbMode = 'manual';
        wbGainR = gainR;
        wbGainG = gainG;
        wbGainB = gainB;
      case null:
        break;
    }

    return CamSettings(
      isoMode: isoMode,
      iso: isoValue,
      exposureMode: exposureMode,
      exposureTimeNs: exposureValue,
      focusMode: focusMode,
      focusDistanceDiopters: focusValue,
      wbMode: wbMode,
      wbGainR: wbGainR,
      wbGainG: wbGainG,
      wbGainB: wbGainB,
      zoomRatio: zoomRatio,
      noiseReductionMode: noiseReductionMode?.index,
      edgeMode: edgeMode?.index,
      evCompensation: evCompensation,
    );
  }
}

/// C++ pipeline processing parameters.
/// Applied fire-and-forget: the next frame picks up any changes.
class ProcessingParams {
  ProcessingParams({
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
  }) {
    _validate();
  }

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

  void _validate() {
    // NaN checks — all double fields must be finite numbers.
    if (blackR.isNaN) throw ArgumentError.value(blackR, 'blackR', 'must not be NaN');
    if (blackG.isNaN) throw ArgumentError.value(blackG, 'blackG', 'must not be NaN');
    if (blackB.isNaN) throw ArgumentError.value(blackB, 'blackB', 'must not be NaN');
    if (gamma.isNaN || gamma <= 0) {
      throw ArgumentError.value(gamma, 'gamma', 'must be > 0 and not NaN');
    }
    if (histBlackPoint.isNaN) {
      throw ArgumentError.value(histBlackPoint, 'histBlackPoint', 'must not be NaN');
    }
    if (histWhitePoint.isNaN) {
      throw ArgumentError.value(histWhitePoint, 'histWhitePoint', 'must not be NaN');
    }
    if (autoStretchLow.isNaN) {
      throw ArgumentError.value(autoStretchLow, 'autoStretchLow', 'must not be NaN');
    }
    if (autoStretchHigh.isNaN) {
      throw ArgumentError.value(autoStretchHigh, 'autoStretchHigh', 'must not be NaN');
    }
    if (brightness.isNaN) {
      throw ArgumentError.value(brightness, 'brightness', 'must not be NaN');
    }
    if (saturation.isNaN) {
      throw ArgumentError.value(saturation, 'saturation', 'must not be NaN');
    }
    // Range checks.
    if (histBlackPoint > histWhitePoint) {
      throw ArgumentError(
        'histBlackPoint ($histBlackPoint) must be <= histWhitePoint ($histWhitePoint)',
      );
    }
    if (autoStretch && autoStretchLow >= autoStretchHigh) {
      throw ArgumentError(
        'autoStretchLow ($autoStretchLow) must be < autoStretchHigh ($autoStretchHigh) '
        'when autoStretch is true',
      );
    }
  }

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
