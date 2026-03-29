import 'dart:math' show max, min;

enum CameraSettingType { af, iso, shutter, focus, wb, zoom }

class CameraRanges {
  final List<int> isoRange;
  final List<int> exposureTimeRangeNs;

  /// Maximum diopter value from Camera2 LENS_INFO_MINIMUM_FOCUS_DISTANCE.
  /// Valid focus range is [0.0, minFocusDistance]; higher diopters = closer.
  final double minFocusDistance;
  final double minZoomRatio;
  final double maxZoomRatio;

  const CameraRanges({
    this.isoRange = const [100, 3200],
    this.exposureTimeRangeNs = const [1000000, 1000000000],
    this.minFocusDistance = 0.0,
    this.minZoomRatio = 1.0,
    this.maxZoomRatio = 1.0,
  });
}

class CameraSettingsValues {
  final int isoValue;
  final int exposureTimeNs;
  final double focusDistance;
  final double zoomRatio;
  final bool afEnabled;
  final bool wbLocked;

  const CameraSettingsValues({
    this.isoValue = 200,
    this.exposureTimeNs = 250000,
    this.focusDistance = 0.1,
    this.zoomRatio = 1.0,
    this.afEnabled = false,
    this.wbLocked = false,
  });

  factory CameraSettingsValues.initialFromRanges(CameraRanges ranges) {
    final clampedFocusDistance = min(0.1, ranges.minFocusDistance);
    return CameraSettingsValues(
      isoValue: max(ranges.isoRange[0], min(200, ranges.isoRange[1])),
      exposureTimeNs: max(
        ranges.exposureTimeRangeNs[0],
        min(250000, ranges.exposureTimeRangeNs[1]),
      ),
      focusDistance: clampedFocusDistance,
      zoomRatio: ranges.minZoomRatio,
      afEnabled: false,
      wbLocked: false,
    );
  }

  CameraSettingsValues copyWith({
    int? isoValue,
    int? exposureTimeNs,
    double? focusDistance,
    double? zoomRatio,
    bool? afEnabled,
    bool? wbLocked,
  }) {
    return CameraSettingsValues(
      isoValue: isoValue ?? this.isoValue,
      exposureTimeNs: exposureTimeNs ?? this.exposureTimeNs,
      focusDistance: focusDistance ?? this.focusDistance,
      zoomRatio: zoomRatio ?? this.zoomRatio,
      afEnabled: afEnabled ?? this.afEnabled,
      wbLocked: wbLocked ?? this.wbLocked,
    );
  }
}
