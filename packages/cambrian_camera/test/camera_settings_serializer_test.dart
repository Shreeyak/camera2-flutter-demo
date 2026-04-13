import 'dart:async';

// Import the internal serializer directly (it is not part of the public API).
import 'package:cambrian_camera/src/camera_settings_serializer.dart';
import 'package:cambrian_camera/src/messages.g.dart' show CamError, CamErrorCode;
import 'package:cambrian_camera/cambrian_camera.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CameraSettingsSerializer', () {
    test('sends immediately when no call is in-flight', () async {
      final sent = <CameraSettings>[];
      // Mock onSend that completes immediately.
      final serializer = CameraSettingsSerializer(
        onSend: (s) async => sent.add(s),
      );

      serializer.send(CameraSettings(iso: AutoValue.manual(100)));
      // Allow the async completion to propagate.
      await Future<void>.delayed(Duration.zero);

      expect(sent.length, 1);
      expect((sent.first.iso as Manual<int>).value, 100);
      serializer.dispose();
    });

    test('latest value wins when a call is in-flight', () async {
      final sent = <CameraSettings>[];
      // Store the Completer so we can resolve it manually from the test.
      Completer<void>? completer;
      final serializer = CameraSettingsSerializer(
        onSend: (s) {
          sent.add(s);
          completer = Completer<void>();
          return completer!.future;
        },
      );

      // First send kicks off a call.
      serializer.send(CameraSettings(iso: AutoValue.manual(100)));
      expect(sent.length, 1); // dispatched immediately

      // Two more sends while in-flight — only the last should be pending.
      serializer.send(CameraSettings(iso: AutoValue.manual(200)));
      serializer.send(CameraSettings(iso: AutoValue.manual(300)));

      // Complete the first in-flight call.
      completer!.complete();
      await Future<void>.delayed(Duration.zero);

      // The serializer should now have sent the last pending value (300).
      expect(sent.length, 2);
      expect((sent[1].iso as Manual<int>).value, 300); // 200 was discarded
      serializer.dispose();
    });

    test('sends next pending after in-flight completes', () async {
      final sent = <CameraSettings>[];
      Completer<void>? completer;
      final serializer = CameraSettingsSerializer(
        onSend: (s) {
          sent.add(s);
          completer = Completer<void>();
          return completer!.future;
        },
      );

      serializer.send(CameraSettings(iso: AutoValue.manual(100)));
      serializer.send(CameraSettings(iso: AutoValue.manual(200))); // queued as pending

      completer!.complete(); // complete first in-flight
      await Future<void>.delayed(Duration.zero);

      expect(sent.length, 2);
      expect((sent[1].iso as Manual<int>).value, 200);
      serializer.dispose();
    });

    test('does nothing after dispose', () async {
      final sent = <CameraSettings>[];
      final serializer = CameraSettingsSerializer(
        onSend: (s) async => sent.add(s),
      );

      serializer.dispose();
      serializer.send(CameraSettings(iso: AutoValue.manual(100)));
      await Future<void>.delayed(Duration.zero);

      expect(sent, isEmpty);
    });

    test('handles onSend error without crashing', () async {
      int callCount = 0;
      final serializer = CameraSettingsSerializer(
        onSend: (s) {
          callCount++;
          return Future.error(Exception('camera error'));
        },
      );

      serializer.send(CameraSettings(iso: AutoValue.manual(100)));
      // Should not throw.
      await Future<void>.delayed(Duration.zero);
      expect(callCount, 1);
      serializer.dispose();
    });
  });

  group('CameraSettings', () {
    test('toCam encodes manual values with mode strings', () {
      const settings = CameraSettings(
        iso: AutoValue.manual(400),
        exposureTimeNs: AutoValue.manual(10000000),
        focus: AutoValue.manual(0.5),
        whiteBalance: WhiteBalance.locked(),
        zoomRatio: 2.0,
        noiseReductionMode: NoiseReductionMode.highQuality,
        edgeMode: EdgeMode.off,
        evCompensation: -2,
      );
      final cam = settings.toCam();
      expect(cam.isoMode, 'manual');
      expect(cam.iso, 400);
      expect(cam.exposureMode, 'manual');
      expect(cam.exposureTimeNs, 10000000);
      expect(cam.focusMode, 'manual');
      expect(cam.focusDistanceDiopters, 0.5);
      expect(cam.wbMode, 'locked');
      expect(cam.zoomRatio, 2.0);
      expect(cam.noiseReductionMode, 2); // NoiseReductionMode.highQuality.index
      expect(cam.edgeMode, 0);           // EdgeMode.off.index
      expect(cam.evCompensation, -2);
    });

    test('toCam encodes auto modes correctly', () {
      const settings = CameraSettings(
        iso: AutoValue.auto(),
        exposureTimeNs: AutoValue.auto(),
        focus: AutoValue.auto(),
        whiteBalance: WhiteBalance.auto(),
      );
      final cam = settings.toCam();
      expect(cam.isoMode, 'auto');
      expect(cam.iso, isNull);
      expect(cam.exposureMode, 'auto');
      expect(cam.exposureTimeNs, isNull);
      expect(cam.focusMode, 'auto');
      expect(cam.focusDistanceDiopters, isNull);
      expect(cam.wbMode, 'auto');
    });

    test('toCam encodes manual white balance gains', () {
      const settings = CameraSettings(
        whiteBalance: WhiteBalance.manual(gainR: 1.82, gainG: 1.0, gainB: 1.45),
      );
      final cam = settings.toCam();
      expect(cam.wbMode, 'manual');
      expect(cam.wbGainR, 1.82);
      expect(cam.wbGainG, 1.0);
      expect(cam.wbGainB, 1.45);
    });

    test('toCam leaves null fields as null (don\'t change)', () {
      const settings = CameraSettings(zoomRatio: 3.0);
      final cam = settings.toCam();
      expect(cam.isoMode, isNull);
      expect(cam.iso, isNull);
      expect(cam.exposureMode, isNull);
      expect(cam.focusMode, isNull);
      expect(cam.wbMode, isNull);
      expect(cam.zoomRatio, 3.0);
    });

    test('cropOutputSize round-trips through toCam', () {
      final settings = CameraSettings(
        cropOutputSize: const CameraSize(1600, 1200),
      );
      final cam = settings.toCam();
      expect(cam.cropOutputSize, isNotNull);
      expect(cam.cropOutputSize!.width, 1600);
      expect(cam.cropOutputSize!.height, 1200);
    });

    test('cropOutputSize null by default', () {
      final settings = CameraSettings();
      expect(settings.toCam().cropOutputSize, isNull);
    });
  });

  group('ProcessingParams', () {
    test('defaults are identity (no processing)', () {
      final p = ProcessingParams();
      expect(p.gamma, 1.0);
      expect(p.brightness, 0.0);
      expect(p.contrast, 0.0);
      expect(p.saturation, 0.0);
      expect(p.blackR, 0.0);
    });

    test('copyWith overrides only specified fields', () {
      final original = ProcessingParams(gamma: 2.2, brightness: 0.1);
      final copy = original.copyWith(gamma: 1.0);
      expect(copy.gamma, 1.0);
      expect(copy.brightness, 0.1); // unchanged
    });

    test('toCam preserves all fields', () {
      final p = ProcessingParams(
        blackR: 0.05,
        blackG: 0.04,
        blackB: 0.06,
        gamma: 2.2,
        brightness: 0.1,
        saturation: 0.8,
        contrast: 0.5,
      );
      final cam = p.toCam();
      expect(cam.blackR, 0.05);
      expect(cam.gamma, 2.2);
      expect(cam.saturation, 0.8);
      expect(cam.contrast, 0.5);
    });

    test('contrast defaults to 0.0', () {
      expect(ProcessingParams().contrast, 0.0);
    });

    test('copyWith overrides contrast', () {
      expect(ProcessingParams().copyWith(contrast: 0.5).contrast, 0.5);
    });

    test('toCam includes contrast', () {
      expect(ProcessingParams(contrast: 0.5).toCam().contrast, 0.5);
    });

    test('contrast NaN throws', () {
      expect(
        () => ProcessingParams(contrast: double.nan),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('NaN throws for all fields', () {
      for (final ctor in <Function>[
        () => ProcessingParams(brightness: double.nan),
        () => ProcessingParams(saturation: double.nan),
        () => ProcessingParams(gamma: double.nan),
        () => ProcessingParams(blackR: double.nan),
        () => ProcessingParams(blackG: double.nan),
        () => ProcessingParams(blackB: double.nan),
      ]) {
        expect(ctor, throwsA(isA<ArgumentError>()));
      }
    });

    test('boundary values are accepted', () {
      // All at their documented min/max — must not throw.
      expect(ProcessingParams(brightness: -1.0).brightness, -1.0);
      expect(ProcessingParams(brightness: 1.0).brightness, 1.0);
      expect(ProcessingParams(contrast: -1.0).contrast, -1.0);
      expect(ProcessingParams(contrast: 1.0).contrast, 1.0);
      expect(ProcessingParams(saturation: -1.0).saturation, -1.0);
      expect(ProcessingParams(saturation: 1.0).saturation, 1.0);
      expect(ProcessingParams(gamma: 0.1).gamma, 0.1);
      expect(ProcessingParams(gamma: 4.0).gamma, 4.0);
      expect(ProcessingParams(blackR: 0.0).blackR, 0.0);
      expect(ProcessingParams(blackR: 0.5).blackR, 0.5);
      expect(ProcessingParams(blackG: 0.0).blackG, 0.0);
      expect(ProcessingParams(blackG: 0.5).blackG, 0.5);
      expect(ProcessingParams(blackB: 0.0).blackB, 0.0);
      expect(ProcessingParams(blackB: 0.5).blackB, 0.5);
    });

    test('out-of-range values throw', () {
      for (final ctor in <Function>[
        () => ProcessingParams(brightness: -1.001),
        () => ProcessingParams(brightness: 1.001),
        () => ProcessingParams(contrast: -1.001),
        () => ProcessingParams(contrast: 1.001),
        () => ProcessingParams(saturation: -1.001),
        () => ProcessingParams(saturation: 1.001),
        () => ProcessingParams(gamma: 0.09),
        () => ProcessingParams(gamma: 4.01),
        () => ProcessingParams(blackR: -0.01),
        () => ProcessingParams(blackR: 0.51),
        () => ProcessingParams(blackG: -0.01),
        () => ProcessingParams(blackG: 0.51),
        () => ProcessingParams(blackB: -0.01),
        () => ProcessingParams(blackB: 0.51),
      ]) {
        expect(ctor, throwsA(isA<ArgumentError>()));
      }
    });

    test('identity roundtrip through toCam', () {
      final cam = ProcessingParams().toCam();
      expect(cam.brightness, 0.0);
      expect(cam.contrast, 0.0);
      expect(cam.saturation, 0.0);
      expect(cam.gamma, 1.0);
      expect(cam.blackR, 0.0);
      expect(cam.blackG, 0.0);
      expect(cam.blackB, 0.0);
    });
  });

  group('CameraState', () {
    test('parses all known state strings', () {
      expect(CameraState.fromString('closed'), CameraState.closed);
      expect(CameraState.fromString('opening'), CameraState.opening);
      expect(CameraState.fromString('streaming'), CameraState.streaming);
      expect(CameraState.fromString('recovering'), CameraState.recovering);
      expect(CameraState.fromString('paused'), CameraState.paused);
      expect(CameraState.fromString('suspended'), CameraState.suspended);
      expect(CameraState.fromString('error'), CameraState.error);
    });

    test('unknown string falls back to error', () {
      expect(CameraState.fromString('unknown_value'), CameraState.error);
    });
  });

  group('CameraErrorCode', () {
    test('typedef matches Pigeon CamErrorCode values', () {
      // CameraErrorCode is a typedef for CamErrorCode — verify the alias
      // exposes the expected variants without fromString indirection.
      expect(CameraErrorCode.cameraDevice, CamErrorCode.cameraDevice);
      expect(CameraErrorCode.permissionDenied, CamErrorCode.permissionDenied);
      expect(CameraErrorCode.unknown, CamErrorCode.unknown);
    });

    test('CameraError.fromPigeon maps code directly', () {
      final pigeon = CamError(
        code: CamErrorCode.configurationFailed,
        message: 'test',
        isFatal: false,
      );
      final err = CameraError.fromPigeon(pigeon);
      expect(err.code, CameraErrorCode.configurationFailed);
      expect(err.isFatal, false);
    });
  });
}
