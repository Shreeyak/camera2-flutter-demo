// integration_test/app_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:camera2_flutter_demo/main.dart' as app;
import 'package:camera2_flutter_demo/testing/widget_registry.dart'
    show WidgetRegistry;
import 'package:camera2_flutter_demo/testing/keys/camera_settings_bar_keys.dart'
    show kChipIso, kChipShutter, kChipFocus, kChipWb, kChipZoom;
import 'package:camera2_flutter_demo/testing/keys/camera_control_keys.dart'
    show kHudRecording;

import 'helpers/camera_test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Widget registry', () {
    testWidgets('widgets registered at launch (lazy — count grows as UI opens)', (tester) async {
      print('▶ TEST: Widget registry — checking registered widgets at launch');
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      final registry = WidgetRegistry.instance.all;
      print('  Registry has ${registry.length} widgets: ${registry.keys.join(', ')}');
      // Keys register lazily when their widget first renders.
      // Widgets behind conditional UI (GPU sidebar, WB segment, auto toggle)
      // won't appear until that UI is opened. Expect at least the always-visible set.
      expect(registry.length, greaterThanOrEqualTo(15));
    });
  });

  group('Settings panel', () {
    testWidgets('opens and shows all 5 chips', (tester) async {
      print('▶ TEST: Settings panel — opening settings, checking 5 chips visible');
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      await openSettings(tester);
      print('  Settings opened — verifying chip keys');

      expect(find.byKey(kChipIso.key), findsOneWidget);
      expect(find.byKey(kChipShutter.key), findsOneWidget);
      expect(find.byKey(kChipFocus.key), findsOneWidget);
      expect(find.byKey(kChipWb.key), findsOneWidget);
      expect(find.byKey(kChipZoom.key), findsOneWidget);
      print('  ✓ All 5 chips found');
    });

    testWidgets('each chip can be selected', (tester) async {
      print('▶ TEST: Settings panel — tapping each chip in turn');
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      await openSettings(tester);

      for (final chip in [kChipIso, kChipShutter, kChipFocus, kChipWb, kChipZoom]) {
        print('  Tapping chip: ${chip.id}');
        await tapChip(tester, chip);
      }
      print('  ✓ All chips tappable');
    });
  });

  group('Recording', () {
    testWidgets('start and stop recording', (tester) async {
      print('▶ TEST: Recording — start, wait 3s, stop');
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 3));

      await startRecording(tester);
      print('  Recording started — verifying HUD visible');

      expect(find.byKey(kHudRecording.key), findsOneWidget);
      print('  ✓ HUD visible — waiting 3s');

      await tester.pump(const Duration(seconds: 3));

      await stopRecording(tester);
      print('  ✓ Recording stopped');
    });
  });
}
