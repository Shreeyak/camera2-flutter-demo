import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../camera/camera_format_utils.dart' show formatShutterNs;
import 'camera_dial_config.dart';

/// Bundles the slider config + initial value + callback for one camera param.
@immutable
class CameraDialModel {
  final CameraDialConfig config;
  final double initialValue;
  final ValueChanged<double> onChanged;

  const CameraDialModel({
    required this.config,
    required this.initialValue,
    required this.onChanged,
  });
}

/// ISO dial object for direct use by the camera UI.
@immutable
class IsoDialPreset {
  final int isoMin;
  final int isoMax;
  final int isoValue;
  final ValueChanged<int> onIsoChanged;

  const IsoDialPreset({
    required this.isoMin,
    required this.isoMax,
    required this.isoValue,
    required this.onIsoChanged,
  });

  CameraDialModel toModel() {
    // dart format off
    const all = <double>[
       50,   57,   64,   72,   80,   90,
      100,  112,  125,  141,  160,  179,
      200,  224,  250,  283,  320,  358,
      400,  447,  500,  566,  640,  716,
      800,  894, 1000, 1118, 1250, 1414,
     1600, 1789, 2000, 2236, 2500, 2828,
     3200, 3578, 4000, 4472, 5000, 5657, 6400,
    ];
    // dart format on

    final minIso = isoMin.toDouble();
    final maxIso = isoMax.toDouble();
    final stops = all.where((v) => v >= minIso && v <= maxIso).toList();

    final config = CameraDialConfig(
      stops: stops.isEmpty ? [minIso, maxIso] : stops,
      majorTickEvery: 6,
      formatter: (v) => v.round().toString(),
      leftIcon: Icons.brightness_5,
      rightIcon: Icons.brightness_7,
      iconSize: 20,
    );

    return CameraDialModel(
      config: config,
      initialValue: config.closestTo(isoValue.toDouble()),
      onChanged: (v) => onIsoChanged(v.round()),
    );
  }
}

/// Shutter dial object for direct use by the camera UI.
@immutable
class ShutterDialPreset {
  final int exposureTimeMinNs;
  final int exposureTimeMaxNs;
  final int exposureTimeNs;
  final ValueChanged<int> onExposureTimeNsChanged;

  const ShutterDialPreset({
    required this.exposureTimeMinNs,
    required this.exposureTimeMaxNs,
    required this.exposureTimeNs,
    required this.onExposureTimeNsChanged,
  });

  CameraDialModel toModel() {
    // dart format off
    const shutterSeconds = <double>[
      1/8000, 1/6400, 1/5000, 1/4000, 1/3200, 1/2500,
      1/2000, 1/1600, 1/1250, 1/1000,  1/800,  1/640,
       1/500,  1/400,  1/320,  1/250,  1/200,  1/160,
       1/125,  1/100,   1/80,   1/60,   1/50,   1/40,
        1/30,   1/25,   1/20,   1/15,
    ];
    // dart format on

    final minNs = exposureTimeMinNs.toDouble();
    final maxNs = exposureTimeMaxNs.toDouble();
    final allNs = shutterSeconds.map((s) => s * 1e9).toList();
    final stops = allNs.where((v) => v >= minNs && v <= maxNs).toList();

    final config = CameraDialConfig(
      stops: stops.isEmpty ? [minNs, maxNs] : stops,
      majorTickEvery: 3,
      formatter: formatShutterNs,
      leftIcon: Symbols.shutter_speed_add,
      rightIcon: Symbols.shutter_speed_minus,
      iconSize: 20,
    );

    return CameraDialModel(
      config: config,
      initialValue: config.closestTo(exposureTimeNs.toDouble()),
      onChanged: (v) => onExposureTimeNsChanged(v.round()),
    );
  }
}

/// Zoom dial object for direct use by the camera UI.
@immutable
class ZoomDialPreset {
  final double minZoomRatio;
  final double maxZoomRatio;
  final double currentZoomRatio;
  final ValueChanged<double> onZoomChanged;

  const ZoomDialPreset({
    required this.minZoomRatio,
    required this.maxZoomRatio,
    required this.currentZoomRatio,
    required this.onZoomChanged,
  });

  CameraDialModel toModel() {
    final double max = maxZoomRatio > minZoomRatio + 0.05
        ? maxZoomRatio
        : minZoomRatio + 1.0;
    final int firstInt = minZoomRatio.ceil();
    final int lastInt = max.floor();
    final List<double> stops = [];
    if (minZoomRatio < firstInt - 0.02) stops.add(minZoomRatio);
    for (int z = firstInt; z <= lastInt; z++) {
      stops.add(z.toDouble());
      if (z < lastInt) stops.add(z + 0.5);
    }
    if (max > lastInt + 0.02) stops.add(max);
    if (stops.length < 2) stops.add(max);

    const int majorEvery = 2;
    // Allow enough side labels for the worst case: indicator at one extreme,
    // all major ticks on the other side. Prevents in-viewport labels from
    // being silently dropped when the dial's full range fits in the viewport.
    final int maxSideLabels = ((stops.length - 1) / majorEvery).ceil();

    final config = CameraDialConfig(
      stops: stops,
      majorTickEvery: majorEvery,
      formatter: (v) {
        if ((v - v.roundToDouble()).abs() < 0.05) return '${v.round()}×';
        return '${v.toStringAsFixed(1)}×';
      },
      leftIcon: Icons.zoom_out,
      rightIcon: Icons.zoom_in,
      iconSize: 20,
      style: CameraDialStyle(
        labels: CameraDialLabelStyle(maxPerSide: maxSideLabels),
      ),
    );

    return CameraDialModel(
      config: config,
      initialValue: config.closestTo(currentZoomRatio),
      onChanged: onZoomChanged,
    );
  }
}

/// Focus dial object for direct use by the camera UI.
@immutable
class FocusDialPreset {
  final double focusMaxDiopters;
  final double currentFocusDiopters;
  final ValueChanged<double> onFocusChanged;

  const FocusDialPreset({
    required this.focusMaxDiopters,
    required this.currentFocusDiopters,
    required this.onFocusChanged,
  });

  CameraDialModel toModel() {
    final double max = focusMaxDiopters.clamp(0.0, double.infinity);
    const anchors = <double>[0.0, 0.25, 0.5, 1.0, 2.0, 3.0, 5.0, 7.0, 10.0];
    final valid = anchors.where((d) => d <= max + 0.05).toList();
    if ((valid.last - max).abs() > 0.05) valid.add(max);
    final List<double> stops = [];
    for (int i = 0; i < valid.length; i++) {
      stops.add(valid[i]);
      if (i < valid.length - 1) {
        final a = valid[i], b = valid[i + 1];
        stops.add(a + (b - a) / 3.0);
        stops.add(a + (b - a) * 2.0 / 3.0);
      }
    }

    final config = CameraDialConfig(
      stops: stops,
      majorTickEvery: 3,
      formatter: (v) {
        if (v < 0.01) return '∞';
        final metres = 1.0 / v;
        if (metres >= 100) return '∞';
        if (metres >= 1.0) return '${metres.toStringAsFixed(1)}m';
        return '${(metres * 100).round()}cm';
      },
      leftIcon: Icons.center_focus_weak,
      rightIcon: Icons.center_focus_strong,
      iconSize: 20,
    );

    return CameraDialModel(
      config: config,
      initialValue: config.closestTo(currentFocusDiopters),
      onChanged: onFocusChanged,
    );
  }
}
