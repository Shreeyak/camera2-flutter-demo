# Comprehensive Exploration Report: Cambrian Camera Plugin Structure

> **Date:** 2026-03-31
> **Scope:** Full audit of the implemented `cambrian_camera` plugin as of Phase 3.
> **Device:** OPD2403 (YUV_420_888 only — RGBA_8888 not supported by hardware).

---

## 1. Directory Structure

```
packages/cambrian_camera/
├── lib/                                    # Dart public API
│   ├── cambrian_camera.dart                 # Barrel export
│   └── src/
│       ├── cambrian_camera_controller.dart   # CambrianCamera class
│       ├── cambrian_camera_preview.dart      # CambrianCameraPreview widget
│       ├── camera_settings.dart              # CameraSettings & ProcessingParams
│       ├── camera_state.dart                 # CameraState enum & CameraError
│       ├── camera_settings_serializer.dart   # Latest-value-wins debounce
│       └── messages.g.dart                   # Pigeon generated (Dart side)
│
├── android/src/main/
│   ├── kotlin/com/cambrian/camera/
│   │   ├── CambrianCameraPlugin.kt           # FlutterPlugin entry point
│   │   ├── CameraController.kt               # Camera2 lifecycle (~1200 lines)
│   │   ├── Messages.g.kt                     # Pigeon generated (Kotlin side)
│   │   └── MetadataLayout.kt                 # Frame metadata marshaling
│   │
│   └── cpp/
│       ├── include/
│       │   ├── cambrian_camera_native.h       # Public C++ consumer API (Phase 4)
│       │   └── MetadataLayout.h               # Metadata struct definitions
│       └── src/
│           ├── CameraBridge.cpp               # JNI glue (4 exported functions)
│           └── ImagePipeline.cpp              # ANativeWindow rendering (unused in YUV path)
│
├── pigeons/
│   └── camera_api.dart                       # Pigeon service definition
│
├── ios/                                     # Stub (not implemented)
├── test/                                    # Unit tests
└── pubspec.yaml                             # Plugin metadata & dependencies

lib/                                         # Demo app
├── main.dart                                # CameraScreen — lifecycle & UI
├── camera/
│   ├── camera_callbacks.dart                # Callback bundles for widgets
│   └── camera_settings_values.dart          # Settings state & ranges
└── widgets/                                 # Bottom bar, overlays, controls
```

---

## 2. Dart-Side API

### 2.1 Public Exports

**`packages/cambrian_camera/lib/cambrian_camera.dart`** exports:
- `CambrianCamera` — main controller
- `CambrianCameraPreview` — preview widget
- `CameraSettings`, `ProcessingParams` — configuration
- `CameraState`, `CameraError` — state management
- `CameraCapabilities`, `CameraSize` — device info

### 2.2 CambrianCamera Controller

**File:** `lib/src/cambrian_camera_controller.dart`

```
CambrianCamera
├── Static
│   _instances: Map<int, CambrianCamera>       # Callback routing by handle
│
├── Instance State
│   _handle: int                               # SurfaceProducer.id (also textureId)
│   _hostApi: CameraHostApi                    # Pigeon Dart→Kotlin
│   _capabilities: CameraCapabilities
│   _currentState: CameraState
│   _stateController: StreamController<CameraState>  (broadcast)
│   _errorController: StreamController<CameraError>  (broadcast)
│   _serializer: CameraSettingsSerializer      # Latest-value-wins debounce
│
├── Factory
│   CambrianCamera.open({cameraId?, settings?}) → Future<CambrianCamera>
│     Calls CameraHostApi.open() → receives handle
│     Fetches capabilities, registers in _instances, returns controller
│
├── Public API
│   get textureId → int                        # For Flutter Texture widget
│   get capabilities → CameraCapabilities
│   get state → CameraState
│   get stateStream → Stream<CameraState>
│   get errorStream → Stream<CameraError>
│   updateSettings(CameraSettings) → Future<void>
│   setProcessingParams(ProcessingParams) → void  # Fire-and-forget (Phase 4)
│   takePicture() → Future<String>             # Returns JPEG file path
│   getNativePipelineHandle() → Future<int>    # C++ IImagePipeline* as int64
│   buildPreview({fit, placeholder}) → Widget
│   close() → Future<void>
│
└── Callback Routing
    _FlutterApiDispatcher (singleton)
      Routes Kotlin→Dart callbacks by handle via CameraFlutterApi.setUp()
      onStateChanged(handle, state) → _stateController.add()
      onError(handle, error) → _errorController.add()
```

