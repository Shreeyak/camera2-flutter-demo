import 'dart:async' show StreamSubscription;

import 'package:cambrian_camera/cambrian_camera.dart'
    show
        AutoValue,
        CambrianCamera,
        CamCaptureResult,
        CamPhotosDestination,
        CameraError,
        CameraSettings,
        CameraSize,
        CameraState,
        CameraTextureInfo,
        FrameResult,
        ProcessingParams,
        RecordingState,
        WhiteBalance;
import 'package:flutter/material.dart';

/// Initial settings used by the harness [CambrianCamera.open] call.
///
/// Only the processed/primary preview lane exists since the CameraKit v1.5.0
/// migration removed the live natural lane.
const _kInitialSettings = CameraSettings(
  iso: AutoValue<int>.auto(),
  exposureTimeNs: AutoValue<int>.auto(),
  focus: AutoValue<double>.auto(),
  whiteBalance: WhiteBalance.auto(),
);

/// Preset crop output size used by the setCropRegion test (case 6). Cleared by
/// sending the full sensor size back, which the plugin treats as "no crop".
const _kCropPreset = CameraSize(1600, 1200);

/// Hardware-in-the-loop verification harness.
///
/// One button per [CambrianCamera] host method plus live panels fed by every
/// FlutterApi stream. UX is intentionally minimal: this screen exists to
/// exercise and observe the plugin contract on a physical device, not to look
/// good. See `docs/superpowers/plans/2026-05-18-phase-3-plan-4-hitl-and-polish.md`.
class HitlScreen extends StatefulWidget {
  const HitlScreen({super.key});

  @override
  State<HitlScreen> createState() => _HitlScreenState();
}

class _HitlScreenState extends State<HitlScreen> {
  CambrianCamera? _camera;

  // ── Latest values from the FlutterApi streams ──────────────────────────────
  CameraState? _state;
  CameraError? _lastError;
  FrameResult? _lastFrame;
  RecordingState? _recordingState;
  CameraTextureInfo? _previewTex;

  // ── Last host-method call outcome (shown in the result panel) ──────────────
  String _result = '(no calls yet)';
  bool _busy = false;

  // ── Test-state cursors ─────────────────────────────────────────────────────
  int _resIndex = 0;
  bool _cropOn = false;

  StreamSubscription<CameraState>? _stateSub;
  StreamSubscription<CameraError>? _errorSub;
  StreamSubscription<FrameResult>? _frameSub;
  StreamSubscription<RecordingState>? _recordingSub;
  StreamSubscription<CameraTextureInfo>? _previewTexSub;

  // App-lifecycle (background/foreground) is driven entirely by the plugin's
  // native observers — iOS `LifecycleObserver` (UIScene scene-phase) and
  // Android `ProcessLifecycleOwner` — which run the full suspend/resume
  // sequence. App code must NOT also drive it from `didChangeAppLifecycleState`
  // (that double-drove the engine and, on iOS, left the session running long
  // enough for the background FSM crash; see
  // measurements/phase-3-hitl/2026-05-20/notes.md "Engine bugs" §1).

