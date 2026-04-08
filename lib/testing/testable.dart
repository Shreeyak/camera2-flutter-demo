// lib/testing/testable.dart
import 'package:flutter/material.dart' show Semantics, StatelessWidget, Widget, BuildContext;

import 'widget_registry.dart' show WidgetEntry;

/// Wraps a child widget with both a [ValueKey] (from the registry entry)
/// and a [Semantics] node.
///
/// For slider-type widgets, set [slider] to `true` and pass the current
/// [value] string so accessibility tools can read the slider state.
///
/// ```dart
/// Testable(
///   entry: kGpuBrightness,
///   slider: true,
///   value: brightness.toStringAsFixed(2),
///   child: Slider(...),
/// )
/// ```
class Testable extends StatelessWidget {
  final WidgetEntry entry;
  final Widget child;

  /// Whether this wraps a slider-type widget.
  final bool slider;

  /// Current value string exposed to accessibility (e.g. `"0.42"`).
  final String? value;

  Testable({
    required this.entry,
    required this.child,
    this.slider = false,
    this.value,
  }) : super(key: entry.key);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: entry.label,
      slider: slider,
      value: value,
      child: child,
    );
  }
}
