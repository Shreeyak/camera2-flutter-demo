# Camera2 Flutter Plugin Architecture v2

## Quick Reference

A Flutter plugin (`cambrian_camera`) that captures camera frames on Android via Camera2, applies real-time GPU post-processing (brightness, contrast, gamma, saturation, white balance), and delivers processed frames to both a Flutter preview and any number of native C++ consumer sinks.

### Layer map

| Layer | Language | Key file(s) | Role |
|-------|----------|-------------|------|
| L1 Dart Public API | Dart | `lib/src/cambrian_camera_controller.dart` | `CambrianCamera` class, streams, settings |
| L2 Platform Interface | Dart/Kotlin (generated) | `pigeons/camera_api.dart` → `messages.g.dart`, `Messages.g.kt` | Pigeon type-safe bridge |
| L3 Flutter Plugin | Kotlin | `CambrianCameraPlugin.kt` | Plugin entry, TextureRegistry, Pigeon host |
| L4 Camera Controller | Kotlin | `CameraController.kt`, `VideoRecorder.kt`, `GpuPipeline.kt` | Camera2 lifecycle, auto-recovery, recording, GL thread |
| L5 JNI Bridge | C++ | `CameraBridge.cpp` | Deserialize metadata, call pipeline |
| L6 C++ Pipeline | C++ | `ImagePipeline.cpp`, `GpuRenderer.cpp` | GPU rendering, post-processing, consumer fan-out |

All paths are relative to `packages/cambrian_camera/android/src/main/`.

### Key invariants (preserve when modifying code)

- **Preview = consumer output.** The tone-mapped preview is pixel-identical to what `FULL_RES` sinks receive.
- **1 memcpy per frame.** PBO → `std::vector` in `SharedFrame`. All downstream dispatch is `shared_ptr` copy only.
- **No per-frame allocation.** Ring buffers are pre-allocated at sink registration time.
- **`null` = don't change.** `CameraSettings` fields that are `null` retain their previous Kotlin-side values.
- **ISO ↔ exposure are coupled.** Setting either to `auto` propagates to the other via Camera2's single AE flag.
- **LUT rebuilt atomically.** When `ProcessingParams` change, the 256-entry LUT is rebuilt and swapped; no partial updates visible to the frame loop.
- **Latest-value-wins for CameraSettings.** No debounce — in-flight values are replaced, not queued.
- **Fire-and-forget for ProcessingParams.** No serializer — mutex-protected struct copy in C++, next frame picks up new values.
- **Recording encodes GPU output directly.** MediaCodec surface receives tone-mapped FBO via EGL blit — no CPU YUV copy.

### Section index

| Section | What it covers |
|---------|---------------|
| Architecture Overview | 6-layer ASCII diagram |
| Key Design Decisions | Pigeon, YUV format, ISP settings, SurfaceProducer, consumer model, auto-recovery |
| Plugin File Structure | Complete directory tree with annotations |
| Dart Public API | `CambrianCamera` class, all types, settings update strategies |
| Platform Bridge | Pigeon interface + JNI metadata layout |
| Kotlin Layer | Auto-recovery state machine + video recording subsystem |
| C++ Pipeline Internals | GPU rendering, frame delivery, buffer ownership, processing stages, consumer fan-out, ring buffers, memory budget |
| C++ Native Consumer API | Public header, sink registration example |
| Testing Strategy | Dart unit, C++ unit, Kotlin integration, on-device tests |

---

## Architecture Overview (6 Layers)

