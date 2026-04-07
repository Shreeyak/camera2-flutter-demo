import 'package:flutter/material.dart';
import '../camera/camera_settings_values.dart';
import '../camera/camera_callbacks.dart';
import '../testing/testable.dart' show Testable;
import 'bottom_bar_buttons.dart';
import 'bottom_bar_keys.dart' show kBarCalibrate, kBarRecord, kBarSettings;
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
  final bool isRecording;
  final VoidCallback onToggleRecording;

  const _MainActionBar({
    required this.isSettingsEnabled,
    required this.onToggleSettings,
    required this.onToggleGpuControls,
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
              Testable(
                entry: kBarSettings,
                child: BottomBarActionButton(
                  icon: Icons.tune,
                  label: 'SETTINGS',
                  isDisabled: !isSettingsEnabled,
                  onTap: onToggleSettings,
                ),
              ),
              const SizedBox(width: 16),
              Testable(
                entry: kBarCalibrate,
                child: BottomBarActionButton(
                  icon: Icons.palette,
                  label: 'CALIBRATE COLOR',
                  isDisabled: false,
                  onTap: onToggleGpuControls,
                ),
              ),
              const SizedBox(width: 16),
              Testable(
                entry: kBarRecord,
                child: BottomBarActionButton(
                  icon: isRecording ? Icons.stop_circle : Icons.fiber_manual_record,
                  label: isRecording ? 'STOP' : 'RECORD',
                  isActive: isRecording,
                  isDisabled: false,
                  onTap: onToggleRecording,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
