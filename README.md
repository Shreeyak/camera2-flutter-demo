# CameraKit

A Swift 6 / iOS 26 camera library: dual-lane capture (natural + processed),
Metal preview, recording, and calibration, behind a single declarative lifecycle
API. The package is UI-framework-agnostic — it imports no SwiftUI — and is
consumed both by this repo's native dev harness and by the `cambrian_camera`
Flutter plugin.

## Lifecycle

> **Driving the lifecycle.** The host tells CameraKit its visibility by calling
> `engine.setLifecyclePhase(_:)` on every transition — that is the entire
> lifecycle API. CameraKit owns everything downstream (GPU gate, session
> start/stop, stall watchdogs, recording finalize) plus the device-interruption
> lifecycle; the host owns only *observing* its own app lifecycle and forwarding
> the phase.
>
> - **SwiftUI:** observe `@Environment(\.scenePhase)` and forward `.active` /
>   `.inactive` / `.background` (1:1 — they share names with `AppLifecyclePhase`).
> - **Flutter:** observe the iOS scene lifecycle **natively** in the plugin and
>   forward it — **never** from Dart. Full wiring in
>   [Using CameraKit from Flutter](#using-camerakit-from-flutter) below.
>
> Call it freely on every transition: it never throws, and the latest call wins
> (a superseded in-flight transition is abandoned). Construct the engine with
> your current phase (`initialPhase`) — there is no default.

### What each phase reconciles to

| Phase | GPU gate | capture session | stall watchdogs |
|---|---|---|---|
| `.active` | open | running | armed |
| `.inactive` | closed | running (cheap pause — ~4 ms gate flip, not a ~410 ms restart) | disarmed |
| `.background` | closed | stopped (recording finalized first) | disarmed |

The target is derived from the *current* phase alone — there is no
previous-phase tracking, so the intermediate `.background → .inactive → .active`
restore that both SwiftUI and Flutter emit needs no special-casing. While an OS
interruption owns the device (`.interrupted` / `.recovering` / `.error`) the host
phase does not fight it: no `startRunning`, no watchdog re-arm, and the OS
event's label is not overwritten.

### Construction

`CameraEngine` requires an `initialPhase` — there is **no default**. Pass the
launch phase; pass `.background` when unsure. A default of `.active` would be a
privacy trap: if `open()` ran before the host's first phase forward (prewarm or a
direct-into-background launch) the engine would turn the camera on with no
foreground UI.

```swift
// SwiftUI host
let engine = CameraEngine(initialPhase: .background)   // state the launch phase
let caps = try await engine.open()

// Forward every scenePhase transition (1:1 mapping):
.task(id: scenePhase) {
    switch scenePhase {
    case .active:     await engine.setLifecyclePhase(.active)
    case .inactive:   await engine.setLifecyclePhase(.inactive)
    case .background: await engine.setLifecyclePhase(.background)
    @unknown default: await engine.setLifecyclePhase(.inactive)
    }
}
```

## Using CameraKit from Flutter

CameraKit ships into the `cambrian_camera` Flutter plugin: its Swift source is
embedded under the plugin's `ios/` and referenced as a local SwiftPM dependency,
so **only the plugin's native Swift layer imports CameraKit — Dart never does.**
That native layer is a thin bridge; the rest is a clean division of labor.

### Who owns what

| Concern | Plugin native Swift | Dart |
|---|---|---|
| Hold + `open()` / `close()` the `CameraEngine` | ✅ | — |
| **App lifecycle** → `setLifecyclePhase` | ✅ observe `UIScene` natively | ❌ **never forward lifecycle** |
| Camera commands (capture, resolution, processing, record) | bridges Dart → engine method | ✅ initiates over MethodChannel / Pigeon |
| Engine streams (state, frame results, errors, recording state) | forwards → `EventChannel` | ✅ consumes |
| Preview | vends the engine surface to a `FlutterTexture` | renders the `Texture` widget (or a placeholder) |

### Lifecycle is native-only

The plugin's native layer observes the iOS scene lifecycle and forwards the
phase; **Dart sends no lifecycle signal to CameraKit.** A Dart→native
method-channel round-trip adds latency that can let a backgrounding outrun an
in-flight recording's finalize and corrupt the `.mp4` — so it must be observed
natively. Implement `FlutterSceneLifeCycleDelegate` (register it via the
registrar's `addSceneDelegate`) and map the UIScene callbacks 1:1:

```swift
// In the plugin's scene-lifecycle delegate. `engine` is the CameraEngine the
// plugin constructed with initialPhase: (no default — pass .background if unsure).
func sceneDidBecomeActive(_ scene: UIScene)    { Task { await engine.setLifecyclePhase(.active) } }
func sceneWillResignActive(_ scene: UIScene)   { Task { await engine.setLifecyclePhase(.inactive) } }
func sceneDidEnterBackground(_ scene: UIScene) { Task { await engine.setLifecyclePhase(.background) } }
// (no scene callback maps to a 4th phase; `sceneWillEnterForeground` needs no
//  forward — `sceneDidBecomeActive` carries the `.active` transition.)
```

Forward on every transition — `setLifecyclePhase` never throws and the latest
call wins. Per-phase behavior is the [table above](#what-each-phase-reconciles-to);
the device-interruption lifecycle (`AVCaptureSession` interruptions, recovery,
watchdogs) is owned entirely by CameraKit and needs no plugin or Dart wiring.

### Driving the camera from Dart

Dart drives everything *except* lifecycle:

- **Commands** — `open`, `captureImage` / `captureNaturalPicture`,
  `setResolution`, `setProcessingParams`, calibration, `startRecording` /
  `stopRecording` — go Dart → MethodChannel/Pigeon → the native bridge → the
  matching `CameraEngine` method.
- **Streams** — the native layer forwards each engine `AsyncStream`
  (`stateStream`, `frameResultStream`, `errorStream`, `recordingStateStream`)
  onto an `EventChannel` the Dart side listens to.
- **Preview** — the native layer registers a `FlutterTexture` backed by the
  engine's preview surface (`currentPixelBuffer(stream:)` / `currentTexture()`);
  Dart renders it with a `Texture` widget.

Dart still *sees* its own `AppLifecycleState`, but uses it only for **its own
rendering** (e.g. paint the `Texture` widget vs. a placeholder) — and even that
is better driven by CameraKit's `stateStream` (over the `EventChannel`), which
reflects what the camera is *actually* doing rather than what the OS reported a
few milliseconds ago.
