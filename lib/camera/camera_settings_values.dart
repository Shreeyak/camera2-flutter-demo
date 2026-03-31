import 'dart:math' show max, min;

import 'package:cambrian_camera/cambrian_camera.dart'
    show CameraSettings, Manual;

enum CameraSettingType { iso, shutter, focus, wb, zoom }

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

  /// Focus distance in diopters. Valid range is [0.0, minFocusDiopters].
  /// Higher diopter values indicate closer focus distance.
  final double focusDiopters;
  final double zoomRatio;
  final bool afEnabled;
  final bool wbLocked;

  /// When true, Camera2 auto-exposure controls ISO; [isoValue] is ignored.
  final bool isoAuto;

  /// When true, Camera2 auto-exposure controls shutter speed; [exposureTimeNs] is ignored.
  final bool exposureAuto;

  const CameraSettingsValues({
    this.isoValue = 200,
    this.exposureTimeNs = 250000,
    this.focusDiopters = 0.1,
    this.zoomRatio = 1.0,
    this.afEnabled = false,
    this.wbLocked = false,
    this.isoAuto = true,
    this.exposureAuto = true,
  });

  /// Constructs the initial UI state from the [CameraSettings] passed to
  /// [CambrianCamera.open] and the device capability [ranges].
  ///
  /// This keeps the open() call and the UI's initial display in sync: whatever
  /// is passed to the camera is exactly what the UI reflects.
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
      wbLocked: false,
      isoAuto: isoAuto,
      exposureAuto: exposureAuto,
    );
  }

  factory CameraSettingsValues.initialFromRanges(CameraRanges ranges) {
    final clampedFocusDiopters = min(0.1, ranges.focusMaxDiopters);
    return CameraSettingsValues(
      isoValue: max(ranges.isoMin, min(200, ranges.isoMax)),
      exposureTimeNs: max(ranges.exposureTimeMinNs, min(250000, ranges.exposureTimeMaxNs)),
      focusDiopters: clampedFocusDiopters,
      zoomRatio: ranges.minZoomRatio,
      afEnabled: true,
      wbLocked: false,
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
    bool? wbLocked,
    bool? isoAuto,
    bool? exposureAuto,
  }) {
    return CameraSettingsValues(
      isoValue: isoValue ?? this.isoValue,
      exposureTimeNs: exposureTimeNs ?? this.exposureTimeNs,
      focusDiopters: focusDiopters ?? this.focusDiopters,
      zoomRatio: zoomRatio ?? this.zoomRatio,
      afEnabled: afEnabled ?? this.afEnabled,
      wbLocked: wbLocked ?? this.wbLocked,
      isoAuto: isoAuto ?? this.isoAuto,
      exposureAuto: exposureAuto ?? this.exposureAuto,
    );
  }
}
