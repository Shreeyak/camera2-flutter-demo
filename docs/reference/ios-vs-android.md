# iOS vs Android: Platform Differences

This document describes every place where the Android and iOS implementations of
`cambrian_camera` diverge — from the GPU stack down to file-system conventions.
The Dart public API is identical on both platforms; the differences below are
either behavioural (same method, different internals) or semantic (same field,
different value format).

---

## 1. GPU pipeline

| | Android | iOS |
|---|---|---|
| Rendering API | OpenGL ES 3 (via EGL) | Metal |
| Pipeline language | C++ (`GpuRenderer.cpp`, `ImagePipeline.cpp`) | Swift (`MetalPipeline.swift`, inside CameraKit) |
| Frame delivery to Dart | C++ → JNI → Kotlin → `FlutterTextureRegistry` | Swift `CameraEngine` → `FlutterTextureRegistry` |
| Native consumer API | `cambrian_camera_native.h` (`IImagePipeline`, `addSink`, `SinkFrame`) | CameraKit interop (`CameraKitInterop.swift`) — different header/ABI |
| `getNativePipelineHandle()` | Pointer to `IImagePipeline` (C++) | Pointer to the Swift engine's native handle |

Consumer apps that call `getNativePipelineHandle()` and register C++ sinks are
**not cross-platform** at the native level, even though the Dart call is
identical.

---

## 2. File storage

### Images — `captureImage()` / `captureNaturalPicture()`

Both methods return a `CamCaptureResult`. Which field is populated depends on
platform and the `destination` argument:

| Platform | `destination` | `filePath` | `phAssetLocalId` |
|---|---|---|---|
| iOS | `null` or `saveToLibrary: false` | Absolute path in app Documents dir | `null` |
| iOS | `saveToLibrary: true` | `null` | PHAsset local identifier |
| Android | any | Absolute path in app-specific Pictures dir | `null` |

`filePath` is always a bare POSIX path (e.g. `/private/var/mobile/.../Documents/IMG_….jpg`)
usable directly with `dart:io`.  Android never populates `phAssetLocalId`.

### Videos — `startRecording()` / `stopRecording()`

| | Android | iOS |
|---|---|---|
| `startRecording()` returns | `(content://… URI, display name)` | `(absolute file path, display name)` |
| `stopRecording()` returns | `content://… URI` | Absolute file path |
| Storage location | MediaStore (`Movies/CambrianCamera/`) | App Documents directory |

On **Android** the URI is a `content://` MediaStore URI.  It cannot be used
directly with `dart:io` — use Android's `ContentResolver` or a package such as
`open_file` to open it.

On **iOS** the URI is an absolute file path usable directly with `dart:io`:

```dart
final (uri, name) = await camera.startRecording();
// ...
final videoPath = await camera.stopRecording();
// dart:io works directly:
final file = File(videoPath);
await file.rename('/path/to/new/location.mp4');
```

### Where iOS files live

All captures and recordings are written to the app's **Documents directory**
(`NSDocumentDirectory`, accessible as `URL.documentsDirectory` in Swift).

Both example apps declare these `Info.plist` keys so the Documents directory is
visible in the **Files app** under *On My iPhone* and over USB/Finder:

```xml
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
```

Any app embedding `cambrian_camera` must include these keys in its own
`Info.plist` to expose captures to the user.

---

## 3. Permission API

All four methods exist on both platforms, but they are meaningful only on iOS:

| Method | iOS | Android |
|---|---|---|
| `cameraPermissionStatus()` | `AVCaptureDevice.authorizationStatus` | `ContextCompat.checkSelfPermission` |
| `requestCameraPermission()` | System prompt via `AVCaptureDevice.requestAccess` | Pigeon-level pass-through (Android runtime permissions are handled by `permission_handler` in the app) |
| `photosAddPermissionStatus()` | `PHPhotoLibrary.authorizationStatus(.addOnly)` | Returns `"authorized"` — Android API 29+ uses MediaStore, no explicit permission needed |
| `requestPhotosAddPermission()` | System prompt via `PHPhotoLibrary.requestAuthorization(.addOnly)` | Returns `"authorized"` immediately |

---

## 4. Calibration implementation

### `calibrateWhiteBalance()`

| | Android | iOS |
|---|---|---|
| Loop runs in | Dart (`cambrian_camera_controller.dart`) | Swift CameraEngine (single platform-channel call) |
| `initialGainR/G/B` params | Used to seed the first iteration | **Silently ignored** — engine starts from its own auto snapshot |
| Iterations | Up to 10, driven by `sampleCenterPatch` round-trips | Engine-internal; result carries `iterations` and `converged` fields |

### `calibrateBlackBalance()`

| | Android | iOS |
|---|---|---|
| Loop runs in | Dart | Swift CameraEngine |
| `params` argument | Used; non-black fields preserved across iterations | **Silently ignored** — engine owns the full `ProcessingParameters` state |

The method signatures and return types (`WbCalibrationResult`, `BbCalibrationResult`)
are identical. Callers should not rely on `initialGainR/G/B` or `params` having
any effect on iOS.

---

## 5. Camera lifecycle states

The `CameraState` enum contains all values on both platforms, but each value is
primarily driven by one platform:

| State | Primary platform | Trigger |
|---|---|---|
| `paused` | iOS | UIScene phase → `.inactive` or `.background` (camera gate closed, session still configured) |
| `suspended` | Android | `ProcessLifecycleOwner.onStop` (full `CameraDevice` close so other apps can use it) |
| `recovering` | Both | Non-fatal error; auto-retry with backoff |
| `streaming` | Both | Camera actively delivering frames |
| `error` | Both | Retries exhausted; terminal until camera becomes available |

Both platforms handle lifecycle **natively** — there is no Dart API to
pause/resume. Watch `stateStream` to show UI feedback.

---

## 6. `CameraCapabilities` texture-ID semantics

On **Android** the camera handle returned by `open()` happens to equal the
processed-stream Flutter texture ID (it is the `SurfaceProducer.id()`).

On **iOS** the handle and the texture IDs come from separate registries and are
not equal.

Always use `CameraCapabilities.streamTextureId` and
`CameraCapabilities.naturalStreamTextureId` for rendering — never the raw
handle.

---

## 7. What is identical

Every other aspect of the public Dart API behaves the same on both platforms:

- `open()`, `close()`, `setResolution()`, `updateSettings()`, `setProcessingParams()`
- `toneMappedTexture`, `rawTexture`, `stateStream`, `errorStream`,
  `frameResultStream`, `recordingStateStream`, `capabilitiesStream`
- `getPersistedProcessingParams()`, `sampleCenterPatch()`
- `CameraSettings` field semantics (ISO/exposure coupling, WB modes, crop, etc.)
- `ProcessingParams` ranges and pipeline order
- Auto-recovery behaviour (exponential backoff, `AvailabilityCallback` / scene-delegate escape hatch)
- Settings persistence across process kills
- `enableNaturalStream` / `rawStreamHeight` — both platforms provide a
  passthrough (unprocessed) lane alongside the tone-mapped lane
