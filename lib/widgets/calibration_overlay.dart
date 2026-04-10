import 'package:flutter/material.dart'
    show
        BorderRadius,
        BuildContext,
        Canvas,
        Color,
        Colors,
        Column,
        CustomPaint,
        CustomPainter,
        ElevatedButton,
        MainAxisAlignment,
        MainAxisSize,
        Offset,
        Paint,
        PaintingStyle,
        RRect,
        Radius,
        Rect,
        RoundedRectangleBorder,
        Size,
        SizedBox,
        StatelessWidget,
        Text,
        TextStyle,
        Theme,
        Widget;

import 'gpu_controls_sidebar.dart' show CalibrationTarget;

/// Fullscreen overlay shown while the user is selecting a calibration patch.
///
/// Draws a centered crosshair (4 rounded arms with a center gap, colored in a
/// warm gradient from red at the top through orange to amber at the bottom) and
/// places a floating confirmation button directly below it.
class CalibrationOverlay extends StatelessWidget {
  const CalibrationOverlay({
    super.key,
    required this.target,
    required this.onConfirm,
  });

  final CalibrationTarget target;
  final void Function() onConfirm;

  @override
  Widget build(BuildContext context) {
    final label = target == CalibrationTarget.wb
        ? 'Confirm White Point'
        : 'Confirm Black Point';

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.max,
      children: [
        const SizedBox(
          width: 120,
          height: 120,
          child: CustomPaint(painter: _CrosshairPainter()),
        ),
        const SizedBox(height: 28),
        ElevatedButton(
          onPressed: onConfirm,
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.primary,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(24)),
            ),
          ),
          child: Text(
            label,
            style: const TextStyle(fontSize: 15, letterSpacing: 0.2),
          ),
        ),
      ],
    );
  }
}

/// Paints a four-armed crosshair with a center gap.
///
/// Each arm is a rounded rectangle. Colors follow a warm gradient:
/// top → red, left/right → deep orange, bottom → amber.
class _CrosshairPainter extends CustomPainter {
  const _CrosshairPainter();

  // Arm dimensions and center gap (all in logical pixels).
  static const double _gap = 18.0; // gap from center to arm start
  static const double _len = 32.0; // arm length
  static const double _w = 10.0; // arm width
  static const double _r = _w / 2; // corner radius

  // Warm-gradient colors per arm position.
  static const _colorTop = Color(0xFFE53935); // red
  static const _colorSide = Color(0xFFFF7043); // deep orange
  static const _colorBottom = Color(0xFFFFB300); // amber

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    void drawArm(Rect rect, Color color) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(_r)),
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );
    }

    // Top arm (vertical, above center)
    drawArm(Rect.fromLTWH(cx - _w / 2, cy - _gap - _len, _w, _len), _colorTop);
    // Bottom arm (vertical, below center)
    drawArm(Rect.fromLTWH(cx - _w / 2, cy + _gap, _w, _len), _colorBottom);
    // Left arm (horizontal, left of center)
    drawArm(Rect.fromLTWH(cx - _gap - _len, cy - _w / 2, _len, _w), _colorSide);
    // Right arm (horizontal, right of center)
    drawArm(Rect.fromLTWH(cx + _gap, cy - _w / 2, _len, _w), _colorSide);

    // Center dot — radius 3 px, much thinner than the arms
    canvas.drawCircle(
      Offset(cx, cy),
      3.0,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
