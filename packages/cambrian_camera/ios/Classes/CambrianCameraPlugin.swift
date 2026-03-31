import Flutter

/// iOS stub — not yet implemented.
///
/// The Pigeon `CameraHostApi` is not registered on iOS, so any Dart call to a
/// camera method will fail with a channel-connection error. iOS support will be
/// added in a future phase once the Android implementation is complete.
public class CambrianCameraPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        // No-op: iOS is not supported yet.
        // The plugin is registered to satisfy Flutter's plugin system.
    }
}