  @override
  void dispose() {
    // Mirror the repo-root CameraScreen teardown: cancel every subscription,
    // then close the native session in a catchError so a late failure cannot
    // throw out of dispose(). Clean disposal is what makes the hot-restart
    // matrix case (#18) observable — leaked texture IDs would survive restart.
    _stateSub?.cancel();
    _errorSub?.cancel();
    _frameSub?.cancel();
    _recordingSub?.cancel();
    _previewTexSub?.cancel();
    _camera?.close().catchError((Object e) {
      debugPrint('HITL: camera.close failed during dispose: $e');
    });
    super.dispose();
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Call plumbing
  // ───────────────────────────────────────────────────────────────────────────

  /// Runs [action], showing its result (or error) in the result panel.
  ///
  /// Serializes calls behind [_busy] so a slow host method cannot be re-entered
  /// by an impatient double-tap during verification.
  Future<void> _run(String label, Future<Object?> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _result = '$label …';
    });
    try {
      final value = await action();
      if (!mounted) return;
      setState(() => _result = '$label ✓\n${value ?? '(void)'}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _result = '$label ✗\n$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open() => _run('open', () async {
    if (_camera != null) return 'already open — close first';
    final status = await CambrianCamera.requestCameraPermission();
    if (status != 'authorized') return 'permission not granted: $status';
    final camera = await CambrianCamera.open(settings: _kInitialSettings);
    _stateSub = camera.stateStream.listen((s) {
      if (mounted) setState(() => _state = s);
    });
    _errorSub = camera.errorStream.listen((e) {
      if (mounted) setState(() => _lastError = e);
    });
    _frameSub = camera.frameResultStream.listen((f) {
      if (mounted) setState(() => _lastFrame = f);
    });
    _recordingSub = camera.recordingStateStream.listen((r) {
      if (mounted) setState(() => _recordingState = r);
    });
    _previewTexSub = camera.toneMappedTexture.listen((t) {
      if (mounted) setState(() => _previewTex = t);
    });
    final caps = camera.capabilities;
    setState(() {
      _camera = camera;
      _state = camera.state;
      _resIndex = 0;
      _cropOn = false;
    });
    return 'stream=${caps.streamWidth}x${caps.streamHeight} '
        'fmt=${caps.streamPixelFormat} '
        '(use getNativePipelineHandle for the pipeline pointer)';
  });

  Future<void> _close() => _run('close', () async {
    final camera = _camera;
    if (camera == null) return 'no camera open';
    await _stateSub?.cancel();
    await _errorSub?.cancel();
    await _frameSub?.cancel();
    await _recordingSub?.cancel();
    await _previewTexSub?.cancel();
    await camera.close();
    setState(() {
      _camera = null;
      _state = null;
      _previewTex = null;
      _lastFrame = null;
      _recordingState = null;
    });
    return 'closed';
  });

  Future<void> _cycleResolution() => _run('setResolution', () async {
    final camera = _camera!;
    final sizes = camera.capabilities.supportedSizes;
    if (sizes.isEmpty) return 'no supported sizes reported';
    _resIndex = (_resIndex + 1) % sizes.length;
    final size = sizes[_resIndex];
    await camera.setResolution(size.width, size.height);
    return '→ ${size.width}x${size.height} '
        '(${_resIndex + 1}/${sizes.length})';
  });

  Future<void> _toggleCrop() => _run('setCropRegion', () async {
    final camera = _camera!;
    final caps = camera.capabilities;
    final next = !_cropOn;
    final sensor = CameraSize(caps.sensorStreamWidth, caps.sensorStreamHeight);
    await camera.updateSettings(
      CameraSettings(cropOutputSize: next ? _kCropPreset : sensor),
    );
    setState(() => _cropOn = next);
    return next ? 'crop set ${_kCropPreset.width}x${_kCropPreset.height}'
                : 'crop cleared → ${sensor.width}x${sensor.height}';
  });

  Future<void> _capture({
    required bool natural,
    required bool toLibrary,
  }) {
    final label = '${natural ? 'captureNaturalPicture' : 'captureImage'}'
        '(${toLibrary ? 'Photos' : 'file'})';
    return _run(label, () async {
      final camera = _camera!;
      final dest = CamPhotosDestination(saveToLibrary: toLibrary);
      final CamCaptureResult r = natural
          ? await camera.captureNaturalPicture(destination: dest)
          : await camera.captureImage(destination: dest);
      return toLibrary
          ? 'phAssetLocalId=${r.phAssetLocalId}'
          : 'filePath=${r.filePath}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final open = _camera != null;
    return Scaffold(
      appBar: AppBar(title: const Text('HITL Harness')),
      body: Column(
        children: [
          _previewStrip(),
          _statusPanel(),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                _section('Permissions', [
                  _btn('cameraPermissionStatus', () => _run(
                        'cameraPermissionStatus',
                        CambrianCamera.cameraPermissionStatus,
                      )),
                  _btn('requestCameraPermission', () => _run(
                        'requestCameraPermission',
                        CambrianCamera.requestCameraPermission,
                      )),
                  _btn('photosAddPermissionStatus', () => _run(
                        'photosAddPermissionStatus',
                        CambrianCamera.photosAddPermissionStatus,
                      )),
                  _btn('requestPhotosAddPermission', () => _run(
                        'requestPhotosAddPermission',
                        CambrianCamera.requestPhotosAddPermission,
                      )),
                ]),
                _section('Lifecycle', [
                  _btn('open', _open, enabled: !open),
                  _btn('close', _close, enabled: open),
                ]),
                _section('Settings', [
                  _btn('updateSettings: manual ISO 400', () => _run(
                        'updateSettings ISO',
                        () => _camera!.updateSettings(
                          const CameraSettings(iso: AutoValue.manual(400)),
                        ),
                      ), enabled: open),
                  _btn('updateSettings: manual exposure 10ms', () => _run(
                        'updateSettings exposure',
                        () => _camera!.updateSettings(
                          const CameraSettings(
                            exposureTimeNs: AutoValue.manual(10000000),
                          ),
                        ),
                      ), enabled: open),
                  _btn('updateSettings: manual ISO+exp (one call)', () => _run(
                        'updateSettings ISO+exp',
                        () => _camera!.updateSettings(
                          const CameraSettings(
                            iso: AutoValue.manual(400),
                            exposureTimeNs: AutoValue.manual(10000000),
                          ),
                        ),
                      ), enabled: open),
                  _btn('updateSettings: manual WB', () => _run(
                        'updateSettings WB',
                        () => _camera!.updateSettings(
                          const CameraSettings(
                            whiteBalance: WhiteBalance.manual(
                              gainR: 1.8,
                              gainG: 1.0,
                              gainB: 1.5,
                            ),
                          ),
                        ),
                      ), enabled: open),
                  _btn('updateSettings: all auto', () => _run(
                        'updateSettings auto',
                        () => _camera!.updateSettings(
                          const CameraSettings(
                            iso: AutoValue.auto(),
                            exposureTimeNs: AutoValue.auto(),
                            whiteBalance: WhiteBalance.auto(),
                          ),
                        ),
                      ), enabled: open),
                  _btn('setProcessingParams: brightness +0.2', () => _run(
                        'setProcessingParams',
                        () => _camera!.setProcessingParams(
                          ProcessingParams(brightness: 0.2),
                        ),
                      ), enabled: open),
                  _btn('setResolution (cycle)', _cycleResolution,
                      enabled: open),
                  _btn(_cropOn ? 'setCropRegion: clear' : 'setCropRegion: set',
                      _toggleCrop, enabled: open),
                ]),
                _section('Capabilities', [
                  _btn('getCapabilities (cached)', () => _run(
                        'getCapabilities',
                        () async {
                          final c = _camera!.capabilities;
                          return '${c.streamWidth}x${c.streamHeight} '
                              'fmt=${c.streamPixelFormat} '
                              'iso=${c.isoMin}-${c.isoMax} '
                              'sizes=${c.supportedSizes.length}';
                        },
                      ), enabled: open),
                  _btn('getPersistedProcessingParams', () => _run(
                        'getPersistedProcessingParams',
                        () async => _camera!.getPersistedProcessingParams(),
                      ), enabled: open),
                ]),
                _section('Capture', [
                  _btn('captureImage → file',
                      () => _capture(natural: false, toLibrary: false),
                      enabled: open),
                  _btn('captureImage → Photos',
                      () => _capture(natural: false, toLibrary: true),
                      enabled: open),
                  _btn('captureNaturalPicture → file',
                      () => _capture(natural: true, toLibrary: false),
                      enabled: open),
                  _btn('captureNaturalPicture → Photos',
                      () => _capture(natural: true, toLibrary: true),
                      enabled: open),
                ]),
                _section('Recording', [
                  _btn('startRecording', () => _run(
                        'startRecording',
                        () async {
                          final (uri, name) = await _camera!.startRecording();
                          return 'uri=$uri name=$name';
                        },
                      ), enabled: open),
                  _btn('stopRecording', () => _run(
                        'stopRecording',
                        _camera!.stopRecording,
                      ), enabled: open),
                ]),
                _section('Calibration (iOS host method)', [
                  _btn('calibrateWhiteBalance', () => _run(
                        'calibrateWhiteBalance',
                        () async {
                          final r = await _camera!.calibrateWhiteBalance();
                          return 'gains=${r.gains}\nbefore=${r.patchBefore}\n'
                              'after=${r.patchAfter}';
                        },
                      ), enabled: open),
                  _btn('calibrateBlackBalance', () => _run(
                        'calibrateBlackBalance',
                        () async {
                          final r = await _camera!.calibrateBlackBalance(
                            params: ProcessingParams(),
                          );
                          return 'offsets=${r.offsets}\nbefore=${r.patchBefore}\n'
                              'after=${r.patchAfter}';
                        },
                      ), enabled: open),
                ]),
                _section('Diagnostics', [
                  _btn('sampleCenterPatch', () => _run(
                        'sampleCenterPatch',
                        () async => _camera!.sampleCenterPatch(),
                      ), enabled: open),
                  _btn('getNativePipelineHandle', () => _run(
                        'getNativePipelineHandle',
                        () async {
                          final h = await _camera!.getNativePipelineHandle();
                          return h == null
                              ? 'null'
                              : '0x${h.toRadixString(16)}';
                        },
                      ), enabled: open),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ───────────────────────────────────────────────────────────────────────────
  // Widgets
  // ───────────────────────────────────────────────────────────────────────────

  /// Side-by-side processed / raw texture lanes with a banner explaining that
  /// blank output is a known texture-bridge bug, not a harness fault.
  Widget _previewStrip() {
    return SizedBox(
      height: 160,
      child: Column(
        children: [
          Container(
            width: double.infinity,
            color: Colors.amber.shade900,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: const Text(
              'iOS: processed (left) lane renders; raw (right) lane shows '
              'nothing — the engine does not allocate a texture for it. '
              'Backgrounding the app currently crashes the engine (FSM bug). '
              'Non-preview buttons exercise their host methods.',
              style: TextStyle(fontSize: 11, color: Colors.white),
            ),
          ),
          Expanded(
            child: _lane('processed', _previewTex),
          ),
        ],
      ),
    );
  }

  Widget _lane(String label, CameraTextureInfo? tex) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(
          color: Colors.black,
          child: tex == null
              ? const SizedBox.shrink()
              : FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: tex.width.toDouble(),
                    height: tex.height.toDouble(),
                    child: Texture(textureId: tex.textureId),
                  ),
                ),
        ),
        Positioned(
          left: 4,
          top: 4,
          child: Text(
            '$label${tex == null ? '' : ' #${tex.textureId}'}',
            style: const TextStyle(fontSize: 10, color: Colors.white70),
          ),
        ),
      ],
    );
  }

  /// Compact panel showing the latest value from every FlutterApi stream plus
  /// the most recent host-method call outcome.
  Widget _statusPanel() {
    final f = _lastFrame;
    final err = _lastError;
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.all(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('state: ${_state?.name ?? '—'}   '
              'recording: ${_recordingState?.name ?? '—'}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
          Text(
            'frame: ${f == null ? '—' : 'iso=${f.iso} exp=${f.exposureTimeNs} '
                'wb=(${f.wbGainR},${f.wbGainG},${f.wbGainB})'}',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          Text(
            'error: ${err == null ? '—' : '${err.code} ${err.message}'}',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: err == null
                  ? null
                  : (err.isFatal ? Colors.red : Colors.orange),
            ),
          ),
          const SizedBox(height: 4),
          Text(_result,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(title,
              style: Theme.of(context).textTheme.titleSmall),
        ),
        Wrap(spacing: 8, runSpacing: 4, children: children),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _btn(String label, VoidCallback onPressed, {bool enabled = true}) {
    return ElevatedButton(
      onPressed: (enabled && !_busy) ? onPressed : null,
      child: Text(label),
    );
  }
}
