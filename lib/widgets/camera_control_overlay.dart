import 'package:flutter/material.dart';

import '../camera/camera_settings_values.dart';
import '../camera/camera_callbacks.dart';
import 'camera_ruler_dial/camera_dial_presets.dart';
import 'camera_ruler_dial/camera_ruler_dial.dart';

/// Floating camera-control overlay shown above the bottom settings strip.
///
/// Renders either a [CameraRulerDial] for numeric parameters or a compact
/// WB action panel for white-balance auto/lock.
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
    if (param == CameraSettingType.wb) {
      return _WbControlPanel(
        wbLocked: values.wbLocked,
        onWbLockChanged: callbacks.onWbLockChanged,
      );
    }

    // WB is handled above; remaining params all map to a dial slider.
    final CameraDialModel model;
    switch (param) {
      case CameraSettingType.iso:
        model = IsoDialPreset(
          isoRange: ranges.isoRange,
          isoValue: values.isoValue,
          onIsoChanged: callbacks.onIsoChanged,
        ).toModel();
        break;
      case CameraSettingType.shutter:
        model = ShutterDialPreset(
          exposureTimeRangeNs: ranges.exposureTimeRangeNs,
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
          minFocusDistance: ranges.minFocusDistance,
          currentFocusDistance: values.focusDistance,
          onFocusChanged: callbacks.onFocusChanged,
        ).toModel();
        break;
      case CameraSettingType.af:
      case CameraSettingType.wb:
        // Unreachable — WB is handled by the guard at the top of build().
        return const SizedBox.shrink();
    }

    final cs = Theme.of(context).colorScheme;
    final config = model.config;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
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

class _WbControlPanel extends StatelessWidget {
  const _WbControlPanel({
    required this.wbLocked,
    required this.onWbLockChanged,
  });

  final bool wbLocked;
  final ValueChanged<bool> onWbLockChanged;

  @override
  Widget build(BuildContext context) {
    // SegmentedButton provides its own M3 visual container — no extra
    // wrapping decoration needed. Center it in the 80px overlay slot.
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SegmentedButton<bool>(
        style: ButtonStyle(
          visualDensity: VisualDensity.compact,
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return cs.secondaryContainer.withValues(alpha: 0.85);
            }
            return cs.surfaceContainerLow.withValues(alpha: 0.85);
          }),
        ),
        segments: const [
          ButtonSegment<bool>(
            value: false,
            label: Text('Auto AWB'),
            icon: Icon(Icons.wb_auto),
          ),
          ButtonSegment<bool>(
            value: true,
            label: Text('Lock WB'),
            icon: Icon(Icons.lock),
          ),
        ],
        selected: {wbLocked},
        onSelectionChanged: (Set<bool> selection) {
          onWbLockChanged(selection.first);
        },
      ),
    );
  }
}
