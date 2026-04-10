import 'package:cambrian_camera/cambrian_camera.dart'
    show ProcessingParams, WhiteBalance, WbAuto;
import 'package:flutter/material.dart'
    show
        BuildContext,
        Column,
        Container,
        CrossAxisAlignment,
        Divider,
        EdgeInsets,
        Expanded,
        FontFeature,
        FontWeight,
        GestureDetector,
        Icon,
        Icons,
        ListView,
        MainAxisAlignment,
        OutlinedButton,
        Padding,
        Row,
        RoundSliderOverlayShape,
        RoundSliderThumbShape,
        SafeArea,
        SizedBox,
        Slider,
        SliderTheme,
        StatelessWidget,
        Text,
        Theme,
        ValueChanged,
        VoidCallback,
        Widget;
import 'bottom_bar_buttons.dart' show CameraAutoToggleButton;

/// Which calibration target is currently active.
enum CalibrationTarget { wb, bb }

/// Right-side panel containing WB controls, BB controls, and GPU shader sliders.
///
/// Sections appear in pipeline order: White Balance → Black Balance →
/// Brightness → Contrast → Saturation → Gamma.
class GpuControlsSidebar extends StatelessWidget {
  const GpuControlsSidebar({
    super.key,
    required this.params,
    required this.onChanged,
    required this.wbMode,
    required this.lastWbGains,
    required this.bbLocked,
    required this.lastBbValues,
    required this.onWbToggle,
    required this.onBbToggle,
    required this.onStartCalibration,
    required this.onResetAll,
  });

  final ProcessingParams params;
  final ValueChanged<ProcessingParams> onChanged;

  /// Current WB mode applied to the camera.
  final WhiteBalance wbMode;

  /// Last calibrated WB gains (gainR, gainG, gainB). Null when no calibration
  /// has been performed yet (status line hidden).
  final (double r, double g, double b)? lastWbGains;

  /// Whether BB lock is active (calibrated values being applied).
  final bool bbLocked;

  /// Last calibrated BB offsets (r, g, b). Null = no status line shown.
  /// Non-null only after calibration has been performed and lock is active.
  final (double r, double g, double b)? lastBbValues;

  final VoidCallback onWbToggle;
  final VoidCallback onBbToggle;
  final void Function(CalibrationTarget) onStartCalibration;

  /// Resets all processing params, WB, and BB to factory defaults.
  final VoidCallback onResetAll;

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
            const SizedBox(height: 12),

            // ── White Balance ──────────────────────────────────────────────
            _WbSection(
              wbMode: wbMode,
              lastGains: lastWbGains,
              onToggle: onWbToggle,
              onStartCalibration: () =>
                  onStartCalibration(CalibrationTarget.wb),
            ),

            const Divider(height: 24),

            // ── Black Balance ──────────────────────────────────────────────
            _BbSection(
              bbLocked: bbLocked,
              lastValues: lastBbValues,
              onToggle: onBbToggle,
              onStartCalibration: () =>
                  onStartCalibration(CalibrationTarget.bb),
            ),

            const Divider(height: 24),

            // ── GPU sliders ────────────────────────────────────────────────
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
            const SizedBox(height: 12),
            OutlinedButton.icon(
              // Resets all sliders, WB, and BB to factory defaults.
              onPressed: onResetAll,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reset all'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── White Balance section ──────────────────────────────────────────────────

/// WB controls: auto/manual toggle, calibrate button, and a gain status line.
///
/// The status line (R×… G×… B×…) is shown only when [wbMode] is manual and
/// [lastGains] is non-null. [onToggle] cycles between auto and manual mode;
/// [onStartCalibration] opens the [CalibrationOverlay].
class _WbSection extends StatelessWidget {
  const _WbSection({
    required this.wbMode,
    required this.lastGains,
    required this.onToggle,
    required this.onStartCalibration,
  });

  final WhiteBalance wbMode;
  final (double r, double g, double b)? lastGains;
  final VoidCallback onToggle;
  final VoidCallback onStartCalibration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gains = lastGains;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'WHITE BALANCE',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            CameraAutoToggleButton(
              isAuto: wbMode is WbAuto,
              onTap: onToggle,
              lockedIcon: Icons.lock_outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: onStartCalibration,
                child: const Text('Calibrate'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (wbMode is! WbAuto && gains != null)
          Text(
            'R×${gains.$1.toStringAsFixed(2)}  '
            'G×${gains.$2.toStringAsFixed(2)}  '
            'B×${gains.$3.toStringAsFixed(2)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );
  }
}

// ── Black Balance section ──────────────────────────────────────────────────

/// BB controls: lock toggle, calibrate button, and an offset status line.
///
/// The status line (R… G… B…) is shown only when [bbLocked] is true and
/// [lastValues] is non-null. [onToggle] enables/disables the calibrated offsets;
/// [onStartCalibration] opens the [CalibrationOverlay].
class _BbSection extends StatelessWidget {
  const _BbSection({
    required this.bbLocked,
    required this.lastValues,
    required this.onToggle,
    required this.onStartCalibration,
  });

  final bool bbLocked;
  final (double r, double g, double b)? lastValues;
  final VoidCallback onToggle;
  final VoidCallback onStartCalibration;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vals = lastValues;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'BLACK BALANCE',
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            // isAuto: !bbLocked — highlighted when gains are NOT applied (default/auto state).
            CameraAutoToggleButton(
              isAuto: !bbLocked,
              onTap: onToggle,
              lockedIcon: Icons.lock_outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: onStartCalibration,
                child: const Text('Calibrate'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (bbLocked && vals != null)
          Text(
            'R ${vals.$1.toStringAsFixed(3)}  '
            'G ${vals.$2.toStringAsFixed(3)}  '
            'B ${vals.$3.toStringAsFixed(3)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );
  }
}

// ── Shared slider widget ───────────────────────────────────────────────────

/// A labeled slider row for a single GPU shader parameter.
///
/// Displays [label] on the left and a tappable [valueLabel] on the right;
/// tapping [valueLabel] resets the slider to [defaultValue].
class _ShaderSlider extends StatelessWidget {
  const _ShaderSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.defaultValue,
    required this.valueLabel,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final double defaultValue;
  final String valueLabel;
  final ValueChanged<double> onChanged;

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
