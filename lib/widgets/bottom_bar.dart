import 'package:flutter/material.dart';
import '../camera/camera_settings_values.dart';
import '../camera/camera_callbacks.dart';
import 'bottom_bar_buttons.dart';
import 'camera_settings_bar.dart';

class BottomBar extends StatelessWidget {
  final bool isSettingsOpen;
  final CameraSettingType? activeSetting;
  final CameraSettingsValues values;
  final CameraCallbacks callbacks;
  final VoidCallback onToggleSettings;
  final ValueChanged<CameraSettingType?> onSettingChipTap;

  const BottomBar({
    super.key,
    required this.isSettingsOpen,
    required this.activeSetting,
    required this.values,
    required this.callbacks,
    required this.onToggleSettings,
    required this.onSettingChipTap,
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
                    onToggleSettings: onToggleSettings,
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

// ── Main action bar with just the SETTINGS button
class _MainActionBar extends StatelessWidget {
  final VoidCallback onToggleSettings;

  const _MainActionBar({
    required this.onToggleSettings,
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
              BottomBarActionButton(
                icon: Icons.tune,
                label: 'SETTINGS',
                onTap: onToggleSettings,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
