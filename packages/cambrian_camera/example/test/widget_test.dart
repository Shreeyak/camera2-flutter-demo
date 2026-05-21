// Smoke test for the HITL harness app.
//
// Verifies the harness builds and renders its sections without a camera open —
// the camera-dependent buttons are disabled until [HitlScreen] opens one, which
// can only happen on a real device, so this test stays on the bare UI.

import 'package:flutter_test/flutter_test.dart';

import 'package:cambrian_camera_example/main.dart';

void main() {
  testWidgets('HITL harness renders its sections', (WidgetTester tester) async {
    await tester.pumpWidget(const HitlApp());

    // Assert only on content above the fold — the section list lazily builds,
    // so off-screen sections (Calibration, Diagnostics) aren't in the tree.
    expect(find.text('HITL Harness'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('open'), findsOneWidget);
    // Before a camera is open the result panel shows its initial placeholder.
    expect(find.text('(no calls yet)'), findsOneWidget);
  });
}
