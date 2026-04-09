import 'package:cambrian_camera/cambrian_camera.dart' show CameraSize;
import 'package:flutter/material.dart';
import '../camera/camera_settings_values.dart';
import '../camera/camera_callbacks.dart';
import 'bottom_bar_buttons.dart';
import 'camera_settings_bar.dart';

class BottomBar extends StatelessWidget {
  final bool isSettingsOpen;
  final bool isSettingsEnabled;
  final CameraSettingType? activeSetting;
  final CameraSettingsValues values;
  final CameraCallbacks callbacks;
  final VoidCallback onToggleSettings;
  final ValueChanged<CameraSettingType?> onSettingChipTap;
  final VoidCallback onToggleGpuControls;
  final String currentResolutionLabel;
  final List<CameraSize> availableResolutions;
  final ValueChanged<CameraSize> onResolutionSelected;
  final bool isRecording;
  final VoidCallback onToggleRecording;

  const BottomBar({
    super.key,
    required this.isSettingsOpen,
    required this.isSettingsEnabled,
    required this.activeSetting,
    required this.values,
    required this.callbacks,
    required this.onToggleSettings,
    required this.onSettingChipTap,
    required this.onToggleGpuControls,
    required this.currentResolutionLabel,
    required this.availableResolutions,
    required this.onResolutionSelected,
    required this.isRecording,
    required this.onToggleRecording,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: isSettingsOpen ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOutCubicEmphasized,
      builder: (context, value, _) {
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // Main action bar layer — slides down when settings open
            ClipRect(
              child: Align(
                alignment: Alignment.topCenter,
                heightFactor: 1.0 - value,
                child: FractionalTranslation(
                  translation: Offset(0.0, value),
                  child: _MainActionBar(
                    isSettingsEnabled: isSettingsEnabled,
                    onToggleSettings: onToggleSettings,
                    onToggleGpuControls: onToggleGpuControls,
                    currentResolutionLabel: currentResolutionLabel,
                    availableResolutions: availableResolutions,
                    onResolutionSelected: onResolutionSelected,
                    isRecording: isRecording,
                    onToggleRecording: onToggleRecording,
                  ),
                ),
              ),
            ),

            // Settings bar layer — slides up when settings open
            ClipRect(
              child: Align(
                alignment: Alignment.bottomCenter,
                heightFactor: value,
                child: FractionalTranslation(
                  translation: Offset(0.0, value - 1.0),
                  child: CameraSettingsBar(
                    activeSetting: activeSetting,
                    values: values,
                    callbacks: callbacks,
                    onToggleSettings: onToggleSettings,
                    onSettingChipTap: onSettingChipTap,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ── Main action bar with SETTINGS, CALIBRATE COLOR, and RECORD buttons
class _MainActionBar extends StatelessWidget {
  final bool isSettingsEnabled;
  final VoidCallback onToggleSettings;
  final VoidCallback onToggleGpuControls;
  final String currentResolutionLabel;
  final List<CameraSize> availableResolutions;
  final ValueChanged<CameraSize> onResolutionSelected;
  final bool isRecording;
  final VoidCallback onToggleRecording;

  const _MainActionBar({
    required this.isSettingsEnabled,
    required this.onToggleSettings,
    required this.onToggleGpuControls,
    required this.currentResolutionLabel,
    required this.availableResolutions,
    required this.onResolutionSelected,
    required this.isRecording,
    required this.onToggleRecording,
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
        child: Padding(
          padding: const EdgeInsets.fromLTRB(48.0, 8.0, 48.0, 0.0),
          child: Row(
            children: [
              _ResolutionMenuButton(
                currentLabel: currentResolutionLabel,
                resolutions: availableResolutions,
                onSelected: onResolutionSelected,
              ),
              const SizedBox(width: 16),
              BottomBarActionButton(
                icon: Icons.tune,
                label: 'SETTINGS',
                isDisabled: !isSettingsEnabled,
                onTap: onToggleSettings,
              ),
              const SizedBox(width: 16),
              BottomBarActionButton(
                icon: Icons.palette,
                label: 'CALIBRATE COLOR',
                isDisabled: false,
                onTap: onToggleGpuControls,
              ),
              const SizedBox(width: 16),
              BottomBarActionButton(
                icon: isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
                label: isRecording ? 'STOP' : 'RECORD',
                isActive: isRecording,
                isDisabled: false,
                onTap: onToggleRecording,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Popup menu button that displays available stream resolutions and lets the
/// user switch between them. The current resolution is highlighted in bold.
class _ResolutionMenuButton extends StatelessWidget {
  final String currentLabel;
  final List<CameraSize> resolutions;
  final ValueChanged<CameraSize> onSelected;

  const _ResolutionMenuButton({
    required this.currentLabel,
    required this.resolutions,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = cs.onPrimaryContainer.withValues(alpha: 0.7);
    return PopupMenuButton<CameraSize>(
      onSelected: onSelected,
      itemBuilder: (context) => resolutions.map((size) {
        final label = '${size.width}x${size.height}';
        final isCurrent = label == currentLabel;
        return PopupMenuItem<CameraSize>(
          value: size,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              fontFamily: 'monospace',
              color: isCurrent ? cs.primary : null,
            ),
          ),
        );
      }).toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_size_select_large, color: color, size: 28),
            const SizedBox(height: 2),
            Text(
              currentLabel,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                color: color,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
