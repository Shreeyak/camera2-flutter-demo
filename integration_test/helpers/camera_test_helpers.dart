// integration_test/helpers/camera_test_helpers.dart
import 'package:flutter_test/flutter_test.dart' show WidgetTester, find;

import 'package:camera2_flutter_demo/widgets/bottom_bar_keys.dart'
    show kBarSettings, kBarCalibrate, kBarRecord;
import 'package:camera2_flutter_demo/widgets/camera_settings_bar_keys.dart'
    show kBarClose;
import 'package:camera2_flutter_demo/testing/widget_registry.dart'
    show WidgetEntry;

/// Taps a widget identified by its [WidgetEntry.key] and pumps.
Future<void> tapEntry(WidgetTester tester, WidgetEntry entry) async {
  await tester.tap(find.byKey(entry.key));
  await tester.pumpAndSettle();
}

/// Taps a widget and uses pump(duration) instead of pumpAndSettle.
/// Use this when the app has continuous animations (e.g. during recording).
Future<void> tapEntryNonSettling(
  WidgetTester tester,
  WidgetEntry entry, {
  Duration wait = const Duration(seconds: 1),
}) async {
  await tester.tap(find.byKey(entry.key));
  await tester.pump(wait);
}

/// Opens the camera settings panel.
Future<void> openSettings(WidgetTester tester) async {
  await tapEntry(tester, kBarSettings);
}

/// Closes the camera settings panel.
Future<void> closeSettings(WidgetTester tester) async {
  await tapEntry(tester, kBarClose);
}

/// Taps a settings chip.
Future<void> tapChip(WidgetTester tester, WidgetEntry chip) async {
  await tapEntry(tester, chip);
}

/// Opens the GPU calibration sidebar.
Future<void> openGpuSidebar(WidgetTester tester) async {
  await tapEntry(tester, kBarCalibrate);
}

/// Starts recording. Uses pump() instead of pumpAndSettle() because
/// continuous frame callbacks during recording prevent settling.
Future<void> startRecording(WidgetTester tester) async {
  await tapEntryNonSettling(tester, kBarRecord);
}

/// Stops recording and waits for encoder flush.
Future<void> stopRecording(WidgetTester tester) async {
  await tapEntryNonSettling(
    tester,
    kBarRecord,
    wait: const Duration(seconds: 3),
  );
}
