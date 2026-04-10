import 'dart:async' show StreamSubscription, unawaited;
import 'dart:math' show max;

import 'package:cambrian_camera/cambrian_camera.dart'
    show
        AutoValue,
        CambrianCamera,
        CameraError,
        CameraErrorCode,
        CameraSettings,
        CameraSize,
        CameraTextureInfo,
        FrameResult,
        ProcessingParams,
        RgbSample,
        quarterTurnsFromDisplayRotation,
        RecordingState,
        WbGains,
        WhiteBalance,
        WbAuto;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'camera/camera_callbacks.dart';
import 'camera/camera_settings_values.dart';
import 'theme/material_theme.dart';
import 'theme/theme_util.dart';
import 'widgets/bottom_bar.dart';
import 'widgets/bottom_bar_buttons.dart' show CameraAutoToggleButton;
import 'widgets/camera_control_overlay.dart'
    show CameraControlOverlay, kCameraDialMaxWidth;
import 'widgets/calibration_overlay.dart' show CalibrationOverlay;
import 'widgets/gpu_controls_sidebar.dart'
    show GpuControlsSidebar, CalibrationTarget;
import 'widgets/recording_hud.dart' show RecordingHud;

/// Horizontal offset from the left edge of the dial to the auto-toggle button.
const _kAutoToggleOffset = 60.0;

/// Logical-pixel width of the GPU controls sidebar.
///
/// Wide enough to fit slider labels and numeric readouts at the default text
/// scale without truncation or crowding.
const double _kSidebarWidth = 270.0;

/// Initial camera settings used for both [CambrianCamera.open] and the UI's
/// initial [CameraSettingsValues]. Keeping them in one place ensures the two
/// can never diverge at startup.
const _kInitialSettings = CameraSettings(
  iso: AutoValue<int>.auto(),
  exposureTimeNs: AutoValue<int>.auto(),
  focus: AutoValue<double>.auto(),
  whiteBalance: WhiteBalance.auto(),
  enableRawStream: true,
  rawStreamHeight: 720,
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CameraApp());
}

