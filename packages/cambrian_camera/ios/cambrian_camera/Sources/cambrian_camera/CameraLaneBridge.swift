import CameraKit
import Flutter
import Foundation

/// Per-lane subscriber `Task` that fires `textureFrameAvailable` whenever the
/// engine publishes a new frame on `stream`.
///
/// We discard the yielded `FrameSet` immediately — only the SIGNAL matters
/// here. The accompanying `CameraLaneTexture` handles the pull on Flutter's
/// next render pass via `copyPixelBuffer()`. This split (signal here, pull
/// there) matches the spec §4 "simple pull" model: we never retain a
/// `FrameSet` so the per-frame pool-buffer lifetime rules in
/// `FrameSet`'s docstring are trivially satisfied.
///
/// ## Lifetime
///
/// - Constructed in `CameraHostApiImpl.open` alongside the lane's
///   `CameraLaneTexture`, after the engine actor exists.
/// - `start()` spawns the subscriber task; runs until either the engine's
///   stream finishes (engine deinit / close) or `stop()` cancels it.
/// - `stop()` cancels the task AND unregisters the texture from Flutter's
///   registry. Must be `await`ed before `engine.close()` so we are not still
///   nudging Flutter while the engine is tearing down.
///
/// ## Threading
///
/// Subscribes on a background executor and hops to `MainActor` immediately
/// before invoking `FlutterTextureRegistry.textureFrameAvailable(_:)`.
/// Flutter's texture-registry methods are documented main-thread on iOS;
/// mirroring `FlutterApiPump`'s `await MainActor.run` keeps that contract
/// local to this bridge rather than relying on registry implementation
/// details.
final class CameraLaneBridge {

    // MARK: - Stored properties

    /// Strong — the registrar passes it in and it lives for the plugin's
    /// lifetime (the Flutter engine owns it). Storing weak would risk losing
    /// the reference before `stop()` runs `unregisterTexture`.
    private let textureRegistry: FlutterTextureRegistry
    private let textureId: Int64
    /// Weak — closing the engine should not be blocked by an outstanding
    /// bridge subscription. Matches `CameraLaneTexture`'s engine reference.
    private weak var engine: CameraEngine?
    private let stream: StreamId

    /// Backing storage for the spawned subscriber task. Populated by `start()`
    /// and cleared by `stop()`.
    private var task: Task<Void, Never>?

    // MARK: - Initialization

    init(
        textureRegistry: FlutterTextureRegistry,
        textureId: Int64,
        engine: CameraEngine,
        stream: StreamId
    ) {
        self.textureRegistry = textureRegistry
        self.textureId = textureId
        self.engine = engine
        self.stream = stream
    }

    deinit {
        // Best-effort safety net; correct call sites still invoke stop()
        // explicitly so the texture is unregistered before engine.close().
        task?.cancel()
    }

    // MARK: - Public API

    /// Spawns the subscriber task. Calling twice without an intervening
    /// `stop()` will double-subscribe — callers should invoke `start()` once
    /// per bridge instance.
    func start() {
        // Pull locals out first so the Task does not capture self strongly —
        // mirrors `FlutterApiPump.makeStateTask` (FlutterApiPump.swift:93-106).
        // A strong self capture would prevent the bridge from deiniting until
        // the engine stream finishes.
        let textureRegistry = self.textureRegistry
        let textureId = self.textureId
        let stream = self.stream
        weak var engine = self.engine
        task = Task {
            guard let engine else { return }
            // CameraKit >= v1.5.0 requires an explicit BufferingPolicy.
            // `.latestWins` keeps only the newest frame (drop-on-busy), matching
            // this bridge's prior behavior: we only need the "frame available"
            // signal to poke Flutter, never a backlog.
            let frames = await engine.consumers.subscribe(stream: stream, buffering: .latestWins)
            // CameraKit >= v1.5.0 returns an AsyncThrowingStream; the iteration
            // can throw on stream termination. The task is non-throwing
            // (Task<Void, Never>), so swallow the terminal error — there is
            // nothing to recover, and stop()/close() handles texture cleanup.
            do {
                // Discard the FrameSet — see type docstring. Only the signal matters.
                for try await _ in frames {
                    await MainActor.run {
                        textureRegistry.textureFrameAvailable(textureId)
                    }
                }
            } catch {
                // Stream ended with an error (typically engine teardown). No-op.
            }
        }
    }

    /// Cancels the spawned subscriber task and unregisters the texture from
    /// Flutter's registry. Idempotent — safe to call after `start()` was
    /// never invoked or after a prior `stop()`.
    ///
    /// `async` so callers can `await` the MainActor cleanup before tearing
    /// down the engine; the same precedent as `FlutterApiPump.stop()` being
    /// followed by `engine.close()` in `CameraHostApiImpl`.
    func stop() async {
        task?.cancel()
        task = nil
        let textureRegistry = self.textureRegistry
        let textureId = self.textureId
        await MainActor.run {
            textureRegistry.unregisterTexture(textureId)
        }
    }
}
