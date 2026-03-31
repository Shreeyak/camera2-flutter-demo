/// Formats a shutter speed value in nanoseconds for display.
///
/// Returns fractional notation (e.g. `'1/250'`) for sub-second values, and
/// decimal seconds (e.g. `'1.5s'`) for values ≥ 1 second.
String formatShutterNs(double ns) {
  if (ns <= 0) return '0';
  final secs = ns / 1e9;
  if (secs < 1.0) return '1/${(1.0 / secs).round()}';
  return '${secs.toStringAsFixed(1)}s';
}