### 2.3 Pigeon Contract

**File:** `pigeons/camera_api.dart` — generates Dart (`messages.g.dart`) and Kotlin (`Messages.g.kt`).

**Data classes:**

| Pigeon Class | Key Fields |
|---|---|
| `CamSettings` | `iso?`, `exposureTimeNs?`, `focusDistanceDiopters?`, `zoomRatio?`, `afEnabled?`, `awbLocked?`, `noiseReductionMode?`, `edgeMode?`, `evCompensation?` |
| `CamProcessingParams` | `blackR/G/B`, `gamma`, `histBlackPoint/WhitePoint`, `autoStretch`, `brightness`, `saturation` |
| `CamCapabilities` | `supportedSizes`, ISO/exposure/focus/zoom ranges, `evCompensationStep`, `estimatedMemoryBytes` |
| `CamStateUpdate` | `state: String` — one of `"closed"`, `"opening"`, `"streaming"`, `"recovering"`, `"error"` |
| `CamError` | `code: String`, `message: String`, `isFatal: bool` |

**Host API (Dart → Kotlin):**

| Method | Returns | Notes |
|---|---|---|
| `open(cameraId?, settings?)` | `Future<int>` | Handle (SurfaceProducer ID) |
| `getCapabilities(handle)` | `Future<CamCapabilities>` | Queries CameraCharacteristics |
| `updateSettings(handle, settings)` | `void` | Applies to repeating CaptureRequest |
| `setProcessingParams(handle, params)` | `void` | No-op in Phase 3 |
| `takePicture(handle)` | `Future<String>` | JPEG file path |
| `getNativePipelineHandle(handle)` | `Future<int>` | C++ pointer as int64 |
| `close(handle)` | `Future<void>` | Tears down all resources |

**Flutter API (Kotlin → Dart):**

| Callback | Payload |
|---|---|
| `onStateChanged(handle, CamStateUpdate)` | State transition |
| `onError(handle, CamError)` | Error with `isFatal` flag |

### 2.4 Supporting Dart Classes

**CameraSettings** (`camera_settings.dart`):
- Immutable, all fields nullable (null = "don't change this setting")
- `.toCam()` converts to Pigeon `CamSettings`
- `.copyWith()` for partial updates

**ProcessingParams** (`camera_settings.dart`):
- Immutable processing pipeline parameters (Phase 4)
- Fire-and-forget — no queuing or debounce

**CameraState** (`camera_state.dart`):
```
closed → opening → streaming ⟷ recovering ⟷ error
```

**CameraError** (`camera_state.dart`):
- Error codes emitted by `CameraController.kt`: `camera_device`, `camera_service`, `camera_disconnected`, `configuration_failed`, `permission_denied`, `camera_disabled`, `max_cameras_in_use`, `camera_in_use`, `preview_surface_lost`, `pipeline_error`, `unknown`
- `isFatal: bool` — fatal errors require manual close/reopen; non-fatal trigger auto-recovery

**CameraSettingsSerializer** (`camera_settings_serializer.dart`):
- Latest-value-wins, no debounce timer
- Sends immediately when idle; if a send is in-flight, replaces any pending value (only the newest reaches the platform)
- Drains the pending value on completion

---

## 3. Kotlin Native Side

### 3.1 Plugin Entry Point

**File:** `CambrianCameraPlugin.kt`

**Implements:** `FlutterPlugin`, `ActivityAware`, `CameraHostApi`

