/// Formats a shutter speed value in nanoseconds for display.
///
/// Returns fractional notation (e.g. `'1/250'`) for standard sub-second
/// values whose denominator is ≥ 2 (i.e. exposure < 0.5 s), and decimal
/// seconds (e.g. `'0.8s'`) for longer exposures. This avoids collapsing
/// non-standard AE values (e.g. 0.8 s) to the misleading `'1/1'`.
String formatShutterNs(double ns) {
  if (ns <= 0) return '0';
  final secs = ns / 1e9;
  if (secs < 1.0) {
    final denom = 1.0 / secs;
    if (denom >= 2.0) return '1/${denom.round()}';
  }
  return '${secs.toStringAsFixed(1)}s';
}
