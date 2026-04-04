import 'package:flutter/material.dart';
import 'package:cambrian_camera/cambrian_camera.dart' show ProcessingParams;

/// Right-side panel with Material3 sliders for each GPU shader uniform.
///
/// [params] is the current value displayed by the sliders.
/// [onChanged] is called immediately on every drag with the updated params.
class GpuControlsSidebar extends StatelessWidget {
  const GpuControlsSidebar({
    super.key,
    required this.params,
    required this.onChanged,
  });

  final ProcessingParams params;
  final ValueChanged<ProcessingParams> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 260,
      color: theme.colorScheme.surface.withValues(alpha: 0.92),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            Text(
              'Calibrate Color',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            _ShaderSlider(
              label: 'Brightness',
              value: params.brightness,
              min: -1.0,
              max: 1.0,
              defaultValue: 0.0,
              valueLabel: params.brightness.toStringAsFixed(2),
              onChanged: (v) => onChanged(params.copyWith(brightness: v)),
            ),
            _ShaderSlider(
              label: 'Contrast',
              value: params.contrast,
              min: -1.0,
              max: 1.0,
              defaultValue: 0.0,
              valueLabel: params.contrast.toStringAsFixed(2),
              onChanged: (v) => onChanged(params.copyWith(contrast: v)),
            ),
            _ShaderSlider(
              label: 'Saturation',
              value: params.saturation,
              min: -1.0,
              max: 1.0,
              defaultValue: 0.0,
              valueLabel: params.saturation.toStringAsFixed(2),
              onChanged: (v) => onChanged(params.copyWith(saturation: v)),
            ),
            _ShaderSlider(
              label: 'Gamma',
              value: params.gamma,
              min: 0.1,
              max: 4.0,
              defaultValue: 1.0,
              valueLabel: params.gamma.toStringAsFixed(2),
              onChanged: (v) => onChanged(params.copyWith(gamma: v)),
            ),
            const Divider(height: 24),
            Text(
              'Black Balance',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            _ShaderSlider(
              label: 'R',
              value: params.blackR,
              min: 0.0,
              max: 0.5,
              defaultValue: 0.0,
              valueLabel: params.blackR.toStringAsFixed(3),
              activeColor: Colors.redAccent,
              onChanged: (v) => onChanged(params.copyWith(blackR: v)),
            ),
            _ShaderSlider(
              label: 'G',
              value: params.blackG,
              min: 0.0,
              max: 0.5,
              defaultValue: 0.0,
              valueLabel: params.blackG.toStringAsFixed(3),
              activeColor: Colors.greenAccent,
              onChanged: (v) => onChanged(params.copyWith(blackG: v)),
            ),
            _ShaderSlider(
              label: 'B',
              value: params.blackB,
              min: 0.0,
              max: 0.5,
              defaultValue: 0.0,
              valueLabel: params.blackB.toStringAsFixed(3),
              activeColor: Colors.blueAccent,
              onChanged: (v) => onChanged(params.copyWith(blackB: v)),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => onChanged(ProcessingParams()),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reset all'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShaderSlider extends StatelessWidget {
  const _ShaderSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.valueLabel,
    required this.onChanged,
    this.activeColor,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final double defaultValue;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: theme.textTheme.bodySmall),
              GestureDetector(
                onTap: () => onChanged(defaultValue),
                child: Text(
                  valueLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: activeColor,
              thumbColor: activeColor,
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
