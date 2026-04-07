import 'dart:async' show StreamSubscription;
import 'dart:math' show max;

import 'package:cambrian_camera/cambrian_camera.dart'
    show
        AutoValue,
        CambrianCamera,
        CameraError,
        CameraErrorCode,
        CameraSettings,
        CameraTextureInfo,
        FrameResult,
        ProcessingParams,
        quarterTurnsFromDisplayRotation,
        RecordingState,
        WhiteBalance;
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
import 'widgets/gpu_controls_sidebar.dart' show GpuControlsSidebar;
import 'widgets/recording_hud.dart' show RecordingHud;

/// Horizontal offset from the left edge of the dial to the auto-toggle button.
const _kAutoToggleOffset = 60.0;

/// Initial camera settings used for both [CambrianCamera.open] and the UI's
/// initial [CameraSettingsValues]. Keeping them in one place ensures the two
/// can never diverge at startup.
const _kInitialSettings = CameraSettings(
  iso: AutoValue<int>.auto(),
  exposureTimeNs: AutoValue<int>.auto(),
  focus: AutoValue<double>.auto(),
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

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
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

  /// Display rotation in degrees CW from portrait: 0, 90, 180, or 270.
  int _displayRotationDeg = 0;

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
      onWbLockChanged: _setWbLocked,
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
      final camera = await CambrianCamera.open(
        settings: _kInitialSettings,
      );
      // Restore processing params from previous session, or use identity defaults.
      final persisted = await camera.getPersistedProcessingParams();
      final initialParams = persisted ?? ProcessingParams();
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

  void _setWbLocked(bool locked) {
    setState(() => _values = _values.copyWith(wbLocked: locked));
    _applySettings(CameraSettings(
      whiteBalance: locked ? const WhiteBalance.locked() : const WhiteBalance.auto(),
    ));
  }

  void _toggleAf() {
    final nowAf = !_values.afEnabled;
    setState(() => _values = _values.copyWith(afEnabled: nowAf));
    _applySettings(CameraSettings(
      focus: nowAf
          ? const AutoValue.auto()
          : AutoValue.manual(_values.focusDiopters),
    ));
  }

  void _onIsoChanged(int iso) {
    if (!_aeSeeded) return;
    // ISO and exposure share a single Camera2 AE flag — manual ISO means manual exposure.
    setState(() => _values = _values.copyWith(isoValue: iso, isoAuto: false, exposureAuto: false));
    _applySettings(CameraSettings(iso: AutoValue.manual(iso)));
  }

  void _onExposureTimeNsChanged(int ns) {
    if (!_aeSeeded) return;
    // ISO and exposure share a single Camera2 AE flag — manual exposure means manual ISO.
    setState(
      () => _values = _values.copyWith(exposureTimeNs: ns, exposureAuto: false, isoAuto: false),
    );
    _applySettings(CameraSettings(exposureTimeNs: AutoValue.manual(ns)));
  }

  void _onCameraError(CameraError error) {
    if (!mounted) return;
    if (error.code == CameraErrorCode.settingsConflict) {
      setState(() => _values = _values.copyWith(isoAuto: true, exposureAuto: true));
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

  /// Updates slider positions from live hardware sensor values.
  ///
  /// Only writes fields whose auto mode is currently active — manual values set
  /// by the user are never overwritten. [CameraRulerDial.didUpdateWidget] picks
  /// up the new [initialValue] and snaps the dial to the hardware reading.
  void _onFrameResult(FrameResult result) {
    if (!mounted) return;
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
    final nowSeeded = !_aeSeeded && result.iso != null && result.exposureTimeNs != null;
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
        if (mounted) setState(() {
          _isRecording = true;
          _recordingDisplayName = displayName;
        });
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
      CameraSettingType.focus ||
      CameraSettingType.wb => true,
      CameraSettingType.zoom => false,
    };
  }

  bool _isAutoMode(CameraSettingType? param) {
    if (param == null) return false;
    return switch (param) {
      CameraSettingType.iso => _values.isoAuto,
      CameraSettingType.shutter => _values.exposureAuto,
      CameraSettingType.focus => _values.afEnabled,
      CameraSettingType.wb => !_values.wbLocked,
      CameraSettingType.zoom => false,
    };
  }

  void _onAutoToggleTap(CameraSettingType? param) {
    if (param == null) return;
    switch (param) {
      case CameraSettingType.iso:
        final nowAuto = !_values.isoAuto;
        // Auto is contagious: toggling ISO auto also toggles exposure auto.
        setState(() => _values = _values.copyWith(isoAuto: nowAuto, exposureAuto: nowAuto));
        _applySettings(CameraSettings(
          iso: nowAuto ? const AutoValue.auto() : AutoValue.manual(_values.isoValue),
        ));
      case CameraSettingType.shutter:
        final nowAuto = !_values.exposureAuto;
        // Auto is contagious: toggling exposure auto also toggles ISO auto.
        setState(() => _values = _values.copyWith(exposureAuto: nowAuto, isoAuto: nowAuto));
        _applySettings(CameraSettings(
          exposureTimeNs: nowAuto
              ? const AutoValue.auto()
              : AutoValue.manual(_values.exposureTimeNs),
        ));
      case CameraSettingType.focus:
        _toggleAf();
      case CameraSettingType.wb:
        _setWbLocked(!_values.wbLocked);
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
                      width: _sidebarOpen ? 270 : 0,
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.centerLeft,
                          minWidth: 270,
                          maxWidth: 270,
                          child: GpuControlsSidebar(
                            params: _processingParams,
                            onChanged: _applyProcessingParams,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(child: Center(child: _buildRawPreview())),
                          Expanded(child: Center(child: _buildCameraPreview())),
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
                          stateStream: _camera?.recordingStateStream ?? const Stream.empty(),
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
    return StreamBuilder<CameraTextureInfo>(
      stream: camera.toneMappedTexture,
      builder: (context, snap) {
        if (!snap.hasData) return const ColoredBox(color: Colors.black);
        final t = snap.data!;
        return FittedBox(
          fit: BoxFit.cover,
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
          fit: BoxFit.cover,
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
