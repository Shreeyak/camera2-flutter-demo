import 'dart:async';
import 'package:flutter/material.dart';
import 'camera_dial_config.dart';

// ── Shared helpers ────────────────────────────────────────────────────────────

/// Smoothstep alpha: 1 in the centre, 0 at the viewport edge.
/// Applied per-element (tick or label) so each gets a single uniform alpha
/// derived from its centre x — avoids the half-bright/half-dim split that a
/// ShaderMask produces.
double _edgeFade(double x, double viewportWidth, CameraDialStyle style) {
  final fade = style.fade;
  final double fadeZone = (viewportWidth * fade.fadeZoneFraction)
      .clamp(fade.fadeZoneMinPx, fade.fadeZoneMaxPx)
      .toDouble();

  double t = 1.0; // 1.0 = fully visible, no fade
  if (x < fadeZone) t = (x / fadeZone).clamp(0.0, 1.0);
  if (x > viewportWidth - fadeZone) {
    t = ((viewportWidth - x) / fadeZone).clamp(0.0, 1.0);
  }
  t = t * (1 - fade.minFadeValue) + fade.minFadeValue;
  return t * t * (3.0 - 2.0 * t); // smoothstep curve
}

// ── Widget ────────────────────────────────────────────────────────────────────

/// Horizontal ruler dial styled after iOS camera controls.
class CameraRulerDial extends StatefulWidget {
  final CameraDialConfig config;
  final double initialValue;
  final ValueChanged<double> onChanged;

  /// Enables fling inertia after drag release.
  final bool enableInertia;

  /// Icons shown at the left (min) and right (max) ends.
  final Widget? leftIcon;
  final Widget? rightIcon;

  const CameraRulerDial({
    super.key,
    required this.config,
    required this.initialValue,
    required this.onChanged,
    this.enableInertia = false,
    this.leftIcon,
    this.rightIcon,
  });

  @override
  State<CameraRulerDial> createState() => _CameraRulerDialState();
}

class _CameraRulerDialState extends State<CameraRulerDial> {
  /// Scroll position as 0..1 fraction. Fractional during drag, snapped at rest.
  double _visualPercent = 0;

  double _velocity = 0;
  DateTime? _lastDragTime;
  Timer? _inertiaTimer;

  /// Last snapped tick index — used to fire haptic + onChanged exactly once per
  /// tick boundary crossed, not once per pixel.
  int _lastTickIndex = 0;

  double get _visualIndex => _visualPercent * (widget.config.stopCount - 1);

  @override
  void initState() {
    super.initState();
    _syncToInitialValue();
  }

