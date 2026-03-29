import 'package:flutter/material.dart';

import '../camera/camera_settings_values.dart';
import '../camera/camera_callbacks.dart';
import 'bottom_bar_buttons.dart';

class CameraSettingsBar extends StatelessWidget {
  final CameraSettingType? activeSetting;
  final CameraSettingsValues values;
  final CameraCallbacks callbacks;
  final VoidCallback onToggleSettings;
  final ValueChanged<CameraSettingType?> onSettingChipTap;

  const CameraSettingsBar({
    super.key,
    required this.activeSetting,
    required this.values,
    required this.callbacks,
    required this.onToggleSettings,
    required this.onSettingChipTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surfaceContainerLowest,
      child: SafeArea(
        top: false,
        left: false,
        right: false,
        bottom: true,
        // Camera Settings Bar Padding:
        // Matching the _MainActionBar padding exactly ensures both bars have the same overall height bounding box,
        // which is important for the transition stack animation to look seamless.
        // - Left/Right (48.0): Dead zone for physical tablet clamps.
        // - Top (8.0): Vertically aligns the content within the container to match the main bar.
        // - Bottom: handled by SafeArea instead of a fixed 16.0 inset.
        child: Padding(
          padding: const EdgeInsets.fromLTRB(48.0, 8.0, 48.0, 0.0),
          child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Match the position of the settings button from MainActionBar
          BottomBarActionButton(
            icon: Icons.keyboard_arrow_down,
            label: 'CLOSE',
            onTap: onToggleSettings,
          ),

          const SizedBox(width: 32),

          // Chips
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  CameraSettingChip(
                    param: CameraSettingType.iso,
                    icon: Icons.iso,
                    label: 'ISO',
                    valueLabel: values.isoValue.toString(),
                    isActive: activeSetting == CameraSettingType.iso,
                    onTap: () => onSettingChipTap(
                      activeSetting == CameraSettingType.iso
                          ? null
                          : CameraSettingType.iso,
                    ),
                  ),
                  CameraSettingChip(
                    param: CameraSettingType.shutter,
                    icon: Icons.shutter_speed,
                    label: 'SHUTTER',
                    valueLabel: _formatShutter(values.exposureTimeNs),
                    isActive: activeSetting == CameraSettingType.shutter,
                    onTap: () => onSettingChipTap(
                      activeSetting == CameraSettingType.shutter
                          ? null
                          : CameraSettingType.shutter,
                    ),
                  ),
                  CameraSettingChip(
                    param: CameraSettingType.focus,
                    icon: Icons.center_focus_strong,
                    label: 'FOCUS',
                    valueLabel: values.afEnabled
                        ? 'AUTO'
                        : '${values.focusDistance.toStringAsFixed(1)}D',
                    isActive: activeSetting == CameraSettingType.focus,
                    onTap: () => onSettingChipTap(
                      activeSetting == CameraSettingType.focus
                          ? null
                          : CameraSettingType.focus,
                    ),
                  ),
                  CameraSettingChip(
                    param: CameraSettingType.wb,
                    icon: Icons.wb_auto,
                    label: 'WB',
                    valueLabel: values.wbLocked ? 'LOCK' : 'AUTO',
                    isActive: activeSetting == CameraSettingType.wb,
                    onTap: () => onSettingChipTap(
                      activeSetting == CameraSettingType.wb
                          ? null
                          : CameraSettingType.wb,
                    ),
                  ),
                  CameraSettingChip(
                    param: CameraSettingType.zoom,
                    icon: Icons.zoom_in,
                    label: 'ZOOM',
                    valueLabel: '${values.zoomRatio.toStringAsFixed(1)}×',
                    isActive: activeSetting == CameraSettingType.zoom,
                    onTap: () => onSettingChipTap(
                      activeSetting == CameraSettingType.zoom
                          ? null
                          : CameraSettingType.zoom,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
          ),
        ),
      ),
    );
  }

  String _formatShutter(int ns) {
    final secs = ns / 1e9;
    if (secs < 1.0) return '1/${(1.0 / secs).round()}';
    return '${secs.toStringAsFixed(1)}s';
  }
}
