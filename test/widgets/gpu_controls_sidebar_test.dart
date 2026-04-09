import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cambrian_camera/cambrian_camera.dart'
    show ProcessingParams, WhiteBalance;
import 'package:camera2_flutter_demo/widgets/bottom_bar_buttons.dart'
    show CameraAutoToggleButton;
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
            wbMode: const WhiteBalance.auto(),
            lastWbGains: null,
            bbLocked: false,
            lastBbValues: null,
            isCalibrating: false,
            calibrationTarget: null,
            calibrationIteration: 0,
            onWbToggle: () {},
            onBbToggle: () {},
            onStartCalibration: (_) {},
            onCapture: () {},
              onResetAll: () {},
          ),
        ),
      );

      expect(find.text('Calibrate Color'), findsOneWidget);
      expect(find.text('WHITE BALANCE'), findsOneWidget);
      expect(find.text('BLACK BALANCE'), findsOneWidget);
      expect(find.text('Brightness'), findsOneWidget);
      expect(find.text('Contrast'), findsOneWidget);
      expect(find.text('Saturation'), findsOneWidget);
      expect(find.text('Gamma'), findsOneWidget);
    });

    testWidgets('brightness slider calls onChanged with updated brightness', (
      WidgetTester tester,
    ) async {
      ProcessingParams? received;

      await tester.pumpWidget(
        _wrap(
          GpuControlsSidebar(
            params: ProcessingParams(),
            onChanged: (p) => received = p,
            wbMode: const WhiteBalance.auto(),
            lastWbGains: null,
            bbLocked: false,
            lastBbValues: null,
            isCalibrating: false,
            calibrationTarget: null,
            calibrationIteration: 0,
            onWbToggle: () {},
            onBbToggle: () {},
            onStartCalibration: (_) {},
            onCapture: () {},
              onResetAll: () {},
          ),
        ),
      );

      // Brightness is the first Slider in the widget.
      await tester.drag(find.byType(Slider).first, const Offset(20, 0));
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.brightness, isNot(0.0));
    });

    testWidgets('contrast slider calls onChanged with updated contrast', (
      WidgetTester tester,
    ) async {
      ProcessingParams? received;

      await tester.pumpWidget(
        _wrap(
          GpuControlsSidebar(
            params: ProcessingParams(),
            onChanged: (p) => received = p,
            wbMode: const WhiteBalance.auto(),
            lastWbGains: null,
            bbLocked: false,
            lastBbValues: null,
            isCalibrating: false,
            calibrationTarget: null,
            calibrationIteration: 0,
            onWbToggle: () {},
            onBbToggle: () {},
            onStartCalibration: (_) {},
            onCapture: () {},
              onResetAll: () {},
          ),
        ),
      );

      // Contrast is the second Slider.
      await tester.drag(find.byType(Slider).at(1), const Offset(20, 0));
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.contrast, isNot(0.0));
    });

    testWidgets('saturation slider calls onChanged with updated saturation', (
      WidgetTester tester,
    ) async {
      ProcessingParams? received;

      await tester.pumpWidget(
        _wrap(
          GpuControlsSidebar(
            params: ProcessingParams(),
            onChanged: (p) => received = p,
            wbMode: const WhiteBalance.auto(),
            lastWbGains: null,
            bbLocked: false,
            lastBbValues: null,
            isCalibrating: false,
            calibrationTarget: null,
            calibrationIteration: 0,
            onWbToggle: () {},
            onBbToggle: () {},
            onStartCalibration: (_) {},
            onCapture: () {},
              onResetAll: () {},
          ),
        ),
      );

      // Saturation is the third Slider.
      await tester.drag(find.byType(Slider).at(2), const Offset(20, 0));
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.saturation, isNot(0.0));
    });

    testWidgets('gamma slider calls onChanged with updated gamma', (
      WidgetTester tester,
    ) async {
      ProcessingParams? received;

      await tester.pumpWidget(
        _wrap(
          GpuControlsSidebar(
            params: ProcessingParams(),
            onChanged: (p) => received = p,
            wbMode: const WhiteBalance.auto(),
            lastWbGains: null,
            bbLocked: false,
            lastBbValues: null,
            isCalibrating: false,
            calibrationTarget: null,
            calibrationIteration: 0,
            onWbToggle: () {},
            onBbToggle: () {},
            onStartCalibration: (_) {},
            onCapture: () {},
              onResetAll: () {},
          ),
        ),
      );

      // Gamma is the fourth Slider.
      await tester.drag(find.byType(Slider).at(3), const Offset(20, 0));
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.gamma, isNot(1.0));
    });

    testWidgets('BB section shows Calibrate button when bbLocked is false', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          GpuControlsSidebar(
            params: ProcessingParams(),
            onChanged: (_) {},
            wbMode: const WhiteBalance.auto(),
            lastWbGains: null,
            bbLocked: false,
            lastBbValues: null,
            isCalibrating: false,
            calibrationTarget: null,
            calibrationIteration: 0,
            onWbToggle: () {},
            onBbToggle: () {},
            onStartCalibration: (_) {},
            onCapture: () {},
              onResetAll: () {},
          ),
        ),
      );

      // Both WB and BB sections show a Calibrate button when not calibrating.
      expect(find.text('Calibrate'), findsNWidgets(2));
    });

    testWidgets(
      'BB section shows status line when bbLocked and lastBbValues is non-null',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          _wrap(
            GpuControlsSidebar(
              params: ProcessingParams(),
              onChanged: (_) {},
              wbMode: const WhiteBalance.auto(),
              lastWbGains: null,
              bbLocked: true,
              lastBbValues: (0.012, 0.034, 0.056),
              isCalibrating: false,
              calibrationTarget: null,
              calibrationIteration: 0,
              onWbToggle: () {},
              onBbToggle: () {},
              onStartCalibration: (_) {},
              onCapture: () {},
              onResetAll: () {},
            ),
          ),
        );

        expect(find.text('R 0.012  G 0.034  B 0.056'), findsOneWidget);
      },
    );

    testWidgets('BB section calls onBbToggle when toggle button is tapped', (
      WidgetTester tester,
    ) async {
      var toggled = false;

      await tester.pumpWidget(
        _wrap(
          GpuControlsSidebar(
            params: ProcessingParams(),
            onChanged: (_) {},
            wbMode: const WhiteBalance.auto(),
            lastWbGains: null,
            bbLocked: false,
            lastBbValues: null,
            isCalibrating: false,
            calibrationTarget: null,
            calibrationIteration: 0,
            onWbToggle: () {},
            onBbToggle: () => toggled = true,
            onStartCalibration: (_) {},
            onCapture: () {},
              onResetAll: () {},
          ),
        ),
      );

      // The BB toggle is the second CameraAutoToggleButton in the tree.
      await tester.tap(find.byType(CameraAutoToggleButton).at(1));
      await tester.pump();

      expect(toggled, isTrue);
    });

    testWidgets('reset button invokes onResetAll', (
      WidgetTester tester,
    ) async {
      bool resetAllCalled = false;

      await tester.pumpWidget(
        _wrap(
          GpuControlsSidebar(
            params: ProcessingParams(brightness: 0.5, blackR: 0.1),
            onChanged: (_) {},
            wbMode: const WhiteBalance.auto(),
            lastWbGains: null,
            bbLocked: false,
            lastBbValues: null,
            isCalibrating: false,
            calibrationTarget: null,
            calibrationIteration: 0,
            onWbToggle: () {},
            onBbToggle: () {},
            onStartCalibration: (_) {},
            onCapture: () {},
            onResetAll: () => resetAllCalled = true,
          ),
        ),
      );

      await tester.tap(find.text('Reset all'));
      await tester.pump();

      // Reset all delegates entirely to onResetAll so the parent can clear
      // WB, BB, and all GPU sliders together.
      expect(resetAllCalled, isTrue);
    });

    testWidgets('tapping value label resets that slider to default', (
      WidgetTester tester,
    ) async {
      ProcessingParams? received;
      final initial = ProcessingParams(brightness: 0.5);

      await tester.pumpWidget(
        _wrap(
          GpuControlsSidebar(
            params: initial,
            onChanged: (p) => received = p,
            wbMode: const WhiteBalance.auto(),
            lastWbGains: null,
            bbLocked: false,
            lastBbValues: null,
            isCalibrating: false,
            calibrationTarget: null,
            calibrationIteration: 0,
            onWbToggle: () {},
            onBbToggle: () {},
            onStartCalibration: (_) {},
            onCapture: () {},
              onResetAll: () {},
          ),
        ),
      );

      // The brightness value label shows '0.50'; tapping it resets to 0.0.
      await tester.tap(find.text('0.50'));
      await tester.pump();

      expect(received, isNotNull);
      expect(received!.brightness, 0.0);
    });

    testWidgets('displays current param values in labels', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          GpuControlsSidebar(
            params: ProcessingParams(brightness: 0.5),
            onChanged: (_) {},
            wbMode: const WhiteBalance.auto(),
            lastWbGains: null,
            bbLocked: false,
            lastBbValues: null,
            isCalibrating: false,
            calibrationTarget: null,
            calibrationIteration: 0,
            onWbToggle: () {},
            onBbToggle: () {},
            onStartCalibration: (_) {},
            onCapture: () {},
              onResetAll: () {},
          ),
        ),
      );

      expect(find.text('0.50'), findsOneWidget);
    });
  });
}