  @override
  void didUpdateWidget(covariant CameraRulerDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialValue != widget.initialValue) {
      _syncToInitialValue();
    }
  }

  void _syncToInitialValue() {
    final idx = widget.config.stops.indexOf(widget.initialValue);
    final clampedIdx = (idx < 0 ? 0 : idx).clamp(
      0,
      widget.config.stopCount - 1,
    );
    _visualPercent = widget.config.indexToPercent(clampedIdx);
    _lastTickIndex = clampedIdx.toInt();
  }

  // ── Drag ───────────────────────────────────────────────────────────────────

  void _updateDrag(double delta) {
    final pxPerPercent =
        1.0 /
        ((widget.config.stopCount - 1) *
            widget.config.style.layout.tickSpacing);
    final newPercent = (_visualPercent - delta * pxPerPercent).clamp(0.0, 1.0);
    _crossTick(newPercent);
    setState(() => _visualPercent = newPercent);
  }

  /// Fires haptic + onChanged once each time the indicator crosses a tick.
  void _crossTick(double newPercent) {
    final idx = (newPercent * (widget.config.stopCount - 1)).round().clamp(
      0,
      widget.config.stopCount - 1,
    );
    if (idx != _lastTickIndex) {
      _lastTickIndex = idx;
      _emitHaptic();
      widget.onChanged(widget.config.stops[idx]);
    }
  }

  void _emitHaptic() {
    final haptic = widget.config.hapticFeedback;
    if (haptic != null) unawaited(haptic());
  }

  void _trackVelocity(double delta) {
    final now = DateTime.now();
    if (_lastDragTime != null) {
      final dt = now.difference(_lastDragTime!).inMilliseconds / 1000;
      if (dt > 0) _velocity = delta / dt;
    }
    _lastDragTime = now;
  }

  void _onDragEnd() {
    if (widget.enableInertia && _velocity.abs() >= 0.5) {
      _startInertia();
    } else {
      setState(_snapToNearest);
    }
  }

  // ── Snap ───────────────────────────────────────────────────────────────────

  /// Snaps to nearest tick. Always nearest — velocity-direction snapping is
  /// unreliable because finger-lift velocity is noisy.
  void _snapToNearest() {
    final idx = (_visualPercent * (widget.config.stopCount - 1)).round().clamp(
      0,
      widget.config.stopCount - 1,
    );
    _visualPercent = widget.config.indexToPercent(idx);
    widget.onChanged(widget.config.stops[idx]);
  }

  // ── Inertia ────────────────────────────────────────────────────────────────

  void _startInertia() {
    const friction = 0.88;
    _inertiaTimer?.cancel();
    _inertiaTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _velocity *= friction;
      if (_velocity.abs() < 0.5) {
        _inertiaTimer?.cancel();
        setState(_snapToNearest);
        return;
      }
      _updateDrag(_velocity * 0.016);
    });
  }

  @override
  void dispose() {
    _inertiaTimer?.cancel();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Composite: surface @ 82% over black camera preview → single opaque colour.
    final overlayBg = cs.surface.withValues(alpha: 0.82);

    final style = widget.config.style;
    final layout = style.layout;
    return ClipRRect(
      borderRadius: BorderRadius.circular(100),
      child: ColoredBox(
        color: overlayBg,
        child: SizedBox(
          height: layout.totalHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // Tick index 0 position in inner-zone local coordinates.
              // Pixel-aligned so each tick falls on a whole physical pixel —
              // prevents sub-pixel AA blur on vertical lines.
              final dpr = MediaQuery.of(context).devicePixelRatio;
              final rawOffset =
                  constraints.maxWidth / 2 -
                  _visualIndex * layout.tickSpacing -
                  layout.iconPad;
              final rulerOffset = (rawOffset * dpr).roundToDouble() / dpr;

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (d) {
                  if (widget.enableInertia) _trackVelocity(d.delta.dx);
                  _updateDrag(d.delta.dx);
                },
                onHorizontalDragEnd: (_) => _onDragEnd(),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      left: layout.iconPad,
                      right: layout.iconPad,
                      top: 0,
                      bottom: 0,
                      child: _DialTrack(
                        key: const ValueKey('DialTrack'),
                        config: widget.config,
                        rulerOffset: rulerOffset,
                        visualIndex: _visualIndex,
                        dpr: dpr,
                      ),
                    ),

                    if (widget.leftIcon != null)
                      Positioned(
                        left: layout.iconInset,
                        top: 0,
                        bottom: 0,
                        child: Center(child: widget.leftIcon!),
                      ),
                    if (widget.rightIcon != null)
                      Positioned(
                        right: layout.iconInset,
                        top: 0,
                        bottom: 0,
                        child: Center(child: widget.rightIcon!),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ── DialTrack ─────────────────────────────────────────────────────────────────

/// Ticks, labels, and centre indicator — the scrollable ruler content.
/// Icons and gesture handling live in the parent [_CameraRulerDialState].
class _DialTrack extends StatelessWidget {
  final CameraDialConfig config;
  final double rulerOffset;
  final double visualIndex;
  final double dpr;

  const _DialTrack({
    super.key,
    required this.config,
    required this.rulerOffset,
    required this.visualIndex,
    required this.dpr,
  });

  @override
  Widget build(BuildContext context) {
    final style = config.style;
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: ClipRect(
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _TicksPainter(
                      config: config,
                      rulerOffset: rulerOffset,
                      dpr: dpr,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _LabelsPainter(
                        config: config,
                        visualIndex: visualIndex,
                        rulerOffset: rulerOffset,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Centre indicator — bottomInset creates a small gap beneath ticks.
        Positioned(
          top: 0,
          bottom: style.indicator.bottomInset,
          left: 0,
          right: 0,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: _Indicator(style: style),
          ),
        ),
      ],
    );
  }
}

// ── Painters ──────────────────────────────────────────────────────────────────

/// Draws tick marks for all stops visible in the current viewport.
/// Per-tick alpha via [_edgeFade] keeps each tick uniformly faded based on its centre position.
class _TicksPainter extends CustomPainter {
  final CameraDialConfig config;

  /// X position of tick index 0 in the inner-zone local coordinate space.
  final double rulerOffset;

  /// Device pixel ratio — snaps each tick x to a whole physical pixel.
  final double dpr;

  const _TicksPainter({
    required this.config,
    required this.rulerOffset,
    required this.dpr,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final style = config.style;
    final layout = style.layout;
    final ticks = style.ticks;
    final n = config.stopCount;
    if (n < 2) return;

    // Tick strip bottom at tickTop + majorTickHeight. Painting to size.height would clip
    // against the outer ClipRect at the widget's bottom edge.
    final double bottom = layout.tickTop + ticks.majorHeight;

    final int iFirst =
        ((-layout.tickSpacing - rulerOffset) / layout.tickSpacing)
            .floor()
            .clamp(0, n - 1);
    final int iLast =
        ((size.width + layout.tickSpacing - rulerOffset) / layout.tickSpacing)
            .ceil()
            .clamp(0, n - 1);

    final paint = Paint()..strokeCap = StrokeCap.round;

    for (int i = iFirst; i <= iLast; i++) {
      // Snap to whole physical pixel — integer columns, no AA blur.
      final double x =
          ((rulerOffset + i * layout.tickSpacing) * dpr).roundToDouble() / dpr;

      final double fade = _edgeFade(x, size.width, style);
      if (fade <= 0) continue;

      final bool isMajor = i % config.majorTickEvery == 0;
      final Color baseColor = isMajor ? ticks.color : ticks.minorColor;
      paint
        ..strokeWidth = isMajor ? ticks.majorWidth : ticks.minorWidth
        ..color = baseColor.withValues(
          alpha: (isMajor ? ticks.majorOpacity : ticks.minorOpacity) * fade,
        );

      canvas.drawLine(
        Offset(x, bottom),
        Offset(x, bottom - (isMajor ? ticks.majorHeight : ticks.minorHeight)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TicksPainter old) =>
      old.rulerOffset != rulerOffset ||
      old.config.stopCount != config.stopCount ||
      old.config.majorTickEvery != config.majorTickEvery ||
      old.config.style != config.style;
}

/// Capsule indicator anchored at the ruler's centre — marks the current value.
class _Indicator extends StatelessWidget {
  final CameraDialStyle style;

  const _Indicator({required this.style});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: style.indicator.width,
      height: style.indicator.height,
      decoration: BoxDecoration(
        color: style.indicator.color,
        borderRadius: BorderRadius.circular(100),
      ),
    );
  }
}

/// Draws the centre value label (large, bold) and up to 2 neighbouring major
/// tick labels on each side. Per-label alpha via [_edgeFade] keeps each label uniformly faded.
class _LabelsPainter extends CustomPainter {
  final CameraDialConfig config;
  final double visualIndex;
  final double rulerOffset;

  const _LabelsPainter({
    required this.config,
    required this.visualIndex,
    required this.rulerOffset,
  });

  TextPainter _makeLabel(
    int idx,
    double x,
    double viewportWidth, {
    required bool isCenter,
  }) {
    final style = config.style;
    final labels = style.labels;
    final double fade = _edgeFade(x, viewportWidth, style);
    return TextPainter(
      text: TextSpan(
        text: config.format(config.stops[idx]),
        style: TextStyle(
          color: Colors.white.withValues(
            alpha: isCenter ? fade : labels.sideOpacity * fade,
          ),
          fontSize: isCenter ? labels.centerFontSize : labels.sideFontSize,
          fontWeight: isCenter
              ? labels.centerFontWeight
              : labels.sideFontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  void _paint(Canvas canvas, TextPainter tp, double x) {
    final style = config.style;
    tp.paint(
      canvas,
      Offset(
        x - tp.width / 2,
        style.layout.tickTop + style.labels.baselineOffset - tp.height,
      ),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final style = config.style;
    final layout = style.layout;
    final labels = style.labels;
    final int step = config.majorTickEvery;
    final int centerIdx = visualIndex.round().clamp(0, config.stopCount - 1);
    final double centerX = rulerOffset + visualIndex * layout.tickSpacing;

    // Centre label — always rendered.
    final center = _makeLabel(centerIdx, centerX, size.width, isCenter: true);
    _paint(canvas, center, centerX);
    double rightBound = centerX + center.width / 2;
    double leftBound = centerX - center.width / 2;

    // Walk right — up to _maxPerSide labels.
    int drawnR = 0;
    for (
      int i = ((visualIndex / step).ceil() * step);
      i < config.stopCount && drawnR < labels.maxPerSide;
      i += step
    ) {
      final double x = rulerOffset + i * layout.tickSpacing;
      if (x > size.width + labels.cullMargin) break;
      final tp = _makeLabel(i, x, size.width, isCenter: false);
      if (x - tp.width / 2 - rightBound >= labels.minGap) {
        _paint(canvas, tp, x);
        rightBound = x + tp.width / 2;
        drawnR++;
      }
    }

    // Walk left — up to _maxPerSide labels.
    int drawnL = 0;
    for (
      int i = ((visualIndex / step).floor() * step);
      i >= 0 && drawnL < labels.maxPerSide;
      i -= step
    ) {
      if (i == centerIdx) continue;
      final double x = rulerOffset + i * layout.tickSpacing;
      if (x < -labels.cullMargin) break;
      final tp = _makeLabel(i, x, size.width, isCenter: false);
      if (leftBound - (x + tp.width / 2) >= labels.minGap) {
        _paint(canvas, tp, x);
        leftBound = x - tp.width / 2;
        drawnL++;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LabelsPainter old) =>
      old.visualIndex != visualIndex ||
      old.rulerOffset != rulerOffset ||
      old.config != config;
}
