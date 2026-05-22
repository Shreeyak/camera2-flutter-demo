// Integration tests for iOS file-path contracts on recording and capture.
//
// These tests run on a physical device (or simulator) via:
//
//   flutter test integration_test/recording_path_test.dart \
//     --device-id DEVICE_ID
//
// What is verified:
//   1. captureImage() returns a bare POSIX path in filePath (no file:// scheme),
//      and the file exists at that path.
//   2. captureNaturalPicture() — same contract.
//   3. startRecording() returns a (uri, displayName) tuple where uri is a
//      bare path and displayName is the filename.
//   4. stopRecording() returns the same bare path and the file exists on disk.
//   5. All returned paths begin with / and do not contain a file:// scheme.
import 'dart:io' show File;

import 'package:cambrian_camera/cambrian_camera.dart'
    show
        CambrianCamera,
        CameraSettings,
        AutoValue,
        WhiteBalance,
        CameraState;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late CambrianCamera camera;

  setUpAll(() async {
    // Request camera permission — only prompts on the first run; subsequent
    // runs return the remembered status without showing UI.
    final status = await CambrianCamera.requestCameraPermission();
    if (status != 'authorized') {
      throw Exception(
        'Camera permission not granted (status: $status). '
        'Grant camera access in Settings and rerun.',
      );
    }

    camera = await CambrianCamera.open(
      settings: const CameraSettings(
        iso: AutoValue<int>.auto(),
        exposureTimeNs: AutoValue<int>.auto(),
        focus: AutoValue<double>.auto(),
        whiteBalance: WhiteBalance.auto(),
      ),
    );

    // Wait until the camera is actively streaming before any capture call.
    // On a real device this is typically < 1 s, but allow up to 10 s for
    // slow hardware or permission-grant delays.
    await camera.stateStream
        .firstWhere((s) => s == CameraState.streaming)
        .timeout(const Duration(seconds: 10));
  });

  tearDownAll(() async {
    await camera.close();
  });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void expectBarePath(String path, {required String label}) {
    expect(
      path.startsWith('/'),
      isTrue,
      reason: '$label must be an absolute path; got "$path"',
    );
    expect(
      path.startsWith('file://'),
      isFalse,
      reason: '$label must not carry file:// scheme; got "$path"',
    );
  }

  // ---------------------------------------------------------------------------
  // captureImage
  // ---------------------------------------------------------------------------

  testWidgets('captureImage: filePath is a bare absolute path', (tester) async {
    final result = await camera.captureImage();

    final path = result.filePath;
    expect(path, isNotNull, reason: 'filePath must be populated when destination is null');
    expectBarePath(path!, label: 'captureImage filePath');
    expect(
      path.endsWith('.png') || path.endsWith('.jpg') || path.endsWith('.jpeg'),
      isTrue,
      reason: 'filePath must have an image extension; got "$path"',
    );
  });

  testWidgets('captureImage: file exists on disk at the returned path', (tester) async {
    final result = await camera.captureImage();
    final path = result.filePath!;
    expect(
      File(path).existsSync(),
      isTrue,
      reason: 'No file found at captureImage path "$path"',
    );
    // Clean up.
    File(path).deleteSync();
  });

  // ---------------------------------------------------------------------------
  // captureNaturalPicture
  // ---------------------------------------------------------------------------

  testWidgets('captureNaturalPicture: filePath is a bare absolute path', (tester) async {
    final result = await camera.captureNaturalPicture();

    final path = result.filePath;
    expect(path, isNotNull, reason: 'filePath must be populated when destination is null');
    expectBarePath(path!, label: 'captureNaturalPicture filePath');
    expect(
      path.endsWith('.jpg') || path.endsWith('.jpeg'),
      isTrue,
      reason: 'captureNaturalPicture must produce a JPEG; got "$path"',
    );
  });

  testWidgets('captureNaturalPicture: file exists on disk', (tester) async {
    final result = await camera.captureNaturalPicture();
    final path = result.filePath!;
    expect(
      File(path).existsSync(),
      isTrue,
      reason: 'No file found at captureNaturalPicture path "$path"',
    );
    File(path).deleteSync();
  });

  // ---------------------------------------------------------------------------
  // startRecording / stopRecording
  // ---------------------------------------------------------------------------

  testWidgets('startRecording: uri is a bare absolute path', (tester) async {
    final (uri, displayName) = await camera.startRecording();
    // Stop immediately — we only care about the path format here.
    await camera.stopRecording();

    expectBarePath(uri, label: 'startRecording uri');
    expect(uri.endsWith('.mp4'), isTrue, reason: 'recording uri must end in .mp4; got "$uri"');

    expect(
      displayName.isNotEmpty,
      isTrue,
      reason: 'displayName must not be empty',
    );
    expect(
      uri.endsWith(displayName),
      isTrue,
      reason: 'uri "$uri" must end with displayName "$displayName"',
    );
  });

  testWidgets('stopRecording: uri is the same bare path as startRecording', (tester) async {
    final (startUri, _) = await camera.startRecording();
    // Let a few frames through so the file has content.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final stopUri = await camera.stopRecording();

    expectBarePath(stopUri, label: 'stopRecording uri');
    expect(
      stopUri,
      equals(startUri),
      reason: 'stopRecording must return the same path as startRecording',
    );
  });

  testWidgets('stopRecording: finalized file exists on disk', (tester) async {
    final (_, _) = await camera.startRecording();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final stopUri = await camera.stopRecording();

    expect(
      File(stopUri).existsSync(),
      isTrue,
      reason: 'No file found at stopRecording path "$stopUri"',
    );
    // Clean up.
    File(stopUri).deleteSync();
  });
}
