// lib/widgets/camera_control_keys.dart
import '../testing/widget_registry.dart' show WidgetRegistry;

final kDialAutoToggle = WidgetRegistry.instance.register(
  id: 'dial.auto_toggle',
  label: 'Auto/manual toggle',
  description: 'Toggles between auto and manual mode for the active setting',
);

final kDialWbSegment = WidgetRegistry.instance.register(
  id: 'dial.wb_segment',
  label: 'White balance mode',
  description: 'Switches between auto white balance and locked white balance',
);

final kHudRecording = WidgetRegistry.instance.register(
  id: 'hud.recording',
  label: 'Recording status',
  description: 'Shows recording timer, saving progress, or hidden',
);
