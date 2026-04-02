import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cambrian_camera/cambrian_camera.dart' show ProcessingParams;
import 'package:camera2_flutter_demo/widgets/gpu_controls_sidebar.dart'
    show GpuControlsSidebar;

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('GpuControlsSidebar', () {
    testWidgets('renders all slider labels', (WidgetTester tester) async {
      await tester.pumpWidget(
        _wrap(
          GpuControlsSidebar(
            params: ProcessingParams(),
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.text('Color Controls'), findsOneWidget);
      expect(find.text('Brightness'), findsOneWidget);
      expect(find.text('Contrast'), findsOneWidget);
      expect(find.text('Saturation'), findsOneWidget);
      expect(find.text('Black Balance'), findsOneWidget);
      expect(find.text('R'), findsOneWidget);
      expect(find.text('G'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
    });

    testWidgets(
      'brightness slider calls onChanged with updated brightness',
      (WidgetTester tester) async {
        ProcessingParams? received;

        await tester.pumpWidget(
          _wrap(
            GpuControlsSidebar(
              params: ProcessingParams(),
              onChanged: (p) => received = p,
            ),
          ),
        );

        // Brightness is the first Slider in the widget.
        await tester.drag(find.byType(Slider).first, const Offset(20, 0));
        await tester.pump();

        expect(received, isNotNull);
        expect(received!.brightness, isNot(0.0));
      },
    );

    testWidgets(
      'contrast slider calls onChanged with updated contrast',
      (WidgetTester tester) async {
        ProcessingParams? received;

        await tester.pumpWidget(
          _wrap(
            GpuControlsSidebar(
              params: ProcessingParams(),
              onChanged: (p) => received = p,
            ),
          ),
        );

        // Contrast is the second Slider.
        await tester.drag(find.byType(Slider).at(1), const Offset(20, 0));
        await tester.pump();

        expect(received, isNotNull);
        expect(received!.contrast, isNot(1.0));
      },
    );

    testWidgets(
      'saturation slider calls onChanged with updated saturation',
      (WidgetTester tester) async {
        ProcessingParams? received;

        await tester.pumpWidget(
          _wrap(
            GpuControlsSidebar(
              params: ProcessingParams(),
              onChanged: (p) => received = p,
            ),
          ),
        );

        // Saturation is the third Slider.
        await tester.drag(find.byType(Slider).at(2), const Offset(20, 0));
        await tester.pump();

        expect(received, isNotNull);
        expect(received!.saturation, isNot(1.0));
      },
    );

    testWidgets(
      'reset button calls onChanged with default ProcessingParams',
      (WidgetTester tester) async {
        ProcessingParams? received;
        final initial = ProcessingParams(brightness: 0.5, contrast: 1.5);

        await tester.pumpWidget(
          _wrap(
            GpuControlsSidebar(
              params: initial,
              onChanged: (p) => received = p,
            ),
          ),
        );

        await tester.tap(find.text('Reset all'));
        await tester.pump();

        expect(received, isNotNull);
        expect(received!.brightness, 0.0);
        expect(received!.contrast, 1.0);
        expect(received!.saturation, 1.0);
        expect(received!.blackR, 0.0);
        expect(received!.blackG, 0.0);
        expect(received!.blackB, 0.0);
      },
    );

    testWidgets(
      'tapping value label resets that slider to default',
      (WidgetTester tester) async {
        ProcessingParams? received;
        final initial = ProcessingParams(brightness: 0.5);

        await tester.pumpWidget(
          _wrap(
            GpuControlsSidebar(
              params: initial,
              onChanged: (p) => received = p,
            ),
          ),
        );

        // The brightness value label shows '0.50'; tapping it resets to 0.0.
        await tester.tap(find.text('0.50'));
        await tester.pump();

        expect(received, isNotNull);
        expect(received!.brightness, 0.0);
      },
    );

    testWidgets(
      'displays current param values in labels',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          _wrap(
            GpuControlsSidebar(
              params: ProcessingParams(brightness: 0.5),
              onChanged: (_) {},
            ),
          ),
        );

        expect(find.text('0.50'), findsOneWidget);
      },
    );
  });
}