```
┌─────────────────────────────────────────────────────────────┐
│  L1: Dart Public API          (packages/cambrian_camera/lib)│
│  CambrianCamera, CameraSettings, ProcessingParams, streams  │
└──────────────────────────┬──────────────────────────────────┘
                           │ Pigeon-generated type-safe interface
┌──────────────────────────┴──────────────────────────────────┐
│  L2: Platform Interface   (Pigeon @HostApi / @FlutterApi)    │
│  CameraHostApi → Kotlin, CameraFlutterApi → Dart callbacks   │
└──────────────────────────┬──────────────────────────────────┘
                           │ Generated Kotlin bindings
┌──────────────────────────┴──────────────────────────────────┐
│  L3: Kotlin FlutterPlugin (CambrianCameraPlugin.kt)          │
│  FlutterPlugin + ActivityAware, TextureRegistry, Pigeon host │
└──────────────────────────┬──────────────────────────────────┘
                           │ direct Kotlin calls
┌──────────────────────────┴──────────────────────────────────┐
│  L4: Kotlin CameraController                                 │
│  Camera2 lifecycle, ImageReader, per-request ISP settings,   │
│  auto-recovery state machine                                 │
└──────────────────────────┬──────────────────────────────────┘
                           │ JNI (DirectByteBuffer + flat arrays)
┌──────────────────────────┴──────────────────────────────────┐
│  L5: C++ JNI Bridge  (CameraBridge.cpp)                      │
│  Deserialize metadata, wrap buffers, call pipeline           │
└──────────────────────────┬──────────────────────────────────┘
                           │ C++ calls
┌──────────────────────────┴──────────────────────────────────┐
│  L6: C++ ImagePipeline                                       │
│  Post-processing, preview output, generic consumer fan-out   │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **Pigeon over raw MethodChannel** | Type-safe generated Dart/Kotlin bridge; eliminates string-based method name bugs. `@FlutterApi` replaces EventChannel for callbacks. |
| **YUV_420_888 for streaming** | `resolveStreamFormat()` queries `StreamConfigurationMap`, selects largest 4:3 size (sensor native AR), falls back to 1280×960. Resolution reported in `CameraCapabilities.streamWidth/streamHeight`. |
| **Per-request ISP settings** | All `CameraSettings` map to `CaptureRequest` keys — rebuilds repeating request only (no session reconfiguration). Session-level changes (format/size) trigger full stop/start. |
| **SurfaceProducer for preview** | Flutter's `TextureRegistry.SurfaceProducer` provides the preview Surface. Camera2 writes directly into it as a `CaptureRequest` target — no C++ memcpy on preview path. On surface invalidation (hot restart), controller rebinds to new Surface; `SurfaceProducer.id` is stable. |
| **Generic consumer model** | No hardcoded outputs. Applications register C++ sinks with the config they need (resolution, channels, ring size). Library handles downscaling, channel extraction, ring buffers per-sink. |
| **Auto-recovery** | Camera errors handled internally with exponential backoff. Dart receives state transitions (including `recovering`) but doesn't implement recovery logic. |

---

## Plugin File Structure

```
packages/cambrian_camera/
├── pubspec.yaml
├── pigeons/
│   └── camera_api.dart                  # Pigeon interface definition
├── lib/
│   ├── cambrian_camera.dart             # barrel export
│   └── src/
│       ├── cambrian_camera_controller.dart   # CambrianCamera class
│       ├── camera_settings.dart              # CameraSettings, ProcessingParams
│       ├── camera_state.dart                 # CameraState, CameraCapabilities, CameraError, RecordingState
│       ├── camera_settings_serializer.dart   # Latest-value-wins for CameraSettings
│       ├── frame_result.dart                 # FrameResult (actual sensor values from hardware)
│       └── messages.g.dart                   # Generated by Pigeon
├── android/
│   ├── build.gradle.kts
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── kotlin/com/cambrian/camera/
│       │   ├── CambrianCameraPlugin.kt       # FlutterPlugin + ActivityAware + Pigeon host
│       │   ├── CambrianCameraConfig.kt       # Configuration constants
│       │   ├── CameraController.kt           # Camera2 lifecycle + auto-recovery
│       │   ├── GpuPipeline.kt                # EGL context, GL thread, encoder surface
│       │   ├── VideoRecorder.kt              # MediaCodec/MediaMuxer, drain thread
│       │   ├── VideoRecordingReceiver.kt     # Broadcast receiver for recording state
│       │   ├── MetadataLayout.kt             # Shared metadata array constants
│       │   └── Messages.g.kt                 # Generated by Pigeon
│       └── cpp/
│           ├── CMakeLists.txt
│           ├── include/
│           │   ├── cambrian_camera_native.h   # Public consumer API (NO OpenCV)
│           │   └── MetadataLayout.h           # Shared metadata constants
│           ├── src/
│           │   ├── CameraBridge.cpp           # JNI glue
│           │   ├── GpuRenderer.cpp            # Dual-path GPU rendering (color + raw shaders)
│           │   ├── GpuRenderer.h              # GPU renderer internal header
│           │   ├── ImagePipeline.cpp          # Processing + generic fan-out
│           │   ├── ImagePipeline.h            # Internal header (may use OpenCV)
│           │   ├── InputRing.cpp              # Input ring buffer implementation
│           │   └── InputRing.h                # Input ring buffer header
│           └── test/
│               ├── SinkRoutingTest.cpp        # Consumer sink routing tests
│               └── TrackerDimTest.cpp         # Tracker dimension calculation tests
├── ios/                                       # Stub for future
│   ├── Classes/
│   │   ├── CambrianCameraPlugin.swift         # PlatformException("PLATFORM_NOT_SUPPORTED")
│   │   └── Messages.g.swift                   # Generated by Pigeon (iOS)
│   └── cambrian_camera.podspec
└── test/
    └── camera_settings_serializer_test.dart
