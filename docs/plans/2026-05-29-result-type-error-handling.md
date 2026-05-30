# Plan: Result type error handling for public API

**Status:** queued

## Problem

The `CambrianCamera` public API uses three inconsistent error patterns:

| Pattern | Methods | Problem |
|---|---|---|
| `throw PlatformException` | `open()`, `captureImage()`, `startRecording()` | Callers must know to try/catch — easy to ignore |
| `Future<void>` fire-and-forget | `updateSettings()`, `setProcessingParams()` | Failures silently swallowed; error reaches `errorStream` only as a side-channel |
| `errorStream` broadcast | fps degraded, session lost, fatal errors | Correct — runtime events genuinely have no call site |

`updateSettings()` is the most dangerous: the camera can silently reject a settings change and the UI gets no signal unless it happens to be subscribed to `errorStream`.

## Fix

Define a `Result<T>` sealed class in `packages/cambrian_camera/lib/src/result.dart`:

```dart
sealed class Result<T> {}
final class Success<T> extends Result<T> { final T value; ... }
final class Failure<T> extends Result<T> { final Exception exception; final StackTrace stackTrace; ... }
```

Convert the three request-failure methods to return `Result<T>`:

| Method | Before | After |
|---|---|---|
| `open()` | `Future<CambrianCamera>` (throws) | `Future<Result<CambrianCamera>>` |
| `updateSettings()` | `Future<void>` (silent) | `Future<Result<void>>` |
| `captureImage()` | `Future<CamCaptureResult>` (throws) | `Future<Result<CamCaptureResult>>` |

Leave `errorStream` unchanged — it handles async runtime events correctly.

## Scope

- `packages/cambrian_camera/lib/src/result.dart` — new file, `Result` sealed class
- `packages/cambrian_camera/lib/src/cambrian_camera_controller.dart` — update the three method signatures
- `lib/main.dart` — update example app call sites to switch on `Result`
- `docs/usage-guide.md` — update public API examples

## Out of scope

- `setProcessingParams()`, `startRecording()`, `stopRecording()`, `calibrate*()` — lower priority, can follow in a second pass
- `errorStream` — keep as-is

## Risk

Wire-breaking: all callers of `open()`, `updateSettings()`, and `captureImage()` must be updated. In this repo the only caller is `lib/main.dart`. External consumers would need a deprecation path if the package were published.