```
CambrianCameraPlugin
├── Engine-Scoped State
│   applicationContext: Context
│   textureRegistry: TextureRegistry
│   flutterApi: CameraFlutterApi          # Kotlin→Dart callbacks
│   sessions: MutableMap<Long, CameraSession>
│
├── Activity-Scoped State
│   activity: Activity?                    # For permission checks
│
├── Lifecycle
│   onAttachedToEngine()   → Stores context, registry, creates flutterApi
│   onDetachedFromEngine() → Releases all sessions
│   onAttachedToActivity() → Stores activity ref
│   onDetachedFromActivity() → Clears activity ref
│
└── CameraHostApi Methods
    open()  → Creates SurfaceProducer + CameraController, stores in sessions
    close() → Delegates to controller, releases producer, removes session
    (others delegate directly to the matching CameraController method)
```

**`CameraSession`** = `data class(producer: SurfaceProducer, controller: CameraController)`

### 3.2 CameraController — Camera2 Lifecycle Manager

**File:** `CameraController.kt` (~1200 lines)

This is the heart of the plugin. It manages the Camera2 device, capture session, ImageReaders, preview surface, and error recovery.

#### State Machine

```
CLOSED → OPENING → STREAMING ⟷ RECOVERING ⟷ ERROR
```

Auto-recovery on non-fatal errors:
- Backoff delays: `[500ms, 1s, 2s, 4s, 8s]`
- Max retries: 5
- Resets on successful open

#### JNI Declarations (Legacy — Phase 3 Unused in Frame Path)

```kotlin
companion object {
    init { System.loadLibrary("cambrian_camera") }
    external fun nativeInit(previewSurface: Surface): Long
    external fun nativeDeliverFrame(ptr: Long, data: ByteBuffer, w: Int, h: Int, stride: Int)
    external fun nativeRelease(ptr: Long)
    external fun nativeSetPreviewWindow(ptr: Long, surface: Surface?)
}
```

> **Note:** `nativeDeliverFrame()` is declared but never called in the YUV path.
> The C++ pipeline is initialized for future Phase 4 use, but YUV preview
> rendering goes directly through Flutter's `SurfaceProducer`.

#### Frame Format

Hardcoded to `YUV_420_888`:
```kotlin
// resolveStreamFormat() returns:
Triple(ImageFormat.YUV_420_888, 4160, 3120)
```

The OPD2403 does not advertise `RGBA_8888` as a supported output format. There is no fallback — YUV is the only path.

#### Session Setup

```
startCaptureSession(openCallback)
  1. resolveStreamFormat() → YUV_420_888, 4160x3120
  2. Create ImageReaders:
     - streamReader: YUV_420_888, 2 buffers (streaming)
     - jpegReader: JPEG, 1 buffer (still capture)
  3. nativeInit(previewSurface) → stores nativePipelinePtr (for Phase 4)
  4. Wire OnImageAvailableListener:
     - Drains YUV frames (acquireLatestImage → close) to prevent overflow
     - Preview rendering handled by Camera2 → SurfaceProducer directly
  5. Create CameraCaptureSession targeting:
     - streamReader.surface
     - surfaceProducer.surface  ← Camera2 writes YUV directly here
  6. Build initial CaptureRequest (auto or from pendingSettings)
  7. session.setRepeatingRequest() → emit "streaming" state
```

#### SurfaceProducer Lifecycle

```
surfaceProducer.setCallback()
  onSurfaceAvailable()
    → Resizes SurfaceProducer to match stream dimensions
    → Calls nativeSetPreviewWindow() (for future C++ use)
    → Rebinds capture session if needed
  onSurfaceCleanup()
    → Calls nativeSetPreviewWindow(null) — pauses C++ rendering
```

Flutter may recycle the preview surface at any time (hot reload, navigation). The callback ensures graceful handling.

#### Key Methods

| Method | Behavior |
|---|---|
| `open(cameraId?, settings?, callback)` | Permission check → resolve camera ID → open device → start session |
| `close(callback)` | Teardown all resources → emit "closed" |
| `getCapabilities(callback)` | Query `CameraCharacteristics` → return ranges, sizes, memory estimate |
| `updateSettings(settings)` | Store pending → build new `CaptureRequest` → `setRepeatingRequest()` |
| `setProcessingParams(params)` | No-op in Phase 3 |
| `takePicture(callback)` | JPEG `CaptureRequest` → jpegReader → write to cache → return path |
| `getNativePipelineHandle(callback)` | Return `nativePipelinePtr` (0 if not initialized) |

