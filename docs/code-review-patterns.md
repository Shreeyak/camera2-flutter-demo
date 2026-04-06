# Code Review Patterns — Recurring Mistakes

Patterns extracted from 130+ review comments across PRs #1–#13 (April 2026).
Ordered by combined severity and frequency. Use as a checklist during development
and code review.

```text
Severity × Frequency
       │
       ├── Tier 1 — Critical, fix before merge ──────────── Patterns 1–5
       │
       ├── Tier 2 — Major, systematic issues ─────────────── Patterns 6–10
       │
       ├── Tier 3 — Major, lower frequency ───────────────── Patterns 11–14
       │
       ├── Tier 4 — Medium ───────────────────────────────── Patterns 15–17
       │
       └── Tier 5 — Minor / housekeeping ─────────────────── Patterns 18–22
```

---

# Tier 1 — Critical, High Frequency

These are the patterns most likely to cause crashes, data corruption, or deadlocks.
They appear repeatedly across multiple PRs and must be checked on every change.

---

## 1. Thread Safety: Missing Synchronization on Shared Native State

**Severity:** Critical | **Frequency:** 12+ occurrences | **PRs:** #5, #6, #8, #11, #12, #13

The most pervasive issue in the codebase, appearing in three forms:

### 1a. Captured vs Field References in Posted Lambdas

A Kotlin method captures `gpuHandle` (or similar) into a local variable for a
null/zero guard, then the posted lambda uses the **original field** instead of
the captured snapshot. If `stop()` races with the posted work, the field may
already be 0 or point to freed native memory.

**Bad:**
```kotlin
fun rebindPreviewSurface(surface: Surface?) {
    val handle = gpuHandle          // captured for guard
    if (handle == 0L) return
    glHandler.post {
        nativeRebind(gpuHandle, surface)  // BUG: uses field, not capture
    }
}
```

**Good:**
```kotlin
fun rebindPreviewSurface(surface: Surface?) {
    val handle = gpuHandle
    if (handle == 0L) return
    glHandler.post {
        nativeRebind(handle, surface)     // uses captured snapshot
    }
}
```

**Rule:** Any native handle or shared resource referenced inside a `Handler.post {}`,
`Executor.execute {}`, or coroutine lambda **must** use the locally captured value,
never the class field.

### 1b. Missing Lock on JNI Calls That Race with Teardown

`SurfaceProducer` callbacks and `setProcessingParams()` call JNI functions using
`nativePipelinePtr` without holding `pipelineLock`. Teardown zeroes that pointer
and calls `nativeRelease` under the lock, so concurrent JNI calls can hit a
freed native pointer.

**Rule:** Every JNI call that reads `nativePipelinePtr` (or any native handle shared
with teardown) must be wrapped in `synchronized(pipelineLock) { ... }`, matching
how `nativeDeliverYuv` is already guarded. This includes `SurfaceProducer` callback
bodies and any `nativeSet*` call.

### 1c. Unsafe Thread Self-Join and Self-Removal

Two variants flagged in PRs #6 and #8:
- **Self-join deadlock:** `shutdownConsumer()` joins the consumer's `dispatchThread`.
  If `removeSink()` is called from within that thread's callback, the join deadlocks
  or terminates the process.
- **Self-removal use-after-free:** `removeSink()` from within a dispatch thread
  callback causes the owning `unique_ptr<Consumer>` to be destroyed while the thread
  is still running. Detaching doesn't fix it — the thread returns into a destroyed
  object.

**Rule:** Never destroy or join a thread-owning object from within that thread's
callback. Guard against self-join (compare thread IDs), and use deferred deletion
(shared_ptr prevent destroy, mark-for-removal + external cleanup, or post deletion
to a different thread).

---

## 2. Failure Callbacks Must Always Resolve

**Severity:** Critical | **Frequency:** 7 occurrences | **PRs:** #2, #6, #8, #9

When an async operation fails, the callback/Result is never invoked. The Dart side
hangs indefinitely. The second most impactful bug class after thread safety.