class CameraApp extends StatelessWidget {
  const CameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    final textTheme = createTextTheme('Roboto', 'Noto Sans');
    final materialTheme = MaterialTheme(textTheme);
    return MaterialApp(
      title: 'Camera2 Demo',
      debugShowCheckedModeBanner: false,
      darkTheme: materialTheme.dark(),
      themeMode: ThemeMode.dark,
      home: const CameraScreen(),
    );
  }
}

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  // ── Camera state
  late CameraSettingsValues _values;
  CameraRanges _ranges = const CameraRanges();
  late final CameraCallbacks _callbacks;
  CambrianCamera? _camera;
  StreamSubscription<FrameResult>? _frameResultSub;
  StreamSubscription<CameraError>? _errorSub;

  // ── UI state
  bool _settingsDrawerOpen = false;
  CameraSettingType? _activeSetting;
  ProcessingParams _processingParams = ProcessingParams();
  bool _sidebarOpen = false;

  // ── Recording state
  bool _isRecording = false;
  bool _recordingActionInProgress = false;
  String _recordingDisplayName = '';
  static const String _recordingOutputDir = 'Movies/CambrianCamera';
  StreamSubscription<RecordingState>? _recordingStateSub;

  /// True once the first frame result with real AE values has arrived.
  /// Guards manual ISO/exposure changes to prevent a settingsConflict on open.
  bool _aeSeeded = false;

  // ── White Balance state ─────────────────────────────────────────────────
  WhiteBalance _wbMode = const WhiteBalance.auto();
  WbGains? _lastWbGains;
  // ignore: unused_field — stored for future before/after UI display
  RgbSample? _lastWbPatchBefore;
  // ignore: unused_field — stored for future before/after UI display
  RgbSample? _lastWbPatchAfter;

  // ── Black Balance state ─────────────────────────────────────────────────
  bool _bbLocked = false;
  double _lastBbR = 0.0, _lastBbG = 0.0, _lastBbB = 0.0;
  // ignore: unused_field — stored for future before/after UI display
  RgbSample? _lastBbPatchBefore;
  // ignore: unused_field — stored for future before/after UI display
  RgbSample? _lastBbPatchAfter;

  // ── Calibration flow state (shared WB/BB) ───────────────────────────────
  bool _isCalibrating = false;
  CalibrationTarget? _calibrationTarget;

  // Snapshot of WB/BB state captured at the moment calibration starts, used
  // to restore the exact prior values if the user cancels.
  WhiteBalance? _preCalibrationWbMode;
  bool? _preCalibrationBbLocked;
  double? _preCalibrationBbR;
  double? _preCalibrationBbG;
  double? _preCalibrationBbB;
  ProcessingParams? _preCalibrationProcessingParams;

  /// Most recent FrameResult — used by WB lock to read current sensor gains.
  FrameResult? _latestFrameResult;

  /// Most recent processed-preview texture info — used by [CalibrationOverlay]
  /// to scale the patch square to the correct on-screen size.
  CameraTextureInfo? _latestTextureInfo;

  /// Display rotation in degrees CW from portrait: 0, 90, 180, or 270.
  int _displayRotationDeg = 0;

  /// Current stream resolution label (e.g. "4032x3024").
  String _currentResolutionLabel = '';

  /// Available YUV stream resolutions from capabilities.
  List<CameraSize> _availableResolutions = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _values = CameraSettingsValues.fromSettings(_kInitialSettings, _ranges);
    _openCamera();
    _callbacks = CameraCallbacks(
      onIsoChanged: _onIsoChanged,
      onExposureTimeNsChanged: _onExposureTimeNsChanged,
      onFocusChanged: _onFocusChanged,
      onZoomChanged: _onZoomChanged,
      onToggleAf: _toggleAf,
    );
    _fetchRotation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frameResultSub?.cancel();
    _errorSub?.cancel();
    _recordingStateSub?.cancel();
    final camera = _camera;
    if (camera != null) {
      camera.close().catchError((Object e) {
        debugPrint('CambrianCamera.close failed during dispose: $e');
      });
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden: // screen locked or covered on Android 14+
        if (_isRecording) {
          _camera?.stopRecording().catchError((Object e) {
            debugPrint('auto-stop on background failed: $e');
            return '';
          });
        }
        _camera?.pause();
      case AppLifecycleState.resumed:
        _camera?.resume();
      default:
        break;
    }
  }

  @override
  void didChangeMetrics() {
    _fetchRotation();
  }

  Future<void> _fetchRotation() async {
    final deg = await CambrianCamera.getDisplayRotation();
    if (mounted) setState(() => _displayRotationDeg = deg);
  }

  int get _quarterTurns => quarterTurnsFromDisplayRotation(_displayRotationDeg);

  Future<void> _openCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      debugPrint('Camera permission denied: $status');
      return;
    }
    try {
      final camera = await CambrianCamera.open(settings: _kInitialSettings);
      // Restore processing params from previous session, or use identity defaults.
      // Always clear black balance on startup — applying stale offsets makes the
      // image look unexpectedly dark and confuses users.
      final persisted = await camera.getPersistedProcessingParams();
      final initialParams = (persisted ?? ProcessingParams()).copyWith(
        blackR: 0.0,
        blackG: 0.0,
        blackB: 0.0,
      );
      await camera.setProcessingParams(initialParams);
      final caps = camera.capabilities;
      final ranges = CameraRanges(
        isoMin: caps.isoMin,
        isoMax: caps.isoMax,
        exposureTimeMinNs: caps.exposureTimeMinNs,
        exposureTimeMaxNs: caps.exposureTimeMaxNs,
        focusMaxDiopters: caps.focusMax,
        minZoomRatio: caps.zoomMin,
        maxZoomRatio: caps.zoomMax,
      );
      if (!mounted) {
        // Widget was disposed while open() was in flight — close the native
        // session immediately so it isn't leaked.
        await camera.close();
        return;
      }
      setState(() {
        _camera = camera;
        _ranges = ranges;
        _values = CameraSettingsValues.fromSettings(_kInitialSettings, ranges);
        _processingParams = initialParams; // sidebar sliders reflect persisted or default values
        _availableResolutions = caps.supportedSizes;
        _currentResolutionLabel = '${caps.streamWidth}x${caps.streamHeight}';
      });
      _frameResultSub = camera.frameResultStream.listen(_onFrameResult);
      _errorSub = camera.errorStream.listen(_onCameraError);
      _recordingStateSub = camera.recordingStateStream.listen((state) {
        if (!mounted) return;
        // Only update _isRecording for idle/error — the recording=true case is
        // batched with _recordingDisplayName in _toggleRecording to avoid a
        // frame where _isRecording is true but displayName is still empty.
        if (state != RecordingState.recording) {
          setState(() => _isRecording = false);
        }
      });
      _fetchRotation();
    } catch (e) {
      // Camera may not be available in all environments (e.g. emulators).
      // The UI degrades gracefully to a black placeholder.
      debugPrint('CambrianCamera.open failed: $e');
    }
  }

  // ── Camera setting callbacks

  /// Sends only the changed setting to the camera.
  ///
  /// The plugin accumulates settings on the Kotlin side, so we only need to
  /// send the fields that actually changed — omitted fields (null) keep their
  /// previous values.
  void _applySettings(CameraSettings settings) {
    _camera?.updateSettings(settings);
  }

  void _applyProcessingParams(ProcessingParams params) {
    setState(() => _processingParams = params);
    _camera?.setProcessingParams(params);
  }

  void _toggleAf() {
    final nowAf = !_values.afEnabled;
    setState(() => _values = _values.copyWith(afEnabled: nowAf));
    _applySettings(
      CameraSettings(
        focus: nowAf
            ? const AutoValue.auto()
            : AutoValue.manual(_values.focusDiopters),
      ),
    );
  }

  // ── WB / BB handlers ────────────────────────────────────────────────────

  void _onWbToggle() {
    if (_isCalibrating) return;
    if (_wbMode is WbAuto) {
      // Lock: freeze AWB at its current state via CONTROL_AWB_LOCK.
      // Using WbLocked (not WbManual) preserves the ISP's color correction matrix
      // alongside the gains, so the image does not shift when the lock is applied.
      final gainR = _latestFrameResult?.wbGainR ?? 1.0;
      final gainG = _latestFrameResult?.wbGainG ?? 1.0;
      final gainB = _latestFrameResult?.wbGainB ?? 1.0;
      setState(() {
        _wbMode = const WhiteBalance.locked();
        _lastWbGains = (r: gainR, g: gainG, b: gainB);
      });
      _applySettings(const CameraSettings(whiteBalance: WhiteBalance.locked()));
    } else {
      // Unlock: return to auto AWB.
      setState(() => _wbMode = const WhiteBalance.auto());
      _applySettings(const CameraSettings(whiteBalance: WhiteBalance.auto()));
    }
  }

  void _onBbToggle() {
    if (_isCalibrating) return;
    if (_bbLocked) {
      // Unlock: reset black offsets to zero.
      setState(() => _bbLocked = false);
      _applyProcessingParams(
        _processingParams.copyWith(blackR: 0.0, blackG: 0.0, blackB: 0.0),
      );
    } else {
      // Lock: apply last calibrated black offsets.
      setState(() => _bbLocked = true);
      _applyProcessingParams(
        _processingParams.copyWith(
          blackR: _lastBbR,
          blackG: _lastBbG,
          blackB: _lastBbB,
        ),
      );
    }
  }

  void _onResetAll() {
    // Reset all sliders, WB, and BB to factory defaults.
    _applyProcessingParams(ProcessingParams());
    setState(() {
      _wbMode = const WhiteBalance.auto();
      _lastWbGains = null;
      _lastWbPatchBefore = null;
      _lastWbPatchAfter = null;
      _bbLocked = false;
      _lastBbR = 0.0;
      _lastBbG = 0.0;
      _lastBbB = 0.0;
    });
    _applySettings(const CameraSettings(whiteBalance: WhiteBalance.auto()));
  }

  void _onStartCalibration(CalibrationTarget target) {
    // Second tap on the same target cancels calibration — restore prior state.
    if (_isCalibrating && _calibrationTarget == target) {
      final wbMode = _preCalibrationWbMode;
      final bbLocked = _preCalibrationBbLocked;
      final bbR = _preCalibrationBbR;
      final bbG = _preCalibrationBbG;
      final bbB = _preCalibrationBbB;
      final processingParams = _preCalibrationProcessingParams;

      setState(() {
        _isCalibrating = false;
        _calibrationTarget = null;
        if (wbMode != null) _wbMode = wbMode;
        if (bbLocked != null) _bbLocked = bbLocked;
        if (bbR != null) _lastBbR = bbR;
        if (bbG != null) _lastBbG = bbG;
        if (bbB != null) _lastBbB = bbB;
      });

      if (wbMode != null) {
        _applySettings(CameraSettings(whiteBalance: wbMode));
      }
      if (processingParams != null) {
        _applyProcessingParams(processingParams);
      }
      return;
    }

    // Snapshot current state before any changes so cancellation can restore it.
    _preCalibrationWbMode = _wbMode;
    _preCalibrationBbLocked = _bbLocked;
    _preCalibrationBbR = _lastBbR;
    _preCalibrationBbG = _lastBbG;
    _preCalibrationBbB = _lastBbB;
    _preCalibrationProcessingParams = _processingParams;

    setState(() {
      _isCalibrating = true;
      _calibrationTarget = target;
    });

    // Reset the calibration state so the image starts from a known baseline.
    if (target == CalibrationTarget.wb) {
      // Return to auto WB so any previous bad gains don't bias the new calibration.
      setState(() => _wbMode = const WhiteBalance.auto());
      _applySettings(const CameraSettings(whiteBalance: WhiteBalance.auto()));
    } else {
      // Clear accumulated BB offsets so the image is not stuck in a dark state.
      setState(() {
        _bbLocked = false;
        _lastBbR = 0.0;
        _lastBbG = 0.0;
        _lastBbB = 0.0;
      });
      _applyProcessingParams(
        _processingParams.copyWith(blackR: 0.0, blackG: 0.0, blackB: 0.0),
      );
    }
  }

  bool _calibrationCaptureInProgress = false;

  Future<void> _onCapture() async {
    final target = _calibrationTarget;
    if (target == null || !_isCalibrating || _calibrationCaptureInProgress) {
      return;
    }
    _calibrationCaptureInProgress = true;

    try {
      switch (target) {
        case CalibrationTarget.wb:
          await _runWbCalibration();
        case CalibrationTarget.bb:
          await _runBbCalibration();
      }
    } finally {
      _calibrationCaptureInProgress = false;
      if (mounted) {
        setState(() {
          _isCalibrating = false;
          _calibrationTarget = null;
        });
      }
    }
  }

  Future<void> _runWbCalibration() async {
    final camera = _camera;
    if (camera == null || !mounted) return;
    try {
      final result = await camera.calibrateWhiteBalance(
        initialGainR: _latestFrameResult?.wbGainR ?? 1.0,
        initialGainG: _latestFrameResult?.wbGainG ?? 1.0,
        initialGainB: _latestFrameResult?.wbGainB ?? 1.0,
      );
      if (mounted) {
        setState(() {
          _wbMode = WhiteBalance.manual(
            gainR: result.gains.r,
            gainG: result.gains.g,
            gainB: result.gains.b,
          );
          _lastWbGains = result.gains;
          _lastWbPatchBefore = result.patchBefore;
          _lastWbPatchAfter = result.patchAfter;
        });
        // Forward calibrated gains to Camera2 ISP immediately.
        _applySettings(CameraSettings(whiteBalance: _wbMode));
      }
    } catch (e) {
      if (mounted) {
        _showError(
          'White balance calibration failed — point at a neutral surface and try again',
        );
      }
    }
  }

  Future<void> _runBbCalibration() async {
    final camera = _camera;
    if (camera == null || !mounted) return;
    try {
      final result = await camera.calibrateBlackBalance(
        params: _processingParams,
      );
      if (mounted) {
        setState(() {
          _lastBbR = result.offsets.r;
          _lastBbG = result.offsets.g;
          _lastBbB = result.offsets.b;
          _lastBbPatchBefore = result.patchBefore;
          _lastBbPatchAfter = result.patchAfter;
          _bbLocked = true;
        });
        // Forward calibrated offsets to GPU shader immediately.
        _applyProcessingParams(
          _processingParams.copyWith(
            blackR: result.offsets.r,
            blackG: result.offsets.g,
            blackB: result.offsets.b,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        _showError(
          'Black balance calibration failed — cover the lens fully and try again',
        );
      }
    }
  }

  void _onIsoChanged(int iso) {
    if (!_aeSeeded) return;
    // ISO and exposure share a single Camera2 AE flag — manual ISO means manual exposure.
    setState(
      () => _values = _values.copyWith(
        isoValue: iso,
        isoAuto: false,
        exposureAuto: false,
      ),
    );
    _applySettings(CameraSettings(iso: AutoValue.manual(iso)));
  }

  void _onExposureTimeNsChanged(int ns) {
    if (!_aeSeeded) return;
    // ISO and exposure share a single Camera2 AE flag — manual exposure means manual ISO.
    setState(
      () => _values = _values.copyWith(
        exposureTimeNs: ns,
        exposureAuto: false,
        isoAuto: false,
      ),
    );
    _applySettings(CameraSettings(exposureTimeNs: AutoValue.manual(ns)));
  }

  void _onCameraError(CameraError error) {
    if (!mounted) return;
    if (error.code == CameraErrorCode.settingsConflict) {
      setState(
        () => _values = _values.copyWith(isoAuto: true, exposureAuto: true),
      );
      _showError('Camera not ready — settings reverted to auto');
    } else if (error.code == CameraErrorCode.fpsDegraded) {
      _showError('FPS degraded: ${error.message}');
    } else if (error.code == CameraErrorCode.aeConvergenceTimeout) {
      _showError('Auto-exposure struggling — try more light or manual mode');
    }
  }

  void _onFocusChanged(double dist) {
    setState(
      () => _values = _values.copyWith(focusDiopters: dist, afEnabled: false),
    );
    _applySettings(CameraSettings(focus: AutoValue.manual(dist)));
  }

  void _onZoomChanged(double ratio) {
    setState(() => _values = _values.copyWith(zoomRatio: ratio));
    _applySettings(CameraSettings(zoomRatio: ratio));
  }

  /// Handles user selection of a new stream resolution from the popup menu.
  Future<void> _onResolutionSelected(CameraSize size) async {
    final camera = _camera;
    if (camera == null || _isRecording || _recordingActionInProgress) return;
    setState(() => _recordingActionInProgress = true);
    try {
      await camera.setResolution(size.width, size.height);
      if (!mounted) return;
      final caps = camera.capabilities;
      setState(() {
        _currentResolutionLabel = '${caps.streamWidth}x${caps.streamHeight}';
        _availableResolutions = caps.supportedSizes;
      });
    } catch (e) {
      if (mounted) _showError('Resolution change failed: $e');
    } finally {
      if (mounted) setState(() => _recordingActionInProgress = false);
    }
  }

  /// Updates slider positions from live hardware sensor values.
  ///
  /// Only writes fields whose auto mode is currently active — manual values set
  /// by the user are never overwritten. [CameraRulerDial.didUpdateWidget] picks
  /// up the new [initialValue] and snaps the dial to the hardware reading.
  void _onFrameResult(FrameResult result) {
    if (!mounted) return;
    _latestFrameResult = result;
    var next = _values;
    if (_values.isoAuto) {
      final iso = result.iso;
      if (iso != null) {
        final clamped = iso.clamp(_ranges.isoMin, _ranges.isoMax).toInt();
        if (clamped != _values.isoValue) {
          next = next.copyWith(isoValue: clamped);
        }
      }
    }
    if (_values.exposureAuto) {
      final ns = result.exposureTimeNs;
      if (ns != null) {
        final clamped = ns
            .clamp(_ranges.exposureTimeMinNs, _ranges.exposureTimeMaxNs)
            .toInt();
        if (clamped != _values.exposureTimeNs) {
          next = next.copyWith(exposureTimeNs: clamped);
        }
      }
    }
    if (_values.afEnabled) {
      final focus = result.focusDistanceDiopters;
      if (focus != null) {
        final clamped = focus.clamp(0.0, _ranges.focusMaxDiopters).toDouble();
        if (clamped != _values.focusDiopters) {
          next = next.copyWith(focusDiopters: clamped);
        }
      }
    }
    final nowSeeded =
        !_aeSeeded && result.iso != null && result.exposureTimeNs != null;
    if (!identical(next, _values) || nowSeeded) {
      setState(() {
        _values = next;
        if (nowSeeded) _aeSeeded = true;
      });
    }
  }

  // ── Recording

  Future<void> _toggleRecording() async {
    final camera = _camera;
    if (camera == null || _recordingActionInProgress) return;
    setState(() => _recordingActionInProgress = true);
    try {
      if (_isRecording) {
        await camera.stopRecording();
      } else {
        final (_, displayName) = await camera.startRecording();
        if (mounted) {
          setState(() {
            _isRecording = true;
            _recordingDisplayName = displayName;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        _showError('Recording error: $e');
      }
    } finally {
      if (mounted) setState(() => _recordingActionInProgress = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.error_outline, color: cs.onError, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(message, style: TextStyle(color: cs.onError)),
              ),
            ],
          ),
          backgroundColor: cs.error,
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(context).padding.bottom + 72,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 5),
        ),
      );
  }

  // ── UI actions

  void _onSettingChipTap(CameraSettingType? p) {
    setState(() => _activeSetting = p);
  }

  void _toggleSettingsDrawer() {
    setState(() {
      _settingsDrawerOpen = !_settingsDrawerOpen;
      if (!_settingsDrawerOpen) _activeSetting = null;
    });
  }

  bool _hasAutoMode(CameraSettingType? param) {
    if (param == null) return false;
    return switch (param) {
      CameraSettingType.iso ||
      CameraSettingType.shutter ||
      CameraSettingType.focus => true,
      CameraSettingType.zoom => false,
    };
  }

  bool _isAutoMode(CameraSettingType? param) {
    if (param == null) return false;
    return switch (param) {
      CameraSettingType.iso => _values.isoAuto,
      CameraSettingType.shutter => _values.exposureAuto,
      CameraSettingType.focus => _values.afEnabled,
      CameraSettingType.zoom => false,
    };
  }

  void _onAutoToggleTap(CameraSettingType? param) {
    if (param == null) return;
    switch (param) {
      case CameraSettingType.iso:
        final nowAuto = !_values.isoAuto;
        // Auto is contagious: toggling ISO auto also toggles exposure auto.
        setState(
          () => _values = _values.copyWith(
            isoAuto: nowAuto,
            exposureAuto: nowAuto,
          ),
        );
        _applySettings(
          CameraSettings(
            iso: nowAuto
                ? const AutoValue.auto()
                : AutoValue.manual(_values.isoValue),
          ),
        );
      case CameraSettingType.shutter:
        final nowAuto = !_values.exposureAuto;
        // Auto is contagious: toggling exposure auto also toggles ISO auto.
        setState(
          () => _values = _values.copyWith(
            exposureAuto: nowAuto,
            isoAuto: nowAuto,
          ),
        );
        _applySettings(
          CameraSettings(
            exposureTimeNs: nowAuto
                ? const AutoValue.auto()
                : AutoValue.manual(_values.exposureTimeNs),
          ),
        );
      case CameraSettingType.focus:
        _toggleAf();
      case CameraSettingType.zoom:
        break;
    }
  }

  // ── Build

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_settingsDrawerOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_settingsDrawerOpen) _toggleSettingsDrawer();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // Two preview panes side by side: raw (left) vs processed (right).
              // GPU controls sidebar pushes content from the left.
              Expanded(
                child: Stack(
                  children: [
                    Row(
                      children: [
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeInOutCubic,
                          width: _sidebarOpen ? _kSidebarWidth : 0,
                          child: ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: _kSidebarWidth,
                              maxWidth: _kSidebarWidth,
                              child: GpuControlsSidebar(
                                params: _processingParams,
                                onChanged: _applyProcessingParams,
                                wbMode: _wbMode,
                                lastWbGains: _lastWbGains != null
                                    ? (
                                        _lastWbGains!.r,
                                        _lastWbGains!.g,
                                        _lastWbGains!.b,
                                      )
                                    : null,
                                bbLocked: _bbLocked,
                                lastBbValues: _bbLocked
                                    ? (_lastBbR, _lastBbG, _lastBbB)
                                    : null,
                                onWbToggle: _onWbToggle,
                                onBbToggle: _onBbToggle,
                                onStartCalibration: _onStartCalibration,
                                onResetAll: _onResetAll,
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: Row(
                            children: [
                              Expanded(child: _buildRawPreview()),
                              Expanded(child: _buildCameraPreview()),
                            ],
                          ),
                        ),
                      ],
                    ),
                    // Recording HUD — floats over preview, centered above bottom bar
                    Positioned(
                      bottom: 12,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: RecordingHud(
                          stateStream:
                              _camera?.recordingStateStream ??
                              const Stream.empty(),
                          displayName: _recordingDisplayName,
                          outputDir: _recordingOutputDir,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Bottom bar area (ruler dial overlay + animated bar)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Floating ruler dial overlay
                  if (_activeSetting != null && _settingsDrawerOpen) ...[
                    SizedBox(
                      height: 48,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          CameraControlOverlay(
                            activeSetting: _activeSetting,
                            values: _values,
                            ranges: _ranges,
                            callbacks: _callbacks,
                          ),
                          if (_hasAutoMode(_activeSetting))
                            Positioned(
                              left: max(
                                0.0,
                                (MediaQuery.of(context).size.width / 2) -
                                    kCameraDialMaxWidth / 2 -
                                    _kAutoToggleOffset,
                              ),
                              child: CameraAutoToggleButton(
                                isAuto: _isAutoMode(_activeSetting),
                                onTap: () => _onAutoToggleTap(_activeSetting),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Animated bottom bar
                  ColoredBox(
                    color: Theme.of(context).colorScheme.surfaceContainerLowest,
                    child: BottomBar(
                      isSettingsOpen: _settingsDrawerOpen,
                      isSettingsEnabled: _aeSeeded,
                      activeSetting: _activeSetting,
                      values: _values,
                      callbacks: _callbacks,
                      onToggleSettings: _toggleSettingsDrawer,
                      onSettingChipTap: _onSettingChipTap,
                      onToggleGpuControls: () => setState(() => _sidebarOpen = !_sidebarOpen),
                      currentResolutionLabel: _currentResolutionLabel,
                      availableResolutions: _availableResolutions,
                      onResolutionSelected: _onResolutionSelected,
                      isRecording: _isRecording,
                      onToggleRecording: _toggleRecording,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    final camera = _camera;
    if (camera == null) {
      return const ColoredBox(color: Colors.black);
    }
    return Stack(
      children: [
        StreamBuilder<CameraTextureInfo>(
          stream: camera.toneMappedTexture,
          builder: (context, snap) {
            if (!snap.hasData) return const ColoredBox(color: Colors.black);
            final t = snap.data!;
            // Cache for calibration overlay coordinate mapping (no setState
            // needed — the overlay rebuilds whenever calibration state changes).
            _latestTextureInfo = t;
            return FittedBox(
              fit: BoxFit.contain,
              child: RotatedBox(
                quarterTurns: _quarterTurns,
                child: SizedBox(
                  width: t.width.toDouble(),
                  height: t.height.toDouble(),
                  child: Texture(textureId: t.textureId),
                ),
              ),
            );
          },
        ),
        if (_isCalibrating && _calibrationTarget != null)
          Positioned.fill(
            child: CalibrationOverlay(
              target: _calibrationTarget!,
              onConfirm: () => unawaited(_onCapture()),
              textureInfo: _latestTextureInfo,
              quarterTurns: _quarterTurns,
            ),
          ),
      ],
    );
  }

  /// Raw preview: direct YUV→BGR output before any post-processing.
  Widget _buildRawPreview() {
    final camera = _camera;
    if (camera == null) {
      return const ColoredBox(color: Colors.black);
    }
    return StreamBuilder<CameraTextureInfo>(
      stream: camera.rawTexture,
      builder: (context, snap) {
        if (!snap.hasData) return const ColoredBox(color: Colors.black);
        final t = snap.data!;
        return FittedBox(
          fit: BoxFit.contain,
          child: RotatedBox(
            quarterTurns: _quarterTurns,
            child: SizedBox(
              width: t.width.toDouble(),
              height: t.height.toDouble(),
              child: Texture(textureId: t.textureId),
            ),
          ),
        );
      },
    );
  }
}
