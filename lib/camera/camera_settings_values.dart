import 'dart:math' show max, min;

import 'package:cambrian_camera/cambrian_camera.dart'
    show CameraSettings, Manual;

enum CameraSettingType { iso, shutter, focus, zoom }

class CameraRanges {
  final int isoMin;
  final int isoMax;
  final int exposureTimeMinNs;
  final int exposureTimeMaxNs;

  /// Maximum diopter value from Camera2 LENS_INFO_MINIMUM_FOCUS_DISTANCE.
  /// Valid focus range is [0.0, focusMaxDiopters]; higher diopters = closer focus.
  final double focusMaxDiopters;
  final double minZoomRatio;
  final double maxZoomRatio;

  const CameraRanges({
    this.isoMin = 100,
    this.isoMax = 8200,
    this.exposureTimeMinNs = 100000,
    this.exposureTimeMaxNs = 1000000000,
    this.focusMaxDiopters = 10.0,
    this.minZoomRatio = 1.0,
    this.maxZoomRatio = 20.0,
  });
}

class CameraSettingsValues {
  final int isoValue;
  final int exposureTimeNs;
  /// Focus distance in diopters. Only used when [afEnabled] is false.
  final double focusDiopters;
  final double zoomRatio;
  final bool afEnabled;

  /// When true, Camera2 auto-exposure controls ISO.
  final bool isoAuto;

  /// When true, Camera2 auto-exposure controls shutter speed.
  final bool exposureAuto;

  const CameraSettingsValues({
    this.isoValue = 200,
    this.exposureTimeNs = 250000,
    this.focusDiopters = 0.1,
    this.zoomRatio = 1.0,
    this.afEnabled = false,
    this.isoAuto = true,
    this.exposureAuto = true,
  });

  /// Builds a [CameraSettingsValues] snapshot from live [CameraSettings] and
  /// the camera's [CameraRanges]. Used to initialize UI controls when the
  /// camera starts or settings change.
  factory CameraSettingsValues.fromSettings(
    CameraSettings settings,
    CameraRanges ranges,
  ) {
    final isoAuto = settings.iso is! Manual<int>;
    final isoValue = settings.iso is Manual<int>
        ? (settings.iso as Manual<int>).value
        : max(ranges.isoMin, min(200, ranges.isoMax));

    final exposureAuto = settings.exposureTimeNs is! Manual<int>;
    final exposureTimeNs = settings.exposureTimeNs is Manual<int>
        ? (settings.exposureTimeNs as Manual<int>).value
        : max(ranges.exposureTimeMinNs, min(250000, ranges.exposureTimeMaxNs));

    final afEnabled = settings.focus is! Manual<double>;
    final focusDiopters = settings.focus is Manual<double>
        ? (settings.focus as Manual<double>).value
        : min(0.1, ranges.focusMaxDiopters);

    return CameraSettingsValues(
      isoValue: isoValue,
      exposureTimeNs: exposureTimeNs,
      focusDiopters: focusDiopters,
      zoomRatio: settings.zoomRatio ?? ranges.minZoomRatio,
      afEnabled: afEnabled,
      isoAuto: isoAuto,
      exposureAuto: exposureAuto,
    );
  }

  factory CameraSettingsValues.initialFromRanges(CameraRanges ranges) {
    return CameraSettingsValues(
      isoValue: max(ranges.isoMin, min(200, ranges.isoMax)),
      exposureTimeNs: max(ranges.exposureTimeMinNs, min(250000, ranges.exposureTimeMaxNs)),
      focusDiopters: min(0.1, ranges.focusMaxDiopters),
      zoomRatio: ranges.minZoomRatio,
      afEnabled: true,
      isoAuto: true,
      exposureAuto: true,
    );
  }

  CameraSettingsValues copyWith({
    int? isoValue,
    int? exposureTimeNs,
    double? focusDiopters,
    double? zoomRatio,
    bool? afEnabled,
    bool? isoAuto,
    bool? exposureAuto,
  }) {
    return CameraSettingsValues(
      isoValue: isoValue ?? this.isoValue,
      exposureTimeNs: exposureTimeNs ?? this.exposureTimeNs,
      focusDiopters: focusDiopters ?? this.focusDiopters,
      zoomRatio: zoomRatio ?? this.zoomRatio,
      afEnabled: afEnabled ?? this.afEnabled,
      isoAuto: isoAuto ?? this.isoAuto,
      exposureAuto: exposureAuto ?? this.exposureAuto,
    );
  }
}
