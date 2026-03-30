import 'package:cambrian_camera/cambrian_camera.dart';
import 'package:flutter/material.dart';

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
  final CameraRanges _ranges = const CameraRanges();
  late final CameraCallbacks _callbacks;
  CambrianCamera? _camera;

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
    final camera = await CambrianCamera.open();
    if (mounted) setState(() => _camera = camera);
  }

  @override
  void dispose() {
    _camera?.close();
    super.dispose();
  }

  // ── Camera setting callbacks

  void _setWbLocked(bool locked) {
    setState(() => _values = _values.copyWith(wbLocked: locked));
  }

  void _toggleAf() {
    setState(() => _values = _values.copyWith(afEnabled: !_values.afEnabled));
  }

  void _onIsoChanged(int iso) {
    setState(() => _values = _values.copyWith(isoValue: iso));
  }

  void _onExposureTimeNsChanged(int ns) {
    setState(() => _values = _values.copyWith(exposureTimeNs: ns));
  }

  void _onFocusChanged(double dist) {
    setState(
      () => _values = _values.copyWith(focusDiopters: dist, afEnabled: false),
    );
  }

  void _onZoomChanged(double ratio) {
    setState(() => _values = _values.copyWith(zoomRatio: ratio));
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
      case CameraSettingType.shutter:
        return false; // ISO and shutter don't have auto state, just show button
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
                              left: (MediaQuery.of(context).size.width / 2) - 400 / 2 - 60,
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