#### Error Handling

| Type | Behavior |
|---|---|
| **Non-fatal** (`camera_disconnected`, `camera_service`, `preview_surface_lost`, ...) | Emit "recovering" state → teardown → retry with exponential backoff |
| **Fatal** (`permission_denied`, `camera_disabled`, `max_cameras_in_use`, ...) | Emit "error" state → teardown → no auto-recovery (requires close + reopen) |

---

## 4. C++ Native Side

### 4.1 Current Status

The C++ layer was built during Phase 3 for RGBA frame processing. With the device's lack of RGBA support, it is **not in the active frame delivery path**. The pipeline is initialized (`nativeInit`) and the pointer stored, but `nativeDeliverFrame()` is never called. The C++ code remains as scaffolding for Phase 4, which will implement YUV-aware processing.

### 4.2 JNI Bridge

**File:** `CameraBridge.cpp`

| JNI Function | Status | Purpose |
|---|---|---|
| `nativeInit(surface)` | Called | Creates `ImagePipeline`, acquires `ANativeWindow` |
| `nativeDeliverFrame(ptr, buf, w, h, stride)` | **Not called** | Was for RGBA frame delivery |
| `nativeRelease(ptr)` | Called | Cleanup on close |
| `nativeSetPreviewWindow(ptr, surface)` | Called | Surface swap on Flutter recycle |

### 4.3 ImagePipeline

**File:** `ImagePipeline.cpp`

Phase 3 identity pipeline — copies RGBA frames to `ANativeWindow`. Currently idle since no frames are delivered to it.

```cpp
class ImagePipeline : public IImagePipeline {
    ImagePipeline(ANativeWindow* window);   // Acquire reference
    ~ImagePipeline();                        // Release reference
    void setPreviewWindow(ANativeWindow*);   // Swap surface
    void processFrame(const uint8_t*, int w, int h, int stride);  // RGBA blit (unused)
};
```

### 4.4 Public Consumer API (Phase 4 Placeholder)

**File:** `cambrian_camera_native.h`

Defines types for Phase 4's sink-based frame distribution:

```cpp
namespace cam {
    struct FrameMetadata { frameNumber, sensorTimestampNs, exposureTimeNs, iso };
    struct SinkFrame { data, width, height, stride, channels, meta, release };
    struct SinkConfig { name, width, height, channels, ringSize, dropOnFull };
    using SinkCallback = std::function<void(SinkFrame&)>;

    class IImagePipeline {
        // Phase 4: addSink(), removeSink()
    };
}
```

---

## 5. Data Flow Diagrams

### 5.1 Camera Open

```
Dart: CambrianCamera.open(cameraId?, settings?)
  │
  ▼  Pigeon
Kotlin: CambrianCameraPlugin.open()
  ├─ Create TextureRegistry.SurfaceProducer → handle = producer.id()
  ├─ Construct CameraController(context, producer, flutterApi, handle)
  ├─ Store in sessions[handle]
  └─ controller.open(cameraId, settings)
       │
       ▼  Background thread
       ├─ Check CAMERA permission
       ├─ Resolve cameraId (null → first back-facing)
       ├─ Emit "opening" → Dart
       ├─ cameraManager.openCamera()
       │    └─ onOpened() → startCaptureSession()
       │         ├─ ImageReader: YUV_420_888 (streaming)
       │         ├─ ImageReader: JPEG (still capture)
       │         ├─ nativeInit(previewSurface) → C++ pipeline ptr
       │         ├─ Wire frame drain listener (YUV → acquire → close)
       │         ├─ createCaptureSession([streamReader, surfaceProducer])
       │         ├─ setRepeatingRequest()
       │         └─ Emit "streaming" → Dart
       │
       ▼
  Return handle → Dart constructor
  ├─ getCapabilities(handle)
  └─ Return CambrianCamera ready for use
```

### 5.2 Frame Rendering (YUV Path)

