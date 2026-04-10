import 'package:flutter/material.dart';

import '../camera/camera_callbacks.dart';
import '../camera/camera_settings_values.dart';
import 'camera_ruler_dial/camera_dial_presets.dart';
import 'camera_ruler_dial/camera_ruler_dial.dart';

/// Maximum width of the [CameraRulerDial] in the overlay, in logical pixels.
///
/// Shared with [main.dart] so the auto-toggle button position and the dial
/// constraint never drift out of sync.
const kCameraDialMaxWidth = 400.0;

/// Floating camera-control overlay shown above the bottom settings strip.
///
/// Renders a [CameraRulerDial] for the active numeric parameter.
class CameraControlOverlay extends StatelessWidget {
  const CameraControlOverlay({
    super.key,
    required this.activeSetting,
    required this.values,
    required this.ranges,
    required this.callbacks,
  });

  final CameraSettingType? activeSetting;
  final CameraSettingsValues values;
  final CameraRanges ranges;
  final CameraCallbacks callbacks;

  @override
  Widget build(BuildContext context) {
    final param = activeSetting;
    if (param == null) return const SizedBox.shrink();

    // All params map to a dial slider.
    final CameraDialModel model;
    switch (param) {
      case CameraSettingType.iso:
        model = IsoDialPreset(
          isoMin: ranges.isoMin,
          isoMax: ranges.isoMax,
          isoValue: values.isoValue,
          onIsoChanged: callbacks.onIsoChanged,
        ).toModel();
        break;
      case CameraSettingType.shutter:
        model = ShutterDialPreset(
          exposureTimeMinNs: ranges.exposureTimeMinNs,
          exposureTimeMaxNs: ranges.exposureTimeMaxNs,
          exposureTimeNs: values.exposureTimeNs,
          onExposureTimeNsChanged: callbacks.onExposureTimeNsChanged,
        ).toModel();
        break;
      case CameraSettingType.zoom:
        model = ZoomDialPreset(
          minZoomRatio: ranges.minZoomRatio,
          maxZoomRatio: ranges.maxZoomRatio,
          currentZoomRatio: values.zoomRatio,
          onZoomChanged: callbacks.onZoomChanged,
        ).toModel();
        break;
      case CameraSettingType.focus:
        model = FocusDialPreset(
          focusMaxDiopters: ranges.focusMaxDiopters,
          currentFocusDiopters: values.focusDiopters,
          onFocusChanged: callbacks.onFocusChanged,
        ).toModel();
        break;
    }

    final cs = Theme.of(context).colorScheme;
    final config = model.config;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kCameraDialMaxWidth),
        child: CameraRulerDial(
          key: ValueKey(param),
          config: config,
          initialValue: model.initialValue,
          onChanged: model.onChanged,
          leftIcon: Icon(
            config.leftIcon,
            size: config.iconSize,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
          rightIcon: Icon(
            config.rightIcon,
            size: config.iconSize,
            color: cs.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}
