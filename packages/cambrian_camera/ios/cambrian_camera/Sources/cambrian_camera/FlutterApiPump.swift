import CameraKit
import Flutter
import Foundation

/// One pump per open camera handle. Owns five long-running `Task`s, each
/// `for await`ing one of `CameraEngine`'s `AsyncStream`s and dispatching the
/// converted value through `CameraFlutterApi` to Dart.
///
/// ## Lifetime
///
/// - Constructed in `CameraHostApiImpl.open` once the engine actor exists.
/// - `start()` spawns the five tasks. They run until either the engine's
///   stream finishes (engine deinit) or `stop()` cancels them.
/// - `stop()` cancels every task and is safe to invoke multiple times. It
///   must be called from `CameraHostApiImpl.close` before `engine.close()`
///   so we are not still pushing events into a dead Flutter channel.
///
/// ## Threading
///
/// Each task awaits its engine stream on a background executor and hops to
/// `MainActor` immediately before invoking `CameraFlutterApi`. Flutter
/// platform-channel calls must originate from the main thread; the `await
/// MainActor.run` keeps that contract local to the pump rather than relying
/// on `CameraFlutterApi`'s implementation details.
///
/// The Pigeon completion handler is intentionally ignored (`{ _ in }`).
/// There is no recovery the engine can perform if Dart dropped the message,
/// and surfacing the error back into the engine would only create feedback
/// loops on the error stream.
final class FlutterApiPump {

    // MARK: - Stored properties

    private let handle: Int64
    private let engine: CameraEngine
    private let flutterApi: CameraFlutterApi
    /// Texture-ID accessor — invoked on every `onStreamConfigurationChanged`
    /// dispatch. A closure (rather than two stored `Int64`s) lets the caller
    /// wire texture registration after the pump is constructed without
    /// changing the pump's API or risking a stale snapshot.
    private let textureIds: @Sendable () -> (natural: Int64, preview: Int64)

    /// Backing storage for the five spawned tasks. Populated by `start()`
    /// and cleared by `stop()`. Only mutated on the thread that owns the
    /// pump instance (the host-API call site), so no extra synchronisation
    /// is required.
    private var tasks: [Task<Void, Never>] = []

    // MARK: - Initialization

    init(
        handle: Int64,
        engine: CameraEngine,
        flutterApi: CameraFlutterApi,
        textureIds: @escaping @Sendable () -> (natural: Int64, preview: Int64)
    ) {
        self.handle = handle
        self.engine = engine
        self.flutterApi = flutterApi
        self.textureIds = textureIds
    }

    deinit {
        // Best-effort safety net; correct call sites still invoke stop()
        // explicitly so cancellation happens before engine.close().
        tasks.forEach { $0.cancel() }
    }

    // MARK: - Public API

    /// Spawns the five per-stream forwarding tasks. Calling twice without an
    /// intervening `stop()` will double-subscribe — `CameraHostApiImpl` is
    /// the single caller and only invokes `start()` once per handle.
    func start() {
        tasks.append(makeStateTask())
        tasks.append(makeErrorTask())
        tasks.append(makeFrameResultTask())
        tasks.append(makeRecordingStateTask())
        tasks.append(makeStreamConfigurationTask())
    }

    /// Cancels every spawned task and drops the references. Idempotent —
    /// safe to call after `start()` was never invoked or after a prior
    /// `stop()`. The `for await` loops inside each task exit naturally on
    /// cancellation; no further `FlutterApi` calls fire after this returns.
    func stop() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    // MARK: - Per-stream task factories

    private func makeStateTask() -> Task<Void, Never> {
        let handle = self.handle
        let engine = self.engine
        let flutterApi = self.flutterApi
        return Task {
            let stream = await engine.stateStream()
            for await state in stream {
                let payload = PigeonValueMapping.toCamStateUpdate(state)
                await MainActor.run {
                    flutterApi.onStateChanged(handle: handle, state: payload) { _ in }
                }
            }
        }
    }

    private func makeErrorTask() -> Task<Void, Never> {
        let handle = self.handle
        let engine = self.engine
        let flutterApi = self.flutterApi
        return Task {
            let stream = await engine.errorStream()
            for await error in stream {
                let payload = PigeonValueMapping.toCamError(error)
                await MainActor.run {
                    flutterApi.onError(handle: handle, error: payload) { _ in }
                }
            }
        }
    }

    private func makeFrameResultTask() -> Task<Void, Never> {
        let handle = self.handle
        let engine = self.engine
        let flutterApi = self.flutterApi
        return Task {
            let stream = await engine.frameResultStream()
            for await result in stream {
                let payload = PigeonValueMapping.toCamFrameResult(result)
                await MainActor.run {
                    flutterApi.onFrameResult(handle: handle, result: payload) { _ in }
                }
            }
        }
    }

    private func makeRecordingStateTask() -> Task<Void, Never> {
        let handle = self.handle
        let engine = self.engine
        let flutterApi = self.flutterApi
        return Task {
            let stream = await engine.recordingStateStream()
            for await state in stream {
                let wire = Self.recordingStateWireString(state)
                await MainActor.run {
                    flutterApi.onRecordingStateChanged(handle: handle, state: wire) { _ in }
                }
            }
        }
    }

    private func makeStreamConfigurationTask() -> Task<Void, Never> {
        let handle = self.handle
        let engine = self.engine
        let flutterApi = self.flutterApi
        let textureIds = self.textureIds
        return Task {
            let stream = await engine.streamConfigurationStream()
            for await cfg in stream {
                let ids = textureIds()
                let payload = PigeonValueMapping.toCamStreamConfiguration(
                    cfg,
                    naturalTextureId: ids.natural,
                    previewTextureId: ids.preview
                )
                await MainActor.run {
                    flutterApi.onStreamConfigurationChanged(
                        handle: handle,
                        configuration: payload
                    ) { _ in }
                }
            }
        }
    }

    // MARK: - Local mappings

    /// `RecordingState` → wire string per Plan 2 §3 mapping table.
    ///
    /// Kept here rather than in `PigeonValueMapping` because the single
    /// call site (the recording-state pump task) is the only consumer; the
    /// engine's `idle(lastUri:)` payload is intentionally collapsed since
    /// the wire contract is a plain `String` enum, not a structured value.
    private static func recordingStateWireString(_ state: RecordingState) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .finalizing: return "finalizing"
        case .paused: return "paused"
        }
    }
}
