import 'dart:async';

// Import the internal serializer directly (it is not part of the public API).
import 'package:cambrian_camera/src/camera_settings_serializer.dart';
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

      serializer.send(const CameraSettings(iso: 100));
      // Allow the async completion to propagate.
      await Future<void>.delayed(Duration.zero);

      expect(sent.length, 1);
      expect(sent.first.iso, 100);
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
      serializer.send(const CameraSettings(iso: 100));
      expect(sent.length, 1); // dispatched immediately

      // Two more sends while in-flight — only the last should be pending.
      serializer.send(const CameraSettings(iso: 200));
      serializer.send(const CameraSettings(iso: 300));

      // Complete the first in-flight call.
      completer!.complete();
      await Future<void>.delayed(Duration.zero);

      // The serializer should now have sent the last pending value (300).
      expect(sent.length, 2);
      expect(sent[1].iso, 300); // 200 was discarded
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

      serializer.send(const CameraSettings(iso: 100));
      serializer.send(const CameraSettings(iso: 200)); // queued as pending

      completer!.complete(); // complete first in-flight
      await Future<void>.delayed(Duration.zero);

      expect(sent.length, 2);
      expect(sent[1].iso, 200);
      serializer.dispose();
    });

    test('does nothing after dispose', () async {
      final sent = <CameraSettings>[];
      final serializer = CameraSettingsSerializer(
        onSend: (s) async => sent.add(s),
      );

      serializer.dispose();
      serializer.send(const CameraSettings(iso: 100));
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

      serializer.send(const CameraSettings(iso: 100));
      // Should not throw.
      await Future<void>.delayed(Duration.zero);
      expect(callCount, 1);
      serializer.dispose();
    });
  });

  group('CameraSettings', () {
    test('toCam preserves all fields', () {
      const settings = CameraSettings(
        iso: 400,
        exposureTimeNs: 10000000,
        focusDistanceDiopters: 0.5,
        zoomRatio: 2.0,
        afEnabled: false,
        awbLocked: true,
        noiseReductionMode: NoiseReductionMode.highQuality,
        edgeMode: EdgeMode.off,
        evCompensation: -2,
      );
      final cam = settings.toCam();
      expect(cam.iso, 400);
      expect(cam.exposureTimeNs, 10000000);
      expect(cam.focusDistanceDiopters, 0.5);
      expect(cam.zoomRatio, 2.0);
      expect(cam.afEnabled, false);
      expect(cam.awbLocked, true);
      expect(cam.noiseReductionMode, 2); // NoiseReductionMode.highQuality.index
      expect(cam.edgeMode, 0);           // EdgeMode.off.index
      expect(cam.evCompensation, -2);
    });
  });

  group('ProcessingParams', () {
    test('defaults are identity (no processing)', () {
      const p = ProcessingParams();
      expect(p.gamma, 1.0);
      expect(p.brightness, 0.0);
      expect(p.saturation, 1.0);
      expect(p.blackR, 0.0);
      expect(p.autoStretch, false);
    });

    test('copyWith overrides only specified fields', () {
      const original = ProcessingParams(gamma: 2.2, brightness: 0.1);
      final copy = original.copyWith(gamma: 1.0);
      expect(copy.gamma, 1.0);
      expect(copy.brightness, 0.1); // unchanged
    });

    test('toCam preserves all fields', () {
      const p = ProcessingParams(
        blackR: 0.05,
        blackG: 0.04,
        blackB: 0.06,
        gamma: 2.2,
        histBlackPoint: 0.02,
        histWhitePoint: 0.98,
        autoStretch: true,
        autoStretchLow: 0.01,
        autoStretchHigh: 0.99,
        brightness: 0.1,
        saturation: 1.2,
      );
      final cam = p.toCam();
      expect(cam.blackR, 0.05);
      expect(cam.gamma, 2.2);
      expect(cam.autoStretch, true);
      expect(cam.saturation, 1.2);
    });
  });

  group('CameraState', () {
    test('parses all known state strings', () {
      expect(CameraState.fromString('closed'), CameraState.closed);
      expect(CameraState.fromString('opening'), CameraState.opening);
      expect(CameraState.fromString('streaming'), CameraState.streaming);
      expect(CameraState.fromString('recovering'), CameraState.recovering);
      expect(CameraState.fromString('error'), CameraState.error);
    });

    test('unknown string falls back to error', () {
      expect(CameraState.fromString('unknown_value'), CameraState.error);
    });
  });

  group('CameraErrorCode', () {
    test('parses known error codes', () {
      expect(CameraErrorCode.fromString('camera_device'),
          CameraErrorCode.cameraDevice);
      expect(CameraErrorCode.fromString('permission_denied'),
          CameraErrorCode.permissionDenied);
      expect(CameraErrorCode.fromString('pipeline_error'),
          CameraErrorCode.pipelineError);
    });

    test('unknown code maps to unknown', () {
      expect(
          CameraErrorCode.fromString('banana'), CameraErrorCode.unknown);
    });
  });
}