```

---

## Dart Public API

### CambrianCamera

```dart
class CambrianCamera {
  /// Opens camera and starts the pipeline.
  static Future<CambrianCamera> open({
    String? cameraId,
    CameraSettings? settings,
  });

  Future<void> close();

  /// Flutter texture ID for the color-processed preview.
  Stream<CameraTextureInfo> get toneMappedTexture;

  /// Flutter texture ID for the raw (passthrough) preview.
  /// Only emits if enableRawStream: true was set in CameraSettings.
  Stream<CameraTextureInfo> get rawTexture;

  Stream<CameraState> get stateStream;
  Stream<CameraError> get errorStream;

  /// Actual sensor values reported by hardware. Emits ~3 Hz.
  Stream<FrameResult> get frameResultStream;

  CameraCapabilities get capabilities;

  /// Uses latest-value-wins serialization (see Key Invariants).
  Future<void> updateSettings(CameraSettings settings);

  /// Fire-and-forget: mutex-protected struct copy in C++, next frame picks up new values.
  Future<void> setProcessingParams(ProcessingParams params);

  Future<String> takePicture();

  /// Returns display rotation in degrees CW from portrait (0/90/180/270).
  static Future<int> getDisplayRotation();

  /// Native pipeline pointer for C++ consumer registration, or null if not initialized.
  Future<int?> getNativePipelineHandle();

  Future<(String, String)> startRecording({
    String? outputDirectory,  // MediaStore RELATIVE_PATH; default "Movies/CambrianCamera/"
    String? fileName,         // without extension; default timestamp
    int? bitrate,             // bits/sec; default 50 Mbps
    int? fps,                 // default 30
  });

  Future<String> stopRecording();
  Stream<RecordingState> get recordingStateStream;
}
```

### CameraSettings

Maps to per-request `CaptureRequest` keys. Auto-capable settings use sealed types (`AutoValue.auto()` | `AutoValue.manual(value)`):

```dart
class CameraSettings {
  final AutoValue<int>? iso;              // auto is contagious with exposureTimeNs
  final AutoValue<int>? exposureTimeNs;   // nanoseconds
  final AutoValue<double>? focus;         // diopters; auto = continuous AF
  final WhiteBalance? whiteBalance;       // auto() | locked() | manual(gainR, gainG, gainB)
  final double? zoomRatio;
  final NoiseReductionMode? noiseReductionMode;  // off/fast/highQuality/minimal/zeroShutterLag
  final EdgeMode? edgeMode;               // off/fast/highQuality/zeroShutterLag
  final int? evCompensation;              // steps; no effect when AE disabled
  final bool? enableRawStream;
  final int? rawStreamHeight;             // width auto-computed from aspect ratio
}
```

**Update strategy — latest-value-wins serializer:** Each change requires a Dart → Kotlin → `setRepeatingRequest` round trip. If a new value arrives while the previous is in-flight, the old pending value is replaced (not queued). No artificial latency. Implementation: `CameraSettingsSerializer` in `camera_settings_serializer.dart`.

### ProcessingParams

Controls the GPU color shader applied to every frame on the processed path:

```dart
class ProcessingParams {
  final double blackR, blackG, blackB;   // [0.0, 0.5] per-channel black level
  final double gamma;                     // [0.1, 4.0], 1.0 = identity
  final double brightness;               // [-1.0, +1.0], 0.0 = identity
  final double contrast;                  // [-1.0, +1.0], 0.0 = identity
  final double saturation;               // [-1.0, +1.0], 0.0 = identity
}
```

### Supporting types

```dart
enum CameraState { closed, opening, streaming, recovering, error }

