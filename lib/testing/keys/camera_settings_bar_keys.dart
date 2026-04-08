// lib/testing/keys/camera_settings_bar_keys.dart
import '../widget_registry.dart' show WidgetRegistry;

final kBarClose = WidgetRegistry.instance.register(
  id: 'bar.close',
  label: 'Close settings',
  description: 'Closes camera settings panel',
);

final kChipIso = WidgetRegistry.instance.register(
  id: 'chip.iso',
  label: 'ISO setting',
  description: 'Selects ISO setting dial',
);

final kChipShutter = WidgetRegistry.instance.register(
  id: 'chip.shutter',
  label: 'Shutter setting',
  description: 'Selects shutter speed setting dial',
);

final kChipFocus = WidgetRegistry.instance.register(
  id: 'chip.focus',
  label: 'Focus setting',
  description: 'Selects focus distance setting dial',
);

final kChipWb = WidgetRegistry.instance.register(
  id: 'chip.wb',
  label: 'White balance setting',
  description: 'Selects white balance control',
);

final kChipZoom = WidgetRegistry.instance.register(
  id: 'chip.zoom',
  label: 'Zoom setting',
  description: 'Selects zoom ratio setting dial',
);