**Examples across PRs:**
- `nativeInit()` returns 0 → early return without calling `openCallback` (PRs #6, #8, #9)
- `GpuPipeline.start()` returns null surface → `cameraSurface!!` crashes (PR #9)
- Session continues configuring despite failed pipeline (PR #6)
- Failed `open()` leaves session registered in `sessions` map (PR #2)
- `getCapabilities()` fails → controller registered but never cleaned up (PR #2)
- Capability fields report requested raw-stream state, not actual (PR #9)

**Rule:** Every async operation that accepts a callback or returns a `Result` must
invoke that callback on **all** code paths — success, failure, and early return:
1. On failure, call `callback(Result.failure(...))` before returning.
2. Never force-unwrap (`!!`) after a fallible operation; check for null and fail
   gracefully.
3. State reported to Dart must reflect actual runtime state, not the requested
   configuration.
4. If a resource is registered (e.g., added to a map) before an async call, remove
   it in the failure path.

---

## 3. Parameter Contract Misalignment Across Layers

**Severity:** Critical | **Frequency:** 7 occurrences | **PRs:** #8, #9

When a parameter is added or its semantics change, the update doesn't propagate
through all layers (Dart → Pigeon → Kotlin → JNI → C++ struct → shader). This
causes **silent data corruption** because JNI positional arguments shift.

**Examples:**
- `contrast` added to Dart/Kotlin but missing from JNI bridge and C++
  `ProcessingParams` struct — `saturation` value silently read at wrong index
- `gamma` added to native `setAdjustments` but tests still call with old 6-arg
  signature (won't compile)
- `contrast`/`saturation` identity changed from `1.0` to `0.0` (multiplier →
  adjustment) but tests and docs still assume `1.0`
- `uvRowStride` passed as single value for both U and V planes, but YUV_420_888
  does not guarantee they match — corrupted chroma on I420

**Rule:** When adding or changing a parameter:
1. Trace the full call chain: Dart → Pigeon → Kotlin → JNI bridge → C++ function →
   struct/shader uniform. Update **every** layer.
2. If parameter semantics change (e.g., identity value, range), update all tests,
   docs, header comments, and validation logic.
3. For JNI positional parameters, verify the argument order matches at both the
   Kotlin `external fun` declaration and the C++ `JNI_FUNCTION` implementation.
4. Never assume two data planes share the same stride/format — pass separate values
   or add a validated assertion.

---

## 4. GPU/EGL State Must Be Accessed on the GL Thread

**Severity:** Critical | **Frequency:** 6 occurrences | **PRs:** #9, #12, #13

Methods that create, destroy, or bind EGL surfaces (`eglEncoderSurface_`,
`eglPreviewSurface_`, etc.) are called from the camera/background thread while
`drawAndReadback()` reads those same handles on the GL thread. No mutex or thread
marshalling protects the access.

**Rule:** All reads and writes to EGL surface handles must happen on the GL thread
(via `glHandler.post { ... }`). The codebase already does this correctly for
`rebindRawSurface` and `rebindPreviewSurface` — new methods must follow the same
pattern. If a method touches `eglEncoderSurface_`, `eglPreviewSurface_`, or
`eglContext_`, it must run on the GL thread.

### 4a. EGL Return Values Must Be Checked

`eglMakeCurrent` and `eglSwapBuffers` return values are ignored. If a surface
becomes invalid (background/foreground transition, Flutter surface recreation),
subsequent GL calls operate on an invalid target — silent black frames or crashes.

**Rule:** Always check the return value of `eglMakeCurrent` and `eglSwapBuffers`.
On failure, log via `eglGetError()` and skip the dependent blit/swap sequence.
Guard follow-up operations in an `if (success) { ... }` block.

**Checklist question:** *Does this code touch `gpuHandle`, any `egl*Surface_`, or
call a `nativeGpu*` function? If yes, it must execute on the GL thread, and EGL
calls must have their return values checked.*

---

## 5. Race Conditions in Async / Camera Flows

**Severity:** Critical–Major | **Frequency:** 5 occurrences | **PRs:** #2, #3, #4

Async operations interact with shared state without serialization, leading to
races that are hard to reproduce.

**Examples:**
- **`takePicture()` polls before JPEG is ready:** Posts a background task that
  calls `jpegReader.acquireNextImage()` immediately after `session.capture()` —
  returns null if the JPEG hasn't been written yet (PR #2)
- **Concurrent captures overwrite listener:** Two quick `takePicture()` calls
  overwrite `jpegReader.setOnImageAvailableListener()` on the same one-buffer
  reader, orphaning the first callback (PR #2)
- **`isCaptureInFlight` guard stuck:** Set to true before capture, but only cleared
  on the image callback and `CameraAccessException` — any other exception leaves
  the flag stuck, blocking all future captures (PR #3)
- **Callback window during capabilities fetch:** `_instances[handle]` is registered
  after `await api.getCapabilities(handle)` — any callback emitted during that
  window is dropped (PR #2)
- **Duplicate recovery scheduling:** `onOpened` wraps `startCaptureSession` in
  another `handleNonFatalError` — double-increments `retryCount` and queues
  overlapping reopen attempts (PR #2)

**Rule:**
- Use `OnImageAvailableListener` for async image results — never poll with
  `acquireNextImage()` immediately after capture.
- Serialize concurrent access to shared resources (JPEG reader, capture callbacks)
  with an in-flight guard or queue.
- In-flight guards must be cleared in `finally` blocks, not just happy-path callbacks.
- Register callback handlers *before* the operation that may trigger them.
- Don't wrap an error handler around a function that already handles its own errors.

---

# Tier 2 — Major, High Frequency

Systematic issues that appear across many PRs. Individually less severe than Tier 1,
but their aggregate cost is high because they waste review cycles and cause
compilation failures.

---

## 6. Documentation Drift from Implementation

**Severity:** Minor–Major | **Frequency:** 30+ occurrences | **PRs:** All 13

The single most frequent issue by raw count, appearing in **every PR reviewed**.

### 6a. Code-Level Docs (KDoc / Header Comments)

- KDoc references wrong property names (`persistentSurface` vs `inputSurface`)
- KDoc describes wrong data flow (Camera2 target vs GPU blit)
- Orphaned KDoc blocks not attached to any declaration
- Header comments with wrong identity values (multiplier vs adjustment offset)
- JNI doc comments missing new parameters
- Unused function parameters with stale docstrings
- NDK version comment references removed OpenCV dependency
- Constructor nullability contract says "must not be null" but `nullptr` is accepted
- `MetadataLayout` references `CONTROL_AF_STATE` for a frame number field
- Comment says "50ms debounce" but code does in-flight serialization
- Comment says "values preserved when AE is off" but update is unconditional

### 6b. Markdown Docs (Usage Guide, Architecture, Progress)

- Sample code that won't compile (discarded return values, wrong constructor args,
  bare `child:` at top level, non-existent methods, wrong static/instance calls)
- Version pinning mismatch (`permission_handler: ^11.3.1` vs `^12.0.1`)
- Error codes in docs don't match emitted codes
- `CameraState` enum includes `ready` but code doesn't have it
- minSdk listed as 21 but code sets 33
- RGBA-first description when code only does YUV
- Frame format says RGBA + ring buffer but code delivers BGR + mailbox
- Missing `rawTextureId` in capabilities table
- "Sensor raw" implies Bayer RAW, but it's pre-shader passthrough
- Architecture doc still uses `SurfaceTextureEntry`, code uses `SurfaceProducer`
- README references wrong file for logging flags

### 6c. Docs Ahead of Implementation

Docs describe APIs that don't exist yet. `addSink`/`removeSink` and
`frame.release()` documented as current when the native header marks them as
Phase 4 placeholders. Usage guide documents `supportsRgba8888` and guaranteed
native pipeline pointer as Phase 3 features. Flagged **5 times on a single PR**.

**Rule:**
1. The KDoc/docstring on the changed symbol
2. Any KDoc that *references* the changed symbol (search for the old name)
3. `docs/usage-guide.md` if the public Dart API changed
4. `docs/architecture.md` if the data flow or component relationships changed
5. All code samples in docs — verify they compile against the current API
6. Use precise terminology (e.g., "pre-shader passthrough" not "sensor raw")
7. Never document APIs that aren't implemented yet — mark them as "planned" or
   remove them until they ship

---

## 7. iOS Pigeon Codegen Not Regenerated After API Changes

**Severity:** Major | **Frequency:** 9 occurrences across 6 PRs | **PRs:** #2, #4, #6, #9, #12, #13

**The most persistent single bug in the codebase.** `PigeonError.details` cast as
`String?` instead of `Any?` has been flagged in **6 separate PRs**. Each time it
was "fixed," the next Pigeon regeneration reintroduced it.

Additionally, `FlutterError.message` is cast to non-nullable `String` in the
Kotlin generated code, but it's actually `String?` (PR #2).

**Consequences:**
- Missing parameters in the iOS protocol/handler
- Runtime crash on non-string error payloads
- Runtime crash on null error messages

**Rule:** After modifying `pigeons/camera_api.dart`, always regenerate **both**
platform outputs:
```bash
dart run pigeon --input pigeons/camera_api.dart
```
Then verify:
- Generated Swift: `PigeonError.details` remains `Any?`, not `String?`
- Generated Kotlin: `FlutterError.message` remains `String?`, not `String`
- Both platforms have matching parameter lists

---

## 8. Incomplete Resource Cleanup on Failure Paths

**Severity:** Major | **Frequency:** 8+ occurrences | **PRs:** #2, #7, #12, #13

The happy path acquires resources but exception/failure paths don't release them.

### 8a. Kotlin/Android Resources

- Pending MediaStore entries (`IS_PENDING=1`) left as ghost files
- Open file descriptors leaked
- Unreleased MediaMuxer/MediaCodec instances
- `close()` only cleans up after awaiting platform close — if that throws, stream
  controllers and serializer are never disposed (PR #2)
- Failed `open()` leaves SurfaceProducer/CameraController pair unreachable in
  `sessions` map (PR #2)

**Rule:** Any method that acquires multiple resources must use `try/finally` or a
rollback block to release them on failure.

**Related:** `stop()` must not release `MediaCodec`/`MediaMuxer` while the drain
thread may still be running. Call `drainThread.join()` after `quitSafely()` before
releasing shared resources.

### 8b. C++ / JNI Resource Leaks

`nativeInit()` acquires an `ANativeWindow*` via JNI, then constructs
`ImagePipeline`. If the constructor throws, the window leaks. (PR #7)

**Rule:** In C++ JNI functions, wrap resource-acquiring constructors in try/catch
and release JNI resources (e.g., `ANativeWindow_release`) on failure. Prefer RAII
wrappers or smart pointers.

---

## 9. Tests Not Updated After Signature or Semantic Changes

**Severity:** Major | **Frequency:** 8 occurrences | **PRs:** #8, #9, #13

When a function signature or parameter semantics change, existing tests are not
updated, causing compilation failures or incorrect assertions.

**Examples:**
- `GpuPipeline` constructor gained `Context` param → test instantiations won't compile
- `nativeGpuSetAdjustments` gained `gamma` → test calls with 6 args instead of 7
- `setAdjustments` verify calls use old arg count in `never()` matcher
- `contrast`/`saturation` identity changed from `1.0` to `0.0` → wrong assertions
- `ProcessingParams` validation now rejects values like `1.5` → test data out of range
- Mock declared as local in `setUp()` → test method can't reference it
- `FontFeature` used without import → compilation error
- Widget text changed but test expectations not updated

**Rule:**
- After changing any function signature, grep for all call sites **including tests**.
- After changing default values or valid ranges, search for the old values in
  test assertions.
- Run `flutter test` and `./gradlew test` before pushing.
- Mocks shared across test methods must be class-level fields, not `setUp()` locals.
- If a test depends on `Handler`/`Looper` execution, use Robolectric or inject
  synchronous dispatchers.

---

## 10. Missing Input Validation and Edge-Case Guards

**Severity:** Medium–Major | **Frequency:** 7 occurrences | **PRs:** #1, #2, #3

Code assumes inputs are always well-formed or within expected ranges.

**Examples:**
- `CameraDialConfig` assumes `stops.length >= 2` — divides by `(stopCount - 1)`,
  crashes with 0 or 1 stops (PR #1)
- Shutter formatter does `1.0 / secs` with no guard for `secs <= 0` — renders
  `Infinity` (PR #1)
- `ProcessingParams._validate()` checks `isNaN` but doc says "must be finite" —
  `double.infinity` passes (PR #3)
- Default `CameraSettingsValues` has `exposureTimeNs = 250000` but valid range
  starts at `1000000` — UI disagrees with dial on startup (PR #1)
- `SinkFrame.release` callback is uninitialized — calling it throws
  `std::bad_function_call` (PR #2)

**Rule:**
- Add `assert` or throw `ArgumentError` in constructors for invariants (e.g.,
  `assert(stops.length >= 2)`).
- Guard division and formatting against zero/negative inputs.
- Use `isFinite` not `isNaN` when you need to reject both NaN and infinity.
- Default values must be within the valid ranges they'll be used with.
- Initialize all `std::function` members with a no-op default.

---

# Tier 3 — Major, Lower Frequency

Important issues that appeared in fewer PRs but still need attention.

---

## 11. Optimistic UI State Without Backend Confirmation

**Severity:** Major | **Frequency:** 4 occurrences | **PRs:** #2, #4

The UI optimistically updates state before the native side confirms the transition.

**Examples:**
- Auto-toggle UI added for ISO/shutter but `_onAutoToggleTap` doesn't update
  `isoAuto`/`exposureAuto` flags — button appears but does nothing (PR #2)
- Manual-mode handler flips `_values.isoAuto = false` before native has AE seed —
  UI stuck in manual while camera runs auto-exposure (PR #4)
- `identical(next, _values)` always false because `copyWith` creates a new instance
  — `setState` called on every frame even when nothing changed (PR #4)
- Using cached `lastKnownIso` instead of current frame values — stale numbers (PR #4)

**Rule:**
- Don't flip UI state until the backend confirms the transition (or revert on
  rejection/`SETTINGS_CONFLICT`).
- Compare actual field values for equality, not object identity.
- Use current-frame values for display; keep cached values only for seeding logic.

---

## 12. Lifecycle Callbacks Not Wired for All Surfaces

**Severity:** Major | **Frequency:** 3 occurrences | **PRs:** #8, #9, #11

When Flutter recreates a `SurfaceProducer` surface, the `onSurfaceAvailable`
callback resizes the producer but never tells the GPU pipeline to rebind the new
`ANativeWindow`. The processed preview was wired correctly; the raw preview was not.

**Rule:** When adding a new surface/stream path:
1. Wire **both** `onSurfaceAvailable` and `onSurfaceCleanup` callbacks to the GPU
   pipeline rebind methods.
2. Mirror the wiring pattern of the existing processed-preview callback.
3. Ensure state reported to Dart reflects actual runtime state.

---

## 13. Breaking Public API Changes Without Deprecation

**Severity:** Major | **Frequency:** 2 occurrences | **PRs:** #7, #8

Public getters renamed or removed without a deprecation period. In PR #8 the `id`
getter was renamed to `processedStreamTextureId`; in PR #7 the reverse happened.

**Rule:** When renaming or removing a public API symbol:
1. Keep the old name as a `@Deprecated('Use newName instead')` alias.
2. Remove the deprecated alias only in a major version bump.

---

## 14. State Not Persisted Across Pipeline Recreation

**Severity:** Major | **Frequency:** 1 occurrence | **PRs:** #6

`setProcessingParams()` forwards settings to the current native pipeline. When the
pipeline is destroyed and recreated (e.g., after a camera error), the new instance
starts with defaults. User settings silently reset.

**Rule:** Cache the last-applied state in a Kotlin field. After creating or
recreating the native pipeline, replay the cached state immediately.

---

# Tier 4 — Medium Severity

Issues that cause incorrect behavior but aren't crashes or data corruption.

---

## 15. Dart Type Mismatches from `clamp()` and Kotlin Float/Double

**Severity:** Medium | **Frequency:** 4 occurrences | **PRs:** #4

Dart's `int.clamp()` and `double.clamp()` return `num`, not the original type.
Assigning the result directly to a typed field fails under strong mode.

**Rule:** Always cast `clamp()` results back to the expected type (`.toInt()`,
`as double`). In Kotlin, use `2.0f` for Float arithmetic or explicitly call
`.toDouble()` when assigning to a `Double?` field.

---

## 16. Hardcoded Layout and Hardware Assumptions

**Severity:** Medium | **Frequency:** 4 occurrences | **PRs:** #1, #5

- Dial positioning uses constant `_kDialMaxWidth` but widget may be narrower →
  button goes off-screen (flagged in both PRs #1 and #5)
- `formatShutterNs()` rounds sub-second exposure → `800ms` displays as `1/1`
- Focus range fallback synthesizes `10.0` diopters for fixed-focus devices
- Magic constant defined in two places — risks drift

**Rule:**
- Use actual measured widget dimensions, not constants that duplicate a constraint.
- Formatting helpers must preserve precision for live sensor values.
- Never fabricate hardware values — disable the UI control instead.
- Define shared constants in one place.

---

## 17. Brittle String Wire Formats Across Platform Channels

**Severity:** Medium | **Frequency:** 3 occurrences | **PRs:** #12, #13

`startRecording()` returns a pipe-delimited string (`"uri|filename"`) that the
Dart side parses with `split('|')`. Filenames can legally contain `|`.

**Rule:** Use Pigeon's structured types for platform channel return values. If a
method returns more than one value, define a Pigeon data class. Never invent
custom string serialization formats.

---

# Tier 5 — Minor / Housekeeping

Low-severity issues that should be fixed opportunistically.

---

## 18. Unnecessary Work When No Consumers Are Attached

**Severity:** Minor | **Frequency:** 3 occurrences | **PRs:** #6, #9

`deliverFullResRgba()`, `deliverTrackerRgba()`, and the raw preview path allocate
and copy frames before checking whether any consumers are subscribed.

**Rule:** Check whether the consumer vector is empty **before** allocating or
copying frame data.

---

## 19. Machine-Specific Paths Committed to Repository

**Severity:** Minor | **Frequency:** 2 occurrences | **PRs:** #12, #13

`.clangd` committed with absolute paths like `/Users/shrek/Library/Android/sdk/...`.

**Rule:** `.gitignore` local tooling config or use relative paths / env variables.

---

## 20. Wildcard Imports

**Severity:** Minor | **Frequency:** 1 occurrence | **PRs:** #9

**Rule (per CLAUDE.md):**
- **Dart:** Always use `show`/`hide`
- **Kotlin/Java:** No `import x.y.*`

---

## 21. Missing C++ Header Includes

**Severity:** Minor | **Frequency:** 1 occurrence | **PRs:** #7

`cambrian_camera_native.h` uses `std::string` without `#include <string>`.

**Rule:** Every header must include everything it directly uses.

---

## 22. Undocumented Platform Restrictions

**Severity:** Minor | **Frequency:** 1 occurrence | **PRs:** #6

NDK ABI restricted to `arm64-v8a` with no explanation or documentation.

**Rule:** Document platform restrictions with rationale. Provide a clear error
message for unsupported configs.

---

# Quick-Reference Checklist

Before submitting a PR, verify:

**Tier 1 — Critical (block merge if violated):**
- [ ] All `Handler.post {}` lambdas use captured local variables, not class fields
- [ ] All JNI calls on shared native handles are wrapped in `synchronized(pipelineLock)`
- [ ] No thread self-join or self-removal that deadlocks or destroys the owning object
- [ ] Every async callback/Result is invoked on all code paths (success, failure, early return)
- [ ] No force-unwrap (`!!`) after fallible operations
- [ ] New/changed parameters propagate through all layers: Dart → Pigeon → Kotlin → JNI → C++ → shader
- [ ] All EGL/native GPU calls are marshalled to the GL thread
- [ ] EGL calls (`eglMakeCurrent`, `eglSwapBuffers`) have return values checked
- [ ] Async results use listeners/callbacks, not immediate polling
- [ ] In-flight guards cleared in `finally` blocks, not just happy-path callbacks
- [ ] Callback handlers registered *before* the operation that triggers them

**Tier 2 — Major (fix before PR approval):**
- [ ] KDoc/docstrings match current function signatures and data flow
- [ ] Code samples in docs compile against the current API
- [ ] Docs don't describe unimplemented APIs as available
- [ ] `dart run pigeon` re-run after `camera_api.dart` changes (both iOS and Android)
- [ ] `PigeonError.details` remains `Any?` in generated Swift (not `String?`)
- [ ] `FlutterError.message` remains `String?` in generated Kotlin (not `String`)
- [ ] Failure paths clean up every resource acquired (Kotlin + C++)
- [ ] C++ JNI functions use try/catch + RAII for acquired resources
- [ ] Tests updated for any signature or semantic changes (grep for old call sites)
- [ ] `flutter test` and `./gradlew test` pass
- [ ] Constructor invariants enforced with `assert` or `ArgumentError`
- [ ] Default values are within valid ranges
- [ ] State cached and replayed after pipeline recreation

**Tier 3–4 — Medium (fix in same PR if touched):**
- [ ] UI state changes confirmed by backend before being shown to user
- [ ] All surface types have `onSurfaceAvailable`/`onSurfaceCleanup` wired
- [ ] Renamed/removed public symbols have `@Deprecated` aliases
- [ ] `clamp()` results cast back to expected types
- [ ] No fabricated hardware values — disable UI for unsupported capabilities
- [ ] Platform channel methods use structured Pigeon types, not string parsing

**Tier 5 — Minor (fix opportunistically):**
- [ ] Consumer-empty fast-paths before expensive allocations/copies
- [ ] No absolute/machine-specific paths in committed config files
- [ ] No wildcard imports (Dart: use `show`/`hide`; Kotlin: no `import x.y.*`)
- [ ] C++ headers include everything they directly use
- [ ] Platform/ABI restrictions documented with rationale