enum RecordingState { recording, idle, error }

class CameraCapabilities {
  final List<CameraSize> supportedSizes;
  final int isoMin, isoMax;
  final int exposureTimeMinNs, exposureTimeMaxNs;
  final double focusMin, focusMax;
  final double zoomMin, zoomMax;
  final int evCompMin, evCompMax;
  final double evCompensationStep;
  final int streamWidth, streamHeight;       // chosen by resolveStreamFormat()
  final int rawStreamTextureId;              // 0 when disabled
  final int rawStreamWidth, rawStreamHeight; // 0 when disabled
}

class CameraError {
  final CameraErrorCode code;  // typedef to Pigeon-generated CamErrorCode
  final String message;
  final bool isFatal;          // false = informational (auto-recovering)
}

/// Serialized as integer indices — do NOT reorder; only append before [unknown].
enum CamErrorCode {
  cameraDevice,          // ERROR_CAMERA_DEVICE — fatal hardware failure
  cameraService,         // ERROR_CAMERA_SERVICE — camera service error
  cameraDisconnected,    // camera lost unexpectedly (system reclaim, USB)
  configurationFailed,   // session configuration or rebind failed
  permissionDenied,      // CAMERA permission denied or revoked — fatal
  cameraDisabled,        // ERROR_CAMERA_DISABLED — disabled by policy — fatal
  maxCamerasInUse,       // ERROR_MAX_CAMERAS_IN_USE — too many open — fatal
  cameraInUse,           // ERROR_CAMERA_IN_USE — another app holds the camera
  cameraAccessError,     // CameraAccessException (transient access failure)
  maxRetriesExceeded,    // auto-recovery gave up after max retries — fatal
  previewSurfaceLost,    // Flutter SurfaceProducer was invalidated
  pipelineError,         // C++ processing pipeline error
  settingsConflict,      // invalid settings combination
  frameStall,            // GPU pipeline stopped receiving frames
  unknown,               // catch-all; keep last
}

