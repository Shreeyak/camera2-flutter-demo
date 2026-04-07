// integration_test/app_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:camera2_flutter_demo/main.dart' as app;
import 'package:camera2_flutter_demo/testing/widget_registry.dart'
    show WidgetRegistry;
import 'package:camera2_flutter_demo/widgets/camera_settings_bar_keys.dart'
    show kChipIso, kChipShutter, kChipFocus, kChipWb, kChipZoom;
import 'package:camera2_flutter_demo/widgets/camera_control_keys.dart'
    show kHudRecording;

import 'helpers/camera_test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Widget registry', () {
    testWidgets('all interactive widgets are registered', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final registry = WidgetRegistry.instance.all;
      // 21 widgets expected (4 bar + 5 chips + 3 controls + 8 gpu + 1 hud)
      expect(registry.length, greaterThanOrEqualTo(21));
    });
  });

  group('Settings panel', () {
    testWidgets('opens and shows all 5 chips', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      await openSettings(tester);

      expect(find.byKey(kChipIso.key), findsOneWidget);
      expect(find.byKey(kChipShutter.key), findsOneWidget);
      expect(find.byKey(kChipFocus.key), findsOneWidget);
      expect(find.byKey(kChipWb.key), findsOneWidget);
      expect(find.byKey(kChipZoom.key), findsOneWidget);
    });

    testWidgets('each chip can be selected', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      await openSettings(tester);

      // Tap each chip — no crash means it works
      for (final chip in [kChipIso, kChipShutter, kChipFocus, kChipWb, kChipZoom]) {
        await tapChip(tester, chip);
      }
    });
  });

  group('Recording', () {
    testWidgets('start and stop recording', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      // Start recording
      await startRecording(tester);

      // Verify HUD is visible
      expect(find.byKey(kHudRecording.key), findsOneWidget);

      // Let it record for a few seconds
      await tester.pump(const Duration(seconds: 3));

      // Stop recording
      await stopRecording(tester);
    });
  });
}
