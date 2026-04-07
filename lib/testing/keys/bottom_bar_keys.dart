// lib/testing/keys/bottom_bar_keys.dart
import '../widget_registry.dart' show WidgetRegistry;

final kBarSettings = WidgetRegistry.instance.register(
  id: 'bar.settings',
  label: 'Settings',
  description: 'Opens camera settings panel',
);

final kBarCalibrate = WidgetRegistry.instance.register(
  id: 'bar.calibrate',
  label: 'Calibrate color',
  description: 'Toggles GPU post-processing sidebar',
);

final kBarRecord = WidgetRegistry.instance.register(
  id: 'bar.record',
  label: 'Record video',
  description: 'Starts or stops video recording',
);