class FrameResult {
  final int? iso;
  final int? exposureTimeNs;
  final double? focusDistanceDiopters;  // 0.0 = infinity
  final double? wbGainR, wbGainG, wbGainB;
}
```

---

## Platform Bridge

### Pigeon Interface

Defined in `packages/cambrian_camera/pigeons/camera_api.dart`. Generated outputs: `messages.g.dart` (Dart), `Messages.g.kt` (Kotlin), `Messages.g.swift` (iOS stub).

**HostApi** (Dart → Kotlin): `open`, `getCapabilities`, `updateSettings`, `setProcessingParams`, `takePicture`, `getNativePipelineHandle`, `startRecording`, `stopRecording`, `getDisplayRotation`, `close`

**FlutterApi** (Kotlin → Dart): `onStateChanged`, `onError`, `onFrameResult`, `onRecordingStateChanged`

### JNI Metadata Layout

Flat arrays for zero-allocation metadata transfer between Kotlin (L4) and C++ (L5/L6). Layout defined in `MetadataLayout.kt` and `MetadataLayout.h` — these files **must** be kept in sync (matching array indices and counts).

C++ uses `static_assert` to verify counts match. Example: `static_assert(cam::meta::FLOAT_COUNT == 26, "Layout mismatch");`

---

## Kotlin Layer

### Diagnostic Logging

All log tags share a `CC/` prefix so they can be filtered with one command:

```bash
adb logcat | grep "CC/"
```

| Tag | Source | Content |
|-----|--------|---------|
| `CC/Cam` | CameraController | Lifecycle transitions, device/surface events, errors |
| `CC/3A` | CameraController | AE/AF/AWB state changes (Tier 1) and heartbeat (Tier 2) |
| `CC/Settings` | CameraController | Settings applied per `updateSettings()` call |
| `CC/Gpu` | GpuPipeline | Frame counter, stall detection, pipeline start/stop |
| `CC/Renderer` | GpuRenderer.cpp | EGL/GL operations, per-300-frame heartbeat |
| `CC/Plugin` | CambrianCameraPlugin | open/close/detach events |
| `CC/Dart` | cambrian_camera_controller.dart | Dart-side open/close/state/error (debug builds only) |

Log tiers are controlled by `CambrianCameraConfig`:

| Flag | Default | Effect |
|------|---------|--------|
| *(always on)* | — | Tier 0: lifecycle events, 3A state transitions, settings summary |
| `verboseDiagnostics` | `true` | Tier 2: `CC/3A` heartbeat every 30 frames (fps, drops, full 3A state) |
| `verboseSettings` | `true` | Verbose settings dump via `buildSettingsLog()` |
| `verboseFullResult` | `false` | Tier 3: full `TotalCaptureResult` dump every 30 frames |
| `debugDataFlow` | `false` | GPU pipeline initialization and frame-flow traces |

### Auto-Recovery State Machine

Implemented in `CameraController.kt`.

```
                    ┌──────────┐
                    │  CLOSED  │
                    └────┬─────┘
                         │ open()
                    ┌────▼─────┐
                    │ OPENING  │
                    └────┬─────┘
                         │ camera opened + session configured
                    ┌────▼──────┐
              ┌────►│ STREAMING │◄────────────────┐
              │     └────┬──────┘                  │
              │          │ error detected           │
              │     ┌────▼───────┐                 │
              │     │ RECOVERING │─────────────────┘
              │     └────┬───────┘  success (retry)
              │          │ max retries exceeded
              │     ┌────▼─────┐
              │     │  ERROR   │  (fatal — app must close/reopen)
              │     └──────────┘
              │
              └── close() from any state → CLOSED
```

**Recovery behavior:** Exponential backoff (500ms → 1s → 2s → 4s → max 8s). After 5 failures: fatal error, state = ERROR.

**Auto-recoverable:** `ERROR_CAMERA_DEVICE`, `ERROR_CAMERA_SERVICE`, `onDisconnected()`, `onConfigureFailed()`, `onSurfaceAvailable()` (preview rebinding).

**Fatal (no recovery):** `ERROR_CAMERA_DISABLED`, permission revoked, `ERROR_MAX_CAMERAS_IN_USE`.

#### Preview rebinding

When `SurfaceProducer` is invalidated (hot restart, activity recreation):
1. `onSurfaceAvailable()` fires with new Surface
2. `CameraController.rebindYuvPreviewSurface(newSurface)` — closes old session, creates new with `newSurface`
3. `SurfaceProducer.id` is stable — Dart does not rebuild the `Texture` widget

### Video Recording

Encodes tone-mapped GPU output directly to H.264/HEVC MP4. The encoder receives frames via a MediaCodec input surface on the GPU render thread.

**Key features:**
- Surface-mode `MediaCodec` — GPU blits to encoder surface, no CPU YUV copy
- HEVC preferred, automatic AVC fallback
- Configurable bitrate (default 50 Mbps) and fps (default 30)
- MediaStore integration with `IS_PENDING=1` during recording
- Auto-stop on app background (`AppLifecycleState.paused`)
- Startup cleanup of orphaned `IS_PENDING=1` entries

#### Recording data flow

```
Dart startRecording()
     │
     ├─► CameraController.startRecording()
     │   ├─► VideoRecorder.prepare() → MediaCodec.configure + MediaMuxer + drain thread
     │   ├─► gpuPipeline.setEncoderSurface() → EGL window surface created on GL thread
     │   └─► emit RecordingState.recording
     │
