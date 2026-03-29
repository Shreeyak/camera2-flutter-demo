import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Formatter for label rendering.
typedef DialFormatter = String Function(double value);

/// Visual and layout style for [CameraRulerDial].
///
/// Keep value/stop math in [CameraDialConfig], and appearance knobs here so
/// apps can tune one place for slider look-and-feel.
@immutable
class CameraDialStyle {
  final CameraDialLayoutStyle layout;
  final CameraDialFadeStyle fade;
  final CameraDialTickStyle ticks;
  final CameraDialLabelStyle labels;
  final CameraDialIndicatorStyle indicator;

  const CameraDialStyle({
    this.layout = const CameraDialLayoutStyle(),
    this.fade = const CameraDialFadeStyle(),
    this.ticks = const CameraDialTickStyle(),
    this.labels = const CameraDialLabelStyle(),
    this.indicator = const CameraDialIndicatorStyle(),
  });

  CameraDialStyle copyWith({
    CameraDialLayoutStyle? layout,
    CameraDialFadeStyle? fade,
    CameraDialTickStyle? ticks,
    CameraDialLabelStyle? labels,
    CameraDialIndicatorStyle? indicator,
  }) {
    return CameraDialStyle(
      layout: layout ?? this.layout,
      fade: fade ?? this.fade,
      ticks: ticks ?? this.ticks,
      labels: labels ?? this.labels,
      indicator: indicator ?? this.indicator,
    );
  }
}

@immutable
class CameraDialLayoutStyle {
  final double tickSpacing;
  final double totalHeight;
  final double tickTop;
  final double iconPad;
  final double iconInset;

  const CameraDialLayoutStyle({
    this.tickSpacing = 18.0,
    this.totalHeight = 44.0,
    this.tickTop = 24.0,
    this.iconPad = 44.0,
    this.iconInset = 12.0,
  });
}

@immutable
class CameraDialFadeStyle {
  final double fadeZoneFraction;
  final double fadeZoneMinPx;
  final double fadeZoneMaxPx;
  final double minFadeValue;

  const CameraDialFadeStyle({
    this.fadeZoneFraction = 0.3,
    this.fadeZoneMinPx = 20.0,
    this.fadeZoneMaxPx = 90.0,
    this.minFadeValue = 0.3,
  });
}

@immutable
class CameraDialTickStyle {
  final Color color;
  final double majorWidth;
  final double minorWidth;
  final double majorHeight;
  final double minorHeight;
  final double majorOpacity;
  final double minorOpacity;

  /// Fraction applied to the major tick's saturation to produce the minor
  /// tick colour. Range 0.0..1.0 (0 = fully desaturated / grey, 1 = same
  /// saturation as the major tick). Tunable so callers can adjust contrast.
  final double minorSaturationFactor;

  const CameraDialTickStyle({
    this.color = const Color(0xFFD4847A),
    this.majorWidth = 2.0,
    this.minorWidth = 1.0,
    this.majorHeight = 14.0,
    this.minorHeight = 7.0,
    this.majorOpacity = 0.85,
    this.minorOpacity = 0.45,
    this.minorSaturationFactor = 0.25,
  });

  /// Derive a desaturated minor-tick colour from [color]. Uses HSL space so
  /// we preserve hue/lightness while reducing saturation.
  Color get minorColor {
    final hsl = HSLColor.fromColor(color);
    final double s = (hsl.saturation * minorSaturationFactor).clamp(0.0, 1.0);
    return hsl.withSaturation(s).toColor();
  }
}

@immutable
class CameraDialLabelStyle {
  final double centerFontSize;
  final double sideFontSize;
  final FontWeight centerFontWeight;
  final FontWeight sideFontWeight;
  final double sideOpacity;
  final double baselineOffset;
  final double minGap;
  final int maxPerSide;
  final double cullMargin;

  const CameraDialLabelStyle({
    this.centerFontSize = 18.0,
    this.sideFontSize = 10.0,
    this.centerFontWeight = FontWeight.w600,
    this.sideFontWeight = FontWeight.normal,
    this.sideOpacity = 0.45,
    this.baselineOffset = -6.0,
    this.minGap = 18.0,
    this.maxPerSide = 2,
    this.cullMargin = 60.0,
  });
}

@immutable
class CameraDialIndicatorStyle {
  final double width;
  final double height;
  final Color color;
  final double bottomInset;

  const CameraDialIndicatorStyle({
    this.width = 6.0,
    this.height = 20.0,
    this.color = const Color(0xFFED9478),
    this.bottomInset = 3.0,
  });
}

/// Callback type for haptic feedback on tick-crossing.
typedef CameraDialHapticCallback = Future<void> Function();

/// Configuration for a camera dial (ISO / shutter / zoom / focus).
///
/// Stop arrays, major-tick cadence and formatter are provided by callers.
/// For predefined camera parameter presets, see `camera_dial_presets.dart`.
class CameraDialConfig {
  /// Discrete stops used by the dial.
  final List<double> stops;

  /// Index interval for major ticks.
  final int majorTickEvery;

  /// Optional label formatter. Falls back to [format]'s default when null.
  final DialFormatter? formatter;

  /// Left (minimum) and right (maximum) icons for the slider ends.
  final IconData leftIcon;
  final IconData rightIcon;

  /// Shared icon size for both ends (kept equal intentionally).
  final double iconSize;

  /// Appearance/layout style for the slider UI.
  final CameraDialStyle style;

  /// Haptic callback when crossing ticks.
  ///
  /// Example values at call-site:
  /// - `HapticFeedback.lightImpact`
  /// - `HapticFeedback.mediumImpact`
  /// - `HapticFeedback.heavyImpact`
  /// - `HapticFeedback.vibrate`
  /// - `null` (disabled)
  final CameraDialHapticCallback? hapticFeedback;

  const CameraDialConfig({
    required this.stops,
    this.majorTickEvery = 1,
    this.formatter,
    this.leftIcon = Icons.remove,
    this.rightIcon = Icons.add,
    this.iconSize = 20,
    this.style = const CameraDialStyle(),
    this.hapticFeedback = HapticFeedback.heavyImpact,
  });

  // ── Instance methods ──────────────────────────────────────────────────────

  int get stopCount => stops.length;

  /// Convert stop index → percent.
  double indexToPercent(int index) => index / (stopCount - 1);

  /// Convert percent → stop index.
  int percentToIndex(double percent) => (percent * (stopCount - 1)).round();

  double percentToValue(double percent) => stops[percentToIndex(percent)];

  /// Returns the stop value closest to [value].
  double closestTo(double value) =>
      stops.reduce((a, b) => (a - value).abs() < (b - value).abs() ? a : b);

  /// Default label formatting (used when [formatter] is null).
  String format(double value) {
    if (formatter != null) return formatter!(value);
    if (value >= 1) return value.toStringAsFixed(0);
    final inv = 1 / value;
    if (inv > 100000) return '1/${(inv / 1000).round()}k';
    return '1/${inv.round()}';
  }
}
