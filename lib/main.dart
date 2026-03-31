import 'dart:async' show StreamSubscription;

import 'package:cambrian_camera/cambrian_camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'camera/camera_callbacks.dart';
import 'camera/camera_settings_values.dart';
import 'theme/material_theme.dart';
import 'theme/theme_util.dart';
import 'widgets/bottom_bar.dart';
import 'widgets/camera_control_overlay.dart';
import 'widgets/bottom_bar_buttons.dart';

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

class _CameraScreenState extends State<CameraScreen> {
  // ── Camera state
  late CameraSettingsValues _values;
  CameraRanges _ranges = const CameraRanges();
  late final CameraCallbacks _callbacks;
  CambrianCamera? _camera;
  StreamSubscription<FrameResult>? _frameResultSub;

  // ── UI state
  bool _settingsDrawerOpen = false;
  CameraSettingType? _activeSetting;

  @override
  void initState() {
    super.initState();
    _values = CameraSettingsValues.initialFromRanges(_ranges);
    _openCamera();
    _callbacks = CameraCallbacks(
      onIsoChanged: _onIsoChanged,
      onExposureTimeNsChanged: _onExposureTimeNsChanged,
      onFocusChanged: _onFocusChanged,
      onZoomChanged: _onZoomChanged,
      onWbLockChanged: _setWbLocked,
      onToggleAf: _toggleAf,
    );
  }

  Future<void> _openCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      debugPrint('Camera permission denied: $status');
      return;
    }
    try {
      final camera = await CambrianCamera.open(
        settings: CameraSettings(focus: const AutoValue.auto()),
      );
      final caps = camera.capabilities;
      final ranges = CameraRanges(
        isoRange: [caps.isoMin, caps.isoMax],
        exposureTimeRangeNs: [caps.exposureTimeMinNs, caps.exposureTimeMaxNs],
        minFocusDiopters: caps.focusMax,
        minZoomRatio: caps.zoomMin,
        maxZoomRatio: caps.zoomMax,
      );
      if (mounted) {
        setState(() {
          _camera = camera;
          _ranges = ranges;
          _values = CameraSettingsValues.initialFromRanges(ranges);
        });
        _frameResultSub = camera.frameResultStream.listen(_onFrameResult);
      }
    } catch (e) {
      // Camera may not be available in all environments (e.g. emulators).
      // The UI degrades gracefully to a black placeholder.
      debugPrint('CambrianCamera.open failed: $e');
    }
  }

  @override
  void dispose() {
    _frameResultSub?.cancel();
    final camera = _camera;
    if (camera != null) {
      camera.close().catchError((Object e) {
        debugPrint('CambrianCamera.close failed during dispose: $e');
      });
    }
    super.dispose();
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
    // ISO and exposure share a single Camera2 AE flag — manual ISO means manual exposure.
    setState(() => _values = _values.copyWith(isoValue: iso, isoAuto: false, exposureAuto: false));
    _applySettings(CameraSettings(iso: AutoValue.manual(iso)));
  }

  void _onExposureTimeNsChanged(int ns) {
    // ISO and exposure share a single Camera2 AE flag — manual exposure means manual ISO.
    setState(
      () => _values = _values.copyWith(exposureTimeNs: ns, exposureAuto: false, isoAuto: false),
    );
    _applySettings(CameraSettings(exposureTimeNs: AutoValue.manual(ns)));
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
        final clamped = iso.clamp(_ranges.isoRange[0], _ranges.isoRange[1]).toInt();
        if (clamped != _values.isoValue) {
          next = next.copyWith(isoValue: clamped);
        }
      }
    }
    if (_values.exposureAuto) {
      final ns = result.exposureTimeNs;
      if (ns != null) {
        final clamped = ns
            .clamp(_ranges.exposureTimeRangeNs[0], _ranges.exposureTimeRangeNs[1])
            .toInt();
        if (clamped != _values.exposureTimeNs) {
          next = next.copyWith(exposureTimeNs: clamped);
        }
      }
    }
    if (_values.afEnabled) {
      final focus = result.focusDistanceDiopters;
      if (focus != null) {
        final clamped = focus.clamp(0.0, _ranges.minFocusDiopters).toDouble();
        if (clamped != _values.focusDiopters) {
          next = next.copyWith(focusDiopters: clamped);
        }
      }
    }
    if (!identical(next, _values)) {
      setState(() => _values = next);
    }
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
    switch (param) {
      case CameraSettingType.iso:
      case CameraSettingType.shutter:
      case CameraSettingType.focus:
      case CameraSettingType.wb:
        return true;
      default:
        return false;
    }
  }

  bool _isAutoMode(CameraSettingType? param) {
    if (param == null) return false;
    switch (param) {
      case CameraSettingType.iso:
        return _values.isoAuto;
      case CameraSettingType.shutter:
        return _values.exposureAuto;
      case CameraSettingType.focus:
        return _values.afEnabled;
      case CameraSettingType.wb:
        return !_values.wbLocked;
      default:
        return false;
    }
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
        break;
      case CameraSettingType.shutter:
        final nowAuto = !_values.exposureAuto;
        // Auto is contagious: toggling exposure auto also toggles ISO auto.
        setState(() => _values = _values.copyWith(exposureAuto: nowAuto, isoAuto: nowAuto));
        _applySettings(CameraSettings(
          exposureTimeNs: nowAuto
              ? const AutoValue.auto()
              : AutoValue.manual(_values.exposureTimeNs),
        ));
        break;
      case CameraSettingType.focus:
        _toggleAf();
        break;
      case CameraSettingType.wb:
        _setWbLocked(!_values.wbLocked);
        break;
      case CameraSettingType.af:
      default:
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
              // Two preview panes side by side — fill remaining space
              Expanded(
                child: Row(
                  children: [
                    Expanded(child: _buildCameraPreview()),
                    Expanded(child: _buildCameraPreview()),
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
                              left:
                                  (MediaQuery.of(context).size.width / 2) -
                                  400 / 2 -
                                  60,
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
                      activeSetting: _activeSetting,
                      values: _values,
                      callbacks: _callbacks,
                      onToggleSettings: _toggleSettingsDrawer,
                      onSettingChipTap: _onSettingChipTap,
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
      // Camera not yet opened — show black placeholder.
      return const ColoredBox(color: Colors.black);
    }
    return camera.buildPreview(
      fit: BoxFit.cover,
      placeholder: const ColoredBox(color: Colors.black),
    );
  }
}