Each frame (GL thread):
     GpuRenderer::drawAndReadback()
     ├─► Render OES → FBO (tone-mapping shader)
     ├─► Blit FBO → preview surface (eglSwapBuffers → Flutter)
     ├─► Blit FBO → encoder surface (eglSwapBuffers → MediaCodec)  [when recording]
     └─► PBO readback → C++ sinks
     │
Dart stopRecording()
     └─► VideoRecorder.stop()
         ├─► signalEndOfInputStream → wait EOS latch (5s timeout)
         ├─► muxer.stop() [writes moov atom]
         └─► IS_PENDING=0 (visible in gallery)
```

#### Recording error handling

| Scenario | Action | Dart Result |
|----------|--------|-------------|
| Start fails (state invalid, codec init) | Emit error immediately | `RecordingState.error` |
| Disk full during drain | Store exception, rethrow on `stop()` | `RecordingState.error` |
| Muxer failure on `stop()` | Delete pending entry, rethrow | `RecordingState.error` |
| EOS drain timeout (5 sec) | Force stop, continue cleanup | `RecordingState.idle` (best-effort) |
| Force-stop during teardown | Emit error, delete or finalize entry | `RecordingState.error` |

#### Threading model

| Thread | Owner | Purpose |
|--------|-------|---------|
| Main thread | Dart/Flutter | Platform channel calls, Dart callbacks |
| `backgroundHandler` | CameraController | Camera2 operations |
| `glHandler` (GL thread) | GpuPipeline | GPU rendering, PBO readback, encoder blit |
| Drain thread | VideoRecorder | Polls MediaCodec output, writes to MediaMuxer |

Error emission always posts back to `mainHandler` for Dart callback safety.

---

## C++ Pipeline Internals

### Dual-path GPU rendering

`GpuRenderer.cpp` runs two shader passes per frame when `enableRawStream` is active:

```
Camera2 → SurfaceTexture → OES texture
  ├── [color shader]       → processedFBO → preview surface + FULL_RES/TRACKER sinks
  └── [passthrough shader] → rawFBO(rawH) → raw preview surface + RAW sinks
```

**Processed path** (always active): Color shader applies all `ProcessingParams` and renders into `processedFBO`.

**Raw path** (optional, `rawW_ > 0`): Passthrough shader — no adjustments, Camera2 image as-is in RGBA at `rawStreamHeight` resolution.

**Failure handling:** If raw init fails, `rawW_` is set to 0 and processed pipeline continues. Check `capabilities.rawStreamWidth > 0` to confirm raw is active.

**Raw resources** (allocated only when `rawW_ > 0`): `rawFBO`, `rawPBOs[2]` (double-buffered readback), `rawEGLSurface` (optional preview).

### Frame delivery (post-GPU readback)

```
Camera2 → GpuPipeline (GL thread) → GpuRenderer::drawAndReadback
  │
  ├─► fullResCb → ImagePipeline::deliverFullResRgba
  │   └─► memcpy PBO → std::vector in SharedFrame  (the 1 unavoidable copy)
  │       ├─► [no hook]  → publishToFullResConsumers (fast path)
  │       └─► [hook set] → mailbox → hook(in-place) → publishToFullResConsumers
  │           └─► per-consumer mailbox (1-slot, drop-on-busy) → dispatch thread → SinkCallback
  │
  ├─► trackerCb → deliverTrackerRgba  (same pattern, 480p)
  └─► rawCb → deliverRawRgba          (same pattern, passthrough)
