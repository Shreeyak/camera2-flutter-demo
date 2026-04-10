import 'dart:math' show max;

import 'package:cambrian_camera/cambrian_camera.dart' show CameraTextureInfo;
import 'package:flutter/material.dart'
    show
        Alignment,
        BorderRadius,
        BoxConstraints,
        BuildContext,
        Canvas,
        Center,
        Color,
        CustomPaint,
        CustomPainter,
        ElevatedButton,
        LayoutBuilder,
        LinearGradient,
        Paint,
        PaintingStyle,
        Positioned,
        RRect,
        Radius,
        Rect,
        RoundedRectangleBorder,
        Size,
        Stack,
        StatelessWidget,
        Text,
        TextStyle,
        Theme,
        Widget;

import 'gpu_controls_sidebar.dart' show CalibrationTarget;

// GPU patch constants — must stay in sync with GpuRenderer.cpp (kPatchW/kPatchH).
const int _kPatchPx = 96;

/// Fullscreen overlay shown while the user is selecting a calibration patch.
///
/// Draws a square outline that precisely frames the 96×96-pixel center patch
/// sampled by the GPU, and places a confirmation button near the bottom of
/// the screen.
///
/// Pass [textureInfo] and [quarterTurns] so the overlay can map GPU pixel
/// coordinates to on-screen logical pixels using the same BoxFit.cover scale
/// that the camera preview applies.
class CalibrationOverlay extends StatelessWidget {
  const CalibrationOverlay({
    super.key,
    required this.target,
    required this.onConfirm,
    this.textureInfo,
    this.quarterTurns = 0,
  });

  final CalibrationTarget target;
  final void Function() onConfirm;

  /// Most-recent GPU texture dimensions. When non-null, the patch square is
  /// scaled to exactly match the on-screen size of the 96×96 GPU sample region.
  final CameraTextureInfo? textureInfo;

  /// Same value as [RotatedBox.quarterTurns] applied to the camera preview.
  /// Odd values indicate the frame is rotated 90°/270°, swapping w/h for
  /// BoxFit layout purposes.
  final int quarterTurns;

  @override
  Widget build(BuildContext context) {
    final label = target == CalibrationTarget.wb
        ? 'Confirm White Point'
        : 'Confirm Black Point';

    return LayoutBuilder(
      builder: (BuildContext ctx, BoxConstraints constraints) {
        final screenW = constraints.maxWidth;
        final screenH = constraints.maxHeight;

        // Compute the on-screen logical-pixel size of the 96×96 GPU patch.
        //
        // The preview uses FittedBox(BoxFit.cover) wrapping a
        // RotatedBox(quarterTurns, SizedBox(frameW, frameH, Texture)).
        // When quarterTurns is odd, RotatedBox swaps w/h for layout, so the
        // FittedBox sees a (frameH × frameW) child.
        // BoxFit.cover scale = max(screenW / layoutW, screenH / layoutH).
        // Since the patch is square, the on-screen square side = 96 × scale.
        double squarePx = _kPatchPx.toDouble(); // 1:1 fallback
        final info = textureInfo;
        if (info != null && info.width > 0 && info.height > 0) {
          final bool swapped = quarterTurns % 2 != 0;
          final double layoutW =
              swapped ? info.height.toDouble() : info.width.toDouble();
          final double layoutH =
              swapped ? info.width.toDouble() : info.height.toDouble();
          final double scale = max(screenW / layoutW, screenH / layoutH);
          squarePx = _kPatchPx * scale;
        }

        return Stack(
          children: [
            // Square outline centered on screen — pixel-accurate match to the
            // GPU sampling region.
            Center(
              child: CustomPaint(
                size: Size(squarePx, squarePx),
                painter: const _PatchBorderPainter(),
              ),
            ),
            // Confirm button anchored near the bottom of the overlay.
            Positioned(
              bottom: 72,
              left: 0,
              right: 0,
              child: Center(
                child: ElevatedButton(
                  onPressed: onConfirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.primary,
                    foregroundColor: Theme.of(ctx).colorScheme.onPrimary,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.all(Radius.circular(24)),
                    ),
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(fontSize: 15, letterSpacing: 0.2),
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

/// Paints the patch boundary as a rounded-rectangle stroke and a four-armed
/// crosshair centered in the patch.
///
/// Square: white outer stroke + dark shadow — readable on any background.
/// Crosshair: four rounded arms in a warm gradient (red → orange → amber),
/// with a center gap so the arms frame the target without covering it.
class _PatchBorderPainter extends CustomPainter {
  const _PatchBorderPainter();

  // Crosshair arm dimensions (logical pixels, fixed regardless of patch size).
  static const double _gap = 18.0; // gap from center to arm start
  static const double _len = 32.0; // arm length
  static const double _w = 10.0; // arm width
  static const double _r = _w / 2; // corner radius

  // Warm gradient colors per arm.
  static const _colorTop = Color(0xFFE53935); // red
  static const _colorSide = Color(0xFFFF7043); // deep orange
  static const _colorBottom = Color(0xFFFFB300); // amber

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;

    // ── Square border ──────────────────────────────────────────────────────
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    const borderRadius = Radius.circular(4);

    // Warm gradient shader — top red → middle orange → bottom amber,
    // matching the crosshair arm colors for a unified look.
    final gradientShader = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [_colorTop, _colorSide, _colorBottom],
    ).createShader(rect);

    // Dark shadow behind for contrast on any background.
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.inflate(1.5), borderRadius),
      Paint()
        ..color = const Color(0xBB000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0,
    );
    // Gradient foreground stroke.
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, borderRadius),
      Paint()
        ..shader = gradientShader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // ── Crosshair arms ─────────────────────────────────────────────────────
    void drawArm(Rect armRect, Color color) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(armRect, const Radius.circular(_r)),
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );
    }

    // Top arm (vertical, above center)
    drawArm(
        Rect.fromLTWH(cx - _w / 2, cy - _gap - _len, _w, _len), _colorTop);
    // Bottom arm (vertical, below center)
    drawArm(Rect.fromLTWH(cx - _w / 2, cy + _gap, _w, _len), _colorBottom);
    // Left arm (horizontal, left of center)
    drawArm(
        Rect.fromLTWH(cx - _gap - _len, cy - _w / 2, _len, _w), _colorSide);
    // Right arm (horizontal, right of center)
    drawArm(Rect.fromLTWH(cx + _gap, cy - _w / 2, _len, _w), _colorSide);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