```
Camera2 sensor captures frame
  │
  ├──► SurfaceProducer.surface (Camera2 output target)
  │      └─ Flutter engine renders to Texture widget directly
  │         (no Dart/Kotlin/C++ code in this path)
  │
  └──► ImageReader (YUV_420_888)
         └─ OnImageAvailableListener
              └─ acquireLatestImage() → image.close()
                 (drain only — prevents buffer overflow)
```

> **Key difference from RGBA path:** Camera2 writes directly to the
> `SurfaceProducer` surface. There is no C++ processing step. The
> `ImageReader` exists to keep the Camera2 pipeline flowing and will
> be the feed point for Phase 4's C++ ISP.

### 5.3 Settings Update

```
UI slider drag
  │
  ▼
camera.updateSettings(CameraSettings(...))
  │
  ▼
CameraSettingsSerializer (50ms debounce, latest-value-wins)
  │  ← Rapid calls: only the final value survives
  ▼  Pigeon
CameraController.updateSettings(settings)
  ├─ Build new CaptureRequest with updated fields:
  │    ISO, SENSOR_EXPOSURE_TIME, LENS_FOCUS_DISTANCE,
  │    SCALER_CROP_REGION (zoom), AF mode, AWB lock, etc.
  ├─ session.setRepeatingRequest(newRequest)
  └─ Takes effect on next captured frame
```

### 5.4 Still Capture

```
camera.takePicture()
  │  Pigeon
  ▼
CameraController.takePicture()
  ├─ Build JPEG CaptureRequest → jpegImageReader
  ├─ session.capture(jpegRequest, callback)
  └─ Background thread:
       ├─ jpegReader.acquireNextImage()
       ├─ Extract JPEG bytes from planes[0].buffer
       ├─ Write to <cacheDir>/capture_<timestamp>.jpg
       └─ Return absolute path → Dart
```

### 5.5 State & Error Callbacks (Kotlin → Dart)

```
Camera2 error (device/session/capture)
  │
  ▼
CameraController
  ├─ Non-fatal path:
  │    ├─ flutterApi.onStateChanged(handle, "recovering")
  │    ├─ flutterApi.onError(handle, {code, msg, isFatal=false})
  │    ├─ teardown()
  │    └─ Schedule retry (exponential backoff)
  │
  └─ Fatal path:
       ├─ flutterApi.onStateChanged(handle, "error")
       ├─ flutterApi.onError(handle, {code, msg, isFatal=true})
       └─ teardown() — no auto-recovery
  │
  ▼  Pigeon reverse channel
Dart: _FlutterApiDispatcher.onStateChanged / onError
  └─ Routes by handle → CambrianCamera instance
       ├─ _stateController.add(newState)
       └─ _errorController.add(error)
              │
              ▼
         StreamBuilder in UI rebuilds
```

---

## 6. Design Patterns

### Handle-Based Resource Management

The `SurfaceProducer.id()` serves double duty as both the Flutter `Texture` widget ID and the session lookup key. This allows multiple simultaneous camera instances and provides a single opaque identifier that routes through every layer.

### Latest-Value-Wins Serializer

When the user drags a slider, `updateSettings()` may fire 30+ times per second. The `CameraSettingsSerializer` debounces with a 50ms timer — each new call cancels the pending one, so only the most recent value reaches the platform channel. This prevents a queue of stale `CaptureRequest` updates from piling up in Camera2.

### Split Signal Path

Two separate `ImageReader` instances prevent still capture from interfering with streaming:
- **Streaming reader** (YUV, 2 buffers): drained continuously, feeds Phase 4 pipeline
- **JPEG reader** (1 buffer): used only during `takePicture()`

Camera2's output surface list includes both readers plus the `SurfaceProducer`, so all three receive frames from the same capture session.

### Exponential Backoff Recovery

Non-fatal Camera2 errors (disconnects, service crashes) trigger automatic recovery:
```
Attempt 1: wait  500ms → retry open()
Attempt 2: wait 1000ms → retry
Attempt 3: wait 2000ms → retry
Attempt 4: wait 4000ms → retry
Attempt 5: wait 8000ms → retry
Attempt 6: give up → fatal error
```
Counter resets on successful open.

### Broadcast Streams

`stateStream` and `errorStream` use `StreamController.broadcast()`, allowing multiple widgets to independently react to camera lifecycle changes without interfering with each other.