```

```mermaid
sequenceDiagram
    participant Cam as Camera2
    participant GP as GpuPipeline.kt<br/>(GL thread)
    participant GR as GpuRenderer<br/>::drawAndReadback
    participant CB as fullResCb<br/>lambda
    participant IP as ImagePipeline<br/>::deliverFullResRgba
    participant PS as ProcessingStage<br/>(hook thread)
    participant PUB as publishTo<br/>FullResConsumers
    participant CD as Consumer<br/>dispatch thread
    participant UC as SinkCallback<br/>(user code)

    Cam->>GP: onFrameAvailable(SurfaceTexture)
    GP->>GR: nativeGpuDrawAndReadback(oesTexture, texMatrix, ...)
    Note over GR: Render OES→FBO, blit preview,<br/>PBO readback, map previous PBO
    GR->>CB: fullResCb(mapped_ptr, w, h, stride, frameId, meta)
    CB->>IP: deliverFullResRgba(mapped_ptr, w, h, stride, frameId, meta)
    Note over IP: memcpy mapped_ptr →<br/>std::vector in SharedFrame

    alt No hook set (fast path)
        IP->>PUB: publishToFullResConsumers(frame)
    else Hook set
        IP->>PS: post SharedFrame to 1-slot mailbox
        Note over PS: hook(rgba, w, h, stride)<br/>modifies data in-place
        PS->>PUB: publishToFullResConsumers(frame)
    end

    PUB->>CD: post SharedFrame to consumer mailbox (1-slot, drop-on-busy)
    CD->>UC: SinkFrame{data, w, h, stride, format, frameId, meta}
    Note over UC: shared_ptr ref keeps<br/>vector alive during callback
```

### Buffer ownership

One memcpy (PBO → vector), then `shared_ptr` copies only through the rest of the pipeline:

```
GPU PBO[readIdx]           (mapped GPU mem, ephemeral — valid only during callback)
     │
     └─► memcpy → SharedFrame (shared_ptr<Frame>, Frame.data = std::vector<uint8_t>)
           │
           ├─► [hook set?] → ProcessingStage mailbox (1-slot, drop-on-busy, shared_ptr copy)
           │                  └─► hook(data.data(), w, h, stride) runs in-place
           │                      └─► same SharedFrame → consumer mailboxes
           │
           └─► [no hook]  → consumer mailboxes (1 per sink, shared_ptr copy)
                             └─► dispatch thread: frame = std::move(pending)
                                 └─► SinkCallback: SinkFrame.data valid during callback
```

```mermaid
flowchart TD
    PBO["GPU PBO[readIdx]<br/><i>mapped GPU mem, ephemeral</i><br/><i>valid only during callback</i>"]
    SF["SharedFrame<br/><code>shared_ptr&lt;Frame&gt;</code><br/><code>Frame.data = std::vector&lt;uint8_t&gt;</code><br/><i>heap-allocated, ref-counted</i>"]
    PSM["ProcessingStage mailbox<br/><i>1-slot, drop-on-busy</i><br/><i>shared_ptr copy (no data copy)</i>"]
    HOOK["Hook runs in-place<br/><code>hook(data.data(), w, h, stride)</code><br/><i>mutates same buffer</i>"]
    CM["Consumer mailboxes<br/><i>1 per registered sink</i><br/><i>shared_ptr copy (no data copy)</i>"]
    DT["Consumer dispatch thread<br/><code>frame = std::move(pending)</code><br/><i>local ref keeps data alive</i>"]
    SCB["SinkCallback scope<br/><code>SinkFrame.data = frame-&gt;data.data()</code><br/><i>raw pointer, valid during callback</i>"]

    PBO -->|"memcpy<br/>(1 copy, unavoidable)"| SF
    SF -->|"hook set?"| PSM
    SF -->|"no hook<br/>(fast path)"| CM
    PSM --> HOOK
    HOOK -->|"same SharedFrame"| CM
    CM -->|"dispatch thread wakes"| DT
    DT --> SCB

    style PBO fill:#f9f,stroke:#333
    style SF fill:#bbf,stroke:#333
    style HOOK fill:#fdb,stroke:#333
    style CM fill:#bfb,stroke:#333
