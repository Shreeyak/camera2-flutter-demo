// lib/testing/keys/gpu_controls_sidebar_keys.dart
import '../widget_registry.dart' show WidgetRegistry;

final kGpuBrightness = WidgetRegistry.instance.register(
  id: 'gpu.brightness',
  label: 'Brightness',
  description: 'Adjusts image brightness (-1.0 to 1.0)',
);

final kGpuContrast = WidgetRegistry.instance.register(
  id: 'gpu.contrast',
  label: 'Contrast',
  description: 'Adjusts image contrast (-1.0 to 1.0)',
);

final kGpuSaturation = WidgetRegistry.instance.register(
  id: 'gpu.saturation',
  label: 'Saturation',
  description: 'Adjusts image saturation (-1.0 to 1.0)',
);

final kGpuGamma = WidgetRegistry.instance.register(
  id: 'gpu.gamma',
  label: 'Gamma',
  description: 'Adjusts gamma curve (0.1 to 4.0)',
);

final kGpuBlackR = WidgetRegistry.instance.register(
  id: 'gpu.black.r',
  label: 'Black balance red',
  description: 'Adjusts red black point (0.0 to 0.5)',
);

final kGpuBlackG = WidgetRegistry.instance.register(
  id: 'gpu.black.g',
  label: 'Black balance green',
  description: 'Adjusts green black point (0.0 to 0.5)',
);

final kGpuBlackB = WidgetRegistry.instance.register(
  id: 'gpu.black.b',
  label: 'Black balance blue',
  description: 'Adjusts blue black point (0.0 to 0.5)',
);

final kGpuResetAll = WidgetRegistry.instance.register(
  id: 'gpu.reset_all',
  label: 'Reset all processing',
  description: 'Resets all GPU processing parameters to defaults',
);
