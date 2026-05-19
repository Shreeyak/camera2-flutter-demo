import Flutter
import CameraKit

/// Cambrian camera iOS plugin — registrar.
///
/// Plan 2 wires the full dependency graph for the HostApi impl:
/// - `HandleRegistry` — actor that maps `Int64` handles → engines.
/// - `FlutterTextureRegistry` — Flutter's texture-registration entry point.
/// - `CameraFlutterApi` — Pigeon-generated Dart-bound callback channel.
/// - `LifecycleObserver` — UIScene observer fanning scene-phase transitions
///   out to every open engine via `notifyScenePhasePaused`.
///
/// `CameraHostApiSetup.setUp` retains `api` strongly via channel handler
/// closures, but Flutter plugins are otherwise transient — `register(with:)`
/// returns without storing the plugin anywhere. Static properties keep the
/// impl, registry, and observer alive for the process lifetime, matching the
/// FlutterPlugin convention.
public class CambrianCameraPlugin: NSObject, FlutterPlugin {

    /// Process-wide retention for the dependency graph. `register(with:)` is
    /// invoked once per Flutter engine; subsequent calls overwrite (the
    /// previous instances are released, taking their open engines with them).
    private static var sharedRegistry: HandleRegistry?
    private static var sharedApi: CameraHostApiImpl?
    private static var sharedLifecycleObserver: LifecycleObserver?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let registry = HandleRegistry()
        let textureRegistry = registrar.textures()
        let flutterApi = CameraFlutterApi(binaryMessenger: registrar.messenger())
        let api = CameraHostApiImpl(
            registry: registry,
            textureRegistry: textureRegistry,
            flutterApi: flutterApi
        )
        CameraHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: api)

        // Lifecycle observer holds a weak reference to the registry — the
        // static slot below is what keeps it alive.
        let lifecycle = LifecycleObserver(registry: registry)

        sharedRegistry = registry
        sharedApi = api
        sharedLifecycleObserver = lifecycle
    }
}