```

**Concurrency guarantee:** When a consumer's dispatch thread does `frame = std::move(pending)`, it takes ownership of the `shared_ptr`. New frames overwrite the mailbox slot but do NOT affect the local ref.

### Processing stages (GPU color shader, processed path only)

1. **Black balance** — per-channel level subtraction
2. **White balance gains** — per-channel multiply
3. **Gamma + brightness** — single pre-computed 256-entry LUT per channel (rebuilt atomically on `ProcessingParams` change)
4. **Saturation** — RGB luminance-deviation method (not HSV; 3 multiplies + 3 adds per pixel)

### Consumer fan-out

After GPU rendering and PBO readback, the pipeline fans out to registered sinks. Each sink has its own dispatch thread and 1-slot mailbox. Per-sink transforms (downscale via `cv::resize`, channel extraction) are applied before posting.

Preview rendering is separate — FBO blitted to Flutter `SurfaceProducer` surface via `eglSwapBuffers`, no CPU memcpy.

### Ring buffer design

`SlotRing<Slot>` — pre-allocated ring with `acquire()` / `release()` semantics. The `release` closure captures a `shared_ptr` to ring state, preventing use-after-free if pipeline is destroyed while a consumer holds a frame.

### Memory budget

All ring buffers pre-allocated at registration. Memory per sink = `width × height × channels × ringSize`.

Example (4K = 3840×2160):

| Sink | Resolution | Ch | Ring | Memory |
|------|-----------|-----|------|--------|
| Input ring (ImageReader) | 3840×2160 | 4 | 4 | 133 MB |
| ANativeWindow (preview) | 3840×2160 | 4 | 2 | 66 MB |
| "stitcher" consumer | 3840×2160 | 4 | 4 | 133 MB |
| "tracker" consumer | 960×540 | 1 | 8 | 4 MB |
| **Total (processed)** | | | | **~336 MB** |

Raw stream adds: rawFBO (~8 MB at 1080p), rawPBOs[2] (~16 MB), rawEGLSurface (~8 MB).

---

## C++ Native Consumer API

Header: `packages/cambrian_camera/android/src/main/cpp/include/cambrian_camera_native.h`

Key types: `IImagePipeline` (`addSink`/`removeSink`), `SinkConfig`, `SinkFrame`, `FrameMetadata`, `SinkRole`. Intentionally excludes OpenCV and library internals.

### Consumer registration example

```cpp
#include <cambrian_camera_native.h>

void registerConsumers() {
    auto* pipeline = cam::getPipeline();
    if (!pipeline) return;

    pipeline->addSink({"stitcher", cam::SinkRole::FULL_RES},
                      [](const cam::SinkFrame& frame) {
        // frame.data = full-res RGBA, valid for duration of callback
    });

    pipeline->addSink({"tracker", cam::SinkRole::TRACKER},
                      [](const cam::SinkFrame& frame) {
        // frame.data = 480p-height RGBA
    });

    pipeline->addSink({"raw_writer", cam::SinkRole::RAW},
                      [](const cam::SinkFrame& frame) {
        // frame.data = passthrough RGBA, no shader adjustments
    });
}
```

Dart can also call `getNativePipelineHandle()` and pass the pointer to app native code via FFI.

---

## Testing Strategy

| Layer | Scope | Key tests |
|-------|-------|-----------|
| **Dart unit** | `CameraSettingsSerializer` | Latest-value-wins, in-flight replacement, Pigeon serialization round-trips, state machine transitions (mock platform) |
| **C++ unit** (Google Test) | `SlotRing`, pipeline, metadata | Ring acquire/release + concurrency, golden-reference output, flat-array deserialization, per-sink transforms, `SinkRoutingTest.cpp`, `TrackerDimTest.cpp` |
| **Kotlin integration** | CameraController | State machine transitions, auto-recovery simulation, per-request settings on CaptureRequest |
| **On-device** | End-to-end | Camera → pipeline → preview + consumer frames, error recovery, preview rebinding, 5-min memory stability, ProcessingParams latency |