---

## 7. Demo App Integration

**File:** `lib/main.dart`

```
CameraScreen (StatefulWidget)
├── State
│   _camera: CambrianCamera?
│   _values: CameraSettingsValues        # Current slider positions
│   _ranges: CameraRanges                # Min/max from capabilities
│   _callbacks: CameraCallbacks          # Bound methods for widgets
│
├── initState()
│   ├─ Request CAMERA permission
│   ├─ CambrianCamera.open() → _camera
│   ├─ Extract capabilities → _ranges
│   └─ Initialize _values with defaults
│
├── Settings Callbacks
│   _onIsoChanged, _onExposureTimeNsChanged,
│   _onFocusDistanceChanged, _onZoomRatioChanged, etc.
│   └─ Update _values → _applySettings()
│        └─ camera.updateSettings(CameraSettings(...))
│
├── UI Layout
│   ├─ Two side-by-side preview panes
│   │   └─ camera.buildPreview(fit: BoxFit.cover)
│   │       └─ CambrianCameraPreview → Texture(textureId: camera.textureId)
│   └─ Bottom bar with ruler dial overlay
│       └─ CameraControlOverlay (interactive sliders)
│
└── dispose()
    └─ camera.close()
```

---

## 8. Phase 3 → Phase 4 Gap Analysis

| Area | Phase 3 (Current) | Phase 4 (Planned) |
|---|---|---|
| **Frame format** | YUV_420_888, drained | YUV → C++ for processing |
| **C++ pipeline** | Initialized but idle | YUV decode → processing → ANativeWindow |
| **Processing** | None | Black balance, gamma, histogram stretch, brightness, saturation |
| **setProcessingParams** | No-op | Forwards to C++ pipeline |
| **Sink system** | Types defined, not implemented | `addSink()` / `removeSink()` for native consumers |
| **Preview source** | Camera2 → SurfaceProducer directly | C++ pipeline → ANativeWindow (processed) |
| **nativeDeliverFrame** | Not called | Called with YUV data per frame |

The key Phase 4 transition: preview rendering moves from Camera2's direct `SurfaceProducer` output to the C++ pipeline's `ANativeWindow` output, so that processing is visible in the preview and pixel-identical to what native consumers receive.

---

## 9. File Reference

| File | Purpose |
|---|---|
| `lib/cambrian_camera.dart` | Barrel export |
| `lib/src/cambrian_camera_controller.dart` | `CambrianCamera` class — lifecycle, streams, API |
| `lib/src/cambrian_camera_preview.dart` | `CambrianCameraPreview` — Texture wrapper widget |
| `lib/src/camera_settings.dart` | `CameraSettings`, `ProcessingParams` — immutable models |
| `lib/src/camera_state.dart` | `CameraState` enum, `CameraError`, `CameraCapabilities` |
| `lib/src/camera_settings_serializer.dart` | Latest-value-wins debounce (50ms) |
| `lib/src/messages.g.dart` | Pigeon generated — Dart side |
| `pigeons/camera_api.dart` | Pigeon source definition |
| `android/.../CambrianCameraPlugin.kt` | Plugin entry — FlutterPlugin, ActivityAware, session map |
| `android/.../CameraController.kt` | Camera2 lifecycle, ImageReaders, JNI bridge (~1200 lines) |
| `android/.../Messages.g.kt` | Pigeon generated — Kotlin side |
| `android/.../MetadataLayout.kt` | Frame metadata marshaling |
| `cpp/include/cambrian_camera_native.h` | Phase 4 public C++ API (types + IImagePipeline) |
| `cpp/include/MetadataLayout.h` | C++ metadata struct definitions |
| `cpp/src/CameraBridge.cpp` | JNI glue — 4 exported functions |
| `cpp/src/ImagePipeline.cpp` | ANativeWindow rendering (Phase 3: idle) |
| `lib/main.dart` | Demo app — CameraScreen with settings UI |
| `lib/camera/camera_settings_values.dart` | Settings state & capability ranges |
| `lib/camera/camera_callbacks.dart` | Callback bundles for UI widgets |
