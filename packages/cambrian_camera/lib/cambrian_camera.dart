/// Cambrian camera Flutter plugin.
///
/// Exposes a Camera2-backed camera with C++ post-processing and a generic
/// consumer sink API for native frame consumers.
///
/// Typical usage:
/// ```dart
/// import 'package:cambrian_camera/cambrian_camera.dart';
///
/// final camera = await CambrianCamera.open();
/// // ...
/// await camera.close();
/// ```
library;

export 'src/cambrian_camera_controller.dart' show CambrianCamera;
export 'src/cambrian_camera_preview.dart' show CambrianCameraPreview;
export 'src/camera_settings.dart'
    show
        AutoValue,
        Auto,
        Manual,
        WhiteBalance,
        WbAuto,
        WbLocked,
        WbManual,
        CameraSettings,
        ProcessingParams,
        NoiseReductionMode,
        EdgeMode;
export 'src/camera_state.dart'
    show
        CameraState,
        CameraError,
        CameraErrorCode,
        CameraCapabilities,
        CameraSize;
