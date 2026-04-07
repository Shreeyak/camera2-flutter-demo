// lib/testing/widget_registry.dart
import 'package:flutter/foundation.dart' show ValueKey;

/// Metadata for a registered interactive widget.
///
/// Every interactive widget in the app must register via [WidgetRegistry] to
/// obtain a [ValueKey]. This enforces a 1:1 mapping between keys and metadata,
/// preventing drift between code and documentation.
class WidgetEntry {
  /// Dot-separated hierarchy, e.g. `bar.settings`, `chip.iso`.
  final String id;

  /// Accessibility / semantics label, e.g. `Settings`.
  final String label;

  /// Human-readable purpose, used in generated docs.
  final String description;

  /// The stable [ValueKey] derived from [id].
  late final ValueKey<String> key = ValueKey<String>(id);

  WidgetEntry({
    required this.id,
    required this.label,
    required this.description,
  });
}

/// Singleton registry of all interactive widgets.
///
/// Usage at widget definition site:
/// ```dart
/// final kBarSettings = WidgetRegistry.instance.register(
///   id: 'bar.settings',
///   label: 'Settings',
///   description: 'Opens camera settings panel',
/// );
/// ```
class WidgetRegistry {
  WidgetRegistry._();

  /// The singleton instance.
  static final instance = WidgetRegistry._();

  final Map<String, WidgetEntry> _entries = {};

  /// Register a widget and return its [WidgetEntry].
  ///
  /// Asserts that [id] is unique — duplicate IDs are a programming error.
  WidgetEntry register({
    required String id,
    required String label,
    required String description,
  }) {
    assert(
      !_entries.containsKey(id),
      'Duplicate widget id: $id',
    );
    final entry = WidgetEntry(id: id, label: label, description: description);
    _entries[id] = entry;
    return entry;
  }

  /// All registered entries, keyed by id. Unmodifiable.
  Map<String, WidgetEntry> get all => Map.unmodifiable(_entries);
}
