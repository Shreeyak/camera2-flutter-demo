import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../camera/camera_settings_values.dart';

/// A custom vertical icon-text button used in the bottom action bars.
///
/// WHY NOT IconButton + Text?
/// If we stacked a standard Material [IconButton] and a [Text] widget, the tap
/// ripple effect would only circle the icon, leaving the text looking disconnected.
/// Additionally, the tap target wouldn't easily cover the text without extra wrappers,
/// and built-in padding constraints make tight grouping difficult. An [InkWell]
/// wrapping a [Column] solves all of this.
class BottomBarActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final bool isDisabled;
  final VoidCallback? onTap;

  const BottomBarActionButton({
    super.key,
    required this.icon,
    required this.label,
    this.isActive = false,
    this.isDisabled = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final targetColor = isDisabled
        ? cs.onSurface.withValues(alpha: 0.3)
        : isActive
        ? cs.primary
        : cs.onPrimaryContainer.withValues(alpha: 0.7);

    return InkWell(
      onTap: isDisabled ? null : onTap,
      child: Material(
        type: MaterialType.transparency,
        child: Padding(
          // Internal padding that expands the clickable area and ink splash size
          padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 4.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: targetColor, size: 28),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                  color: targetColor,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A custom chip for displaying and selecting a camera parameter.
///
/// WHY NOT ChoiceChip or ActionChip?
/// Built-in Material chips are strictly designed for a single line of text.
/// They force a specific height, making it very difficult to stack two lines
/// (the parameter label and the formatted value) without clipping. This custom
/// implementation bypasses those constraints while retaining the Material
/// shape, color mapping, and ripple effects.
class CameraSettingChip extends StatelessWidget {
  const CameraSettingChip({
    super.key,
    required this.param,
    required this.icon,
    required this.label,
    required this.valueLabel,
    required this.isActive,
    required this.onTap,
  });

  final CameraSettingType param;
  final IconData icon;
  final String label;
  final String valueLabel;
  final bool isActive;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      // Outer padding around each individual chip:
      // - Left/Right (10.0): Horizontal spacing between adjacent chips.
      // - Bottom (4.0): Shifts the chip slightly upwards relative to its neighbors or container center.
      padding: const EdgeInsets.fromLTRB(10.0, 0.0, 10.0, 4.0),
      child: Material(
        color: isActive
            ? cs.primary.withValues(alpha: 0.8)
            : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          splashColor: isActive
              ? cs.onPrimary.withValues(alpha: 0.2)
              : cs.primary.withValues(alpha: 0.1),
          child: Padding(
            // Inner padding of the chip defining its actual visual size:
            // - Horizontal (14.0): Spacing on the left and right of the content.
            // - Vertical (6.0): Defines the height of the chip. Increase/decrease this to make the chip taller/shorter.
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: isActive ? cs.onPrimary : cs.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 9,
                        letterSpacing: 0.5,
                        color: isActive
                            ? cs.onPrimary.withValues(alpha: 0.8)
                            : cs.onSurfaceVariant.withValues(alpha: 0.8),
                      ),
                    ),
                    Text(
                      valueLabel,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: isActive
                            ? FontWeight.bold
                            : FontWeight.w600,
                        fontFamily: 'monospace',
                        color: isActive ? cs.onPrimary : cs.onSurface,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small toggle button used to switch a specific parameter between Auto and Manual.
class CameraAutoToggleButton extends StatelessWidget {
  const CameraAutoToggleButton({
    super.key,
    required this.isAuto,
    required this.onTap,
  });

  final bool isAuto;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return IconButton(
      onPressed: onTap,
      isSelected: isAuto,
      icon: const Icon(Symbols.autofps_select_rounded),
      selectedIcon: const Icon(Symbols.autofps_select_rounded),
      style: ButtonStyle(
        fixedSize: WidgetStateProperty.all(const Size(44, 44)),
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return cs.primary.withValues(alpha: 0.15);
          }
          return cs.surfaceContainerHigh.withValues(alpha: 0.5);
        }),
        foregroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return cs.primary;
          }
          return cs.onSurfaceVariant;
        }),
        iconSize: WidgetStateProperty.all(28.0),
      ),
    );
  }
}
