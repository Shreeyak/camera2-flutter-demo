import Flutter
import CameraKit

/// Cambrian camera iOS plugin — registrar.
///
/// Plan 1 wires only the HostApi-implementation registration. Method bodies
/// are stubs throwing `not_implemented`. Plan 2 fills in real impls; Plan 4
/// HITL-verifies on device.
public class CambrianCameraPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let api = CameraHostApiImpl()
        CameraHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: api)
    }
}
