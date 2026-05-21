# DECISIONS.md

Append-only stigmergy log. Subagents add one-line entries for decisions or assumptions they don't want to litigate in return text. Coordinator doesn't re-read this file during a stage; the next subagent glances at it before its task.

Format:
```
YYYY-MM-DD [stage-NN task-M] agent-id — one-line decision or assumption
```

Compaction: at stage boundaries, fold entries into `state.md`'s "Decisions taken that weren't in briefs" section, then truncate below the stage separator.

---

## Stage 02 (complete — folded into state.md §Decisions)

No subagent entries this stage; coordinator worked inline.

---

## Stage 08 (complete)

35. **Dual-dispatch yield() chosen over full C++ routing (Stage 08).** Brief D-01 says
    "Swift-side subscribe() is a facade over the same C++ pool." Full C++ routing would
    require reassembling a FrameSet (Swift multi-buffer struct) from per-stream surface
    pointer + metadata in a C-ABI callback — this loses capture/processing metadata
    fidelity and requires a parallel C++ metadata channel. Dual-dispatch (Swift AsyncStream
    subscribers use their existing path; C++ pool consumers are dispatched separately from
    yield()) satisfies all TESTABLE tests including 08:swift-subscribe-is-facade-over-cpp-pool
    (observable equivalence: both paths receive the same frame numbers in order).

36. **CannyStubConsumer uses real OpenCV Canny (Stage 08).** OpenCV v4.13 xcframework
    available at ~/software/opencv2.framework. Converted from versioned macOS-style framework
    to flat iOS-style xcframework (lipo arm64-thin + xcodebuild -create-xcframework).
    CannyStubConsumer.cpp runs cv::Canny with thresholds 50/150 on each tracker frame;
    edge pixel count stored in 64-entry ring buffer per ADR-29.
    HITL 08:external-canny-stub-runs-on-device is PENDING device run.

37. **InteropError.notWired removed; invalidCallbacks is the new guard (Stage 08).**
    notWired existed only as a scaffolding error. Real registerCallback validates both
    onFrame (required per D-03) and onOverwrite and throws invalidCallbacks for nil values.
    Stage06Tests updated accordingly.

38. **ADR-13 C++ interop containment not achievable with current Swift semantics (Stage 08).**
    Swift propagates .interoperabilityMode(.Cxx) transitively to every importer regardless
    of whether C++ types appear in the public API. CameraKit, eva-swift-stitch app, and
    eva-swift-stitchTests all required -cxx-interoperability-mode=default added to
    OTHER_SWIFT_FLAGS. Flag for upstream ADR-13 revision.

---

## Stage 08

2026-04-23 [stage-08 hitl] coordinator — CannyStubConsumer extended to handle kCVPixelFormatType_64RGBAHalf (tracker pool format): CV_16FC4 → CV_32FC4 → cvtColor(RGBA2GRAY) → CV_8UC1 → Canny. Previous else-branch returned 0 for all tracker frames.
2026-04-23 [stage-08 hitl] coordinator — CppCannyStub wired to tracker stream in ViewModel.start() (DEBUG only); edge count read from ring buffer and displayed as text in debug overlay every 10 natural frames.

2026-05-08 [stage-09 bugfix] coordinator — fpsDegradedThresholdFps (fixed 15.0 floor) replaced by fpsDegradedFraction=0.8: threshold = expectedFps×0.8, where expectedFps=min(1e9/exposureNs, targetFps) in manual mode and targetFps in auto mode. Long exposure times are intentional; the 15fps hardcoded floor wrongly fired on valid 13fps delivery from a 75ms shutter setting.

2026-05-14 [stage-11 followup] coordinator — Gap 1 (recording start/stop failures invisible to UI): routed RecordingViewModel's caught errors through ErrorPresenterViewModel.present(_:) → top toast, NOT the plan's suggested bottom-banner (ViewModel.captureResult) pattern. Rationale: single error surface, unified with engine errorStream() failures. RecordingViewModel.init now takes errorPresenter:; ViewModel.init creates `errors` before `recording` to wire it.

2026-05-14 [stage-11 followup] coordinator — Unified error surface (per user): captureImage() failures now route to ErrorPresenterViewModel.present(_:) → top toast too, matching recording failures. `ViewModel.captureResult: Result<StillCaptureOutput,Error>?` narrowed+renamed to `captureConfirmation: StillCaptureOutput?` (success-only) — the `.failure` case is dead. captureBanner is now a success-only green confirmation; the red "Capture failed" bottom banner is gone (errors are top toasts only).

2026-05-14 [stage-11 followup] coordinator — Capture-success confirmation moved from bottom safeAreaInset to a top toast (`captureToast`, green checkmark), stacked in a VStack with `errorToast` under one `.overlay(alignment:.top)`. Kept structurally separate from the error toast per user: own state (`captureConfirmation`), own styling — NOT folded into ErrorPresenterViewModel (which is CameraError-typed). Bottom-edge stack is now expandedBar + bottomBar only. Removed dead `ViewModel.error: EngineError?` (write-only field superseded by ErrorPresenterViewModel).

---

## Migration Phase 1A (Flutter migration — UI decoupling)

2026-05-15 [migration-1a task-1] coordinator — CameraEngine.setGate(_:), drainSubmittedFrame(), dumpDeviceFormats() promoted to public. Required by the relocated ViewModel.swift (cross-module). Per spec §2e these are harness-only debug surface (no Pigeon counterpart). Surface curation (demoting other helpers to internal) is gated on Phase 2's calibration move-down and stays deferred.

2026-05-15 [migration-1a task-3] coordinator — CameraKitInterop temporarily exported as a SwiftPM library product so the relocated DisplayViewModel can import CppCannyStub for the DEBUG Canny edge-count overlay. Bridge state; Phase 1B removes the consumer and un-exports. Alternatives rejected: #if DEBUG-stub (regresses overlay between 1A/1B) and 1B-first ordering.

2026-05-15 [migration-1a task-6] coordinator — OrientationLock.swift moved to app target (file #11), not foreseen by the plan-of-record which kept it in package. The file imports SwiftUI for `UIInterfaceOrientationMask` (a UIKit type SwiftUI re-exports). To satisfy the plan's "zero SwiftUI imports in the package" exit gate without weakening Phase 1A's contract, OrientationLock relocates to the app target alongside the SwiftUI files, and its `import SwiftUI` is corrected to `import UIKit` on move. Sole consumer is `eva_swift_stitchApp.swift` (already in app target). User-selected via AskUserQuestion 2026-05-15.

2026-05-15 [migration-1a task-6] coordinator — CameraSettings.merging(onto:) promoted to public alongside the three CameraEngine helpers. Not foreseen by the plan-of-record but caught by the cross-module access audit during Task 6: relocated `HardwareControlsViewModel.swift:47` calls `delta.merging(onto: self.currentSettings)` and would not compile with the method `internal`. CameraSettings is already public; only the extension method needed promotion.

2026-05-15 [migration-1a task-7] coordinator — Stage11Tests.swift split rather than wholesale-relocated (spec §1A said "moves to the app-target test location"). 4 of 9 suites test CameraKit internals (MetalPipeline.*ForTest, SettingsPersistence, Constants.blackBalanceOverscan, MetalError) via @testable import CameraKit and have zero UI refs — they stay dual-membered in CameraKit/Tests/CameraKitTests/Stage11Tests.swift. 5 UI suites + CalibrationEngineStub + ManagedAtomicSafe move to eva-swift-stitchTests/Stage11UITests.swift (single-target — deliberate CLAUDE.md §8 exception). Total test count unchanged: 35 (20 UI + 15 internals). The split itself used sed line-range deletion/extraction rather than the plan's literal `Write` replacement, which had paraphrased the kept suites and would have stripped their inline `//` rationale comments. Per user direction (keep rationale comments).

2026-05-15 [migration-1a task-7] coordinator — CameraKitCxx now explicitly links CoreFoundation (`.linkedFramework("CoreFoundation")`). CannyStubConsumer.cpp references `_kCFAllocatorDefault`. Pre-Phase-1A the app target got CoreFoundation transitively via UIKit and the package test target never linked CameraKitCxx directly, so the gap was latent. Once CameraKitInterop became a direct dependency of `eva-swift-stitchTests` (Task 4 plan addition), the test target's link surfaced the gap as undefined symbols. Alternative considered: remove `CameraKitInterop` from the test target's dependencies (it isn't imported by any test file). Rejected because making CameraKitCxx self-contained for any consumer is the more durable fix.

---

## Migration Phase 1B (Flutter migration — OpenCV consumer decoupling)

2026-05-15 [migration-1b task-1] coordinator — `CannyStubConsumer : public PixelSink` inheritance dropped on relocation. The C-ABI thunk `canny_stub_on_frame` was the only caller of the virtual `onFrame(PixelFrame)`; the inheritance was structurally dead. Dropping it removed the `PixelSink.hpp` / `PixelFrame` header dependency from `CannyConsumer.cpp`, which is what made the relocation a true byte-move with no header search path back into the package needed for that file (`CounterConsumer.cpp` still needs one for `<PixelSinkCallbacks.h>`). Done as a separate in-place refactor commit prior to the move so a regression there would be bisectable.

2026-05-15 [migration-1b task-5] coordinator — `CppCannyStub.makeCallbacks()` dropped on relocation. Grep over the entire repo (sources + tests + app) showed zero callers — the only hit was a comment string in `Stage08Tests.swift`. The Phase 1A version of the class also exposed the lower-level `onFrameCallback()` + `nativeContext` getters; every actual callsite used those, never `makeCallbacks()`.

2026-05-15 [migration-1b task-5] coordinator — `CppCannyStub` Logger category changed from `"interop"` to `"appcxx"` on relocation. The class is no longer in `CameraKitInterop`; tagging its log lines `appcxx` makes them distinguishable from the package's interop logs (`CppPixelSinkPool`, `CppCaptureAtomic`) in Console.app. Subsystem `com.cambrian.camerakit` preserved.

2026-05-15 [migration-1b task-6] coordinator — `SWIFT_OBJC_BRIDGING_HEADER` set on BOTH the app target and the test target (not just the app, as the spec implied). C symbols exposed via the bridging header on a Swift app target are NOT automatically visible to a test target through `@testable import` — each target compiles its Swift independently and resolves the bridging header per-target. `Stage08CannyTests` (`CppCannyStub`) and `CABIParityTests` (`counter_consumer_*`) both call into the AppCxx C-ABI from the test target, so the test target needs the same bridging header. Plan-of-record corrected during execution.

2026-05-15 [migration-1b task-7] coordinator — `opencv2.xcframework` linked + embed-signed on the app target before removal from the package (split across two commits). Linking first guarantees the app self-contains its OpenCV linkage before we sever the package's binary-target reference; if anything had gone wrong with the xcframework copy/sign, the failure would surface at the link-and-embed step, not at the cleanup step. Alternative considered: drop the package's binary target first, then link app-side. Rejected — would have produced a build-broken intermediate state for an entire commit boundary.

2026-05-15 [migration-1b task-8] coordinator — `CameraKitInterop` SwiftPM product **stays exported** (reversing the Phase 1A memo's prediction). Reasoning: the dual-membered `Stage08Tests.stillCaptureUsesCppAtomic` imports `CppCaptureAtomic` from `CameraKitInterop`; un-exporting would break that test in the Xcode test target. The app target dropped its `CameraKitInterop` dep (DisplayViewModel no longer imports the package's interop after `CppCannyStub` relocated); the test target keeps the dep. CLAUDE.md §8 dual-membership default stays intact. Two acceptable alternatives existed: (a) keep product, drop only app-target dep (chosen); (b) untie the atomic test from dual-membership. (a) is less surgery; chose (a).

2026-05-15 [migration-1b task-10] coordinator — C-ABI parity probe (`CounterConsumer` + `CABIParityTests`) added. The C-ABI path (`pixel_sink_pool_register` against `engine.getNativePipelineHandle()`) is exactly what Phase 3's Flutter plugin native code will use; previously the package's only exercise of that path was through `CppPixelSinkPool.register`, the Swift-wrapped pass-through, not the raw C call from foreign code. The probe is a small C++ consumer (no OpenCV, no image processing) registered via the raw C-ABI plus a Swift test asserting identical frame sequences vs. a `registerCallback`-registered consumer. 2 tests, 0 failures.

2026-05-15 [migration-1b task-11] coordinator — `canny_stub_*` C-ABI declarations removed from `CameraKitCxx/include/PixelSinkCallbacks.h`. The header retains a one-line breadcrumb pointing readers to `eva-swift-stitch/AppCxx/include/CannyConsumer.h` for the relocated declarations. `CameraKit/Package.swift` drops the `opencv2` `binaryTarget` and the `"opencv2"` entry from `CameraKitCxx`'s `dependencies`. Package's CoreFoundation linkage stays (added in Phase 1A; harmless after the move).

2026-05-15 [migration-1b task-12] coordinator — HITL verified the relocated path on iPad via `mcp__XcodeBuildMCP__build_run_device` and `scripts/device-log-live.sh`. The log shows: `registerCallback: stream=2 token=1 cppCount=1` immediately after `engine.open()` (the Swift-API path), then 50+ seconds of `yield: frame=N stream=2 surface=true cppConsumers=1` across frames 0 → 1500 with zero overwrites or Swift drops in any `[metrics] window emit`. Evidence file: `measurements/phase-1b/canny-overlay.md`. The CannyStub `os_log` lines themselves don't appear in `camerakit.log` (they go through `os_log()` not CameraKitLog); the `cppConsumers=1` + `surface=true` invariant is the indirect proof that `canny_stub_on_frame` is being invoked end-to-end.

2026-05-15 [migration-2 D-2P-01] coordinator — `CameraSettings.focusDistance` and `FrameResult.focusDistance` are NOT renamed to `focusDistanceDiopters` to match the Pigeon contract. iOS `AVCaptureDevice.lensPosition` is normalized to `[0.0, 1.0]`, NOT real diopters; the contract name is semantically wrong on iOS (pinning the field to "diopters" would mislead native CameraKit consumers reading the value). Phase-3's Pigeon adapter does the rename when bridging to the Flutter side. Logged per Phase-2 spec §2a working principle: "Anything ambiguous → surfaced to the user for a decision, not decided unilaterally."

2026-05-15 [migration-2 D-2P-02] coordinator — `CalibrationResult` matches the Pigeon `CamCalibrationResult` shape verbatim (`before: RgbSample`, `after: RgbSample`, `converged: Bool`, `iterations: Int`). For the Phase-2 single-shot iOS algorithm, `converged = true` and `iterations = 1` always — semantically correct (single-shot trivially converges in one pass). The future iterative Dart-port (per `docs/superpowers/plans/2026-05-15-wb-calibration-dart-port.md`) populates the fields meaningfully without a contract bump. Alternatives rejected: (a) lean `{before, after}` only — would force a contract change later; (b) Void return + frame-result-stream — would force Phase 3's adapter to synthesize the result.

2026-05-15 [migration-2 D-2P-03] coordinator — `CalibrationViewModel` partially reverses Stage-11 ADR-21 decomposition for WB/BB orchestration only. Engine now owns `calibrateWhiteBalance()`/`calibrateBlackBalance()` (the multi-step sample → compute → apply → resample sequence); VM is a thin caller. Other Stage-11 ADR-21 VM responsibilities (HardwareControls, Display, Recording, Processing, ErrorPresenter) are unchanged. Rationale per spec §2b: orchestration is camera-control logic, the contract expects it engine-side, Phase-3's Pigeon adapter needs it there, and it unlocks shrinking the public surface (11 helper methods demoted to internal). The shrunk `CalibrationEngineProtocol` is now 4 methods (was 11) — the test stub's surface area dropped commensurately.

2026-05-15 [migration-2 D-2P-04] coordinator — Phase-2 `SessionState.interrupted` covers `.otherInterruption` (Control Center, Split View / Stage Manager, phone call) only. `.cameraInUseBegan` (videoDeviceInUseByAnotherClient) keeps its existing route to `.error` + Stage-9 self-heal — Stage 9's recovery loop and tests depend on this routing. A future stage may reconcile if the Flutter contract needs unified treatment. The new `[interruption] entering .interrupted` log line fires only on AVF's `wasInterruptedNotification`; SwiftUI ScenePhase pauses (Control Center pull-down on iPad) route through D-2P-07 below.

2026-05-15 [migration-2 D-2P-05] coordinator — Calibration concurrency contract — `internal var calibrationTask: Task<CalibrationResult, Error>?` flag on the engine actor. Conflict guards: `updateSettings()` throws `EngineError.calibrationInProgress` when the flag is set AND the settings touch any WB field (mode/gainR/gainG/gainB); `setResolution()` throws unconditionally when the flag is set (it would invalidate the pipeline reference the calibration holds). Abort-on-lifecycle: `close()` and the `.otherInterruption` route call `calibrationTask?.cancel()`; the task's catch path restores `wbMode = .auto` via `_updateSettingsBypassingCalibrationGuard(_:)` before propagating `CancellationError`. The WB-restore is best-effort (`try?`) so a teardown can't itself throw.

2026-05-15 [migration-2 D-2P-06] coordinator — Permission helpers are `nonisolated static` on `CameraEngine` (not instance methods). Rationale: the Flutter side needs to query (and prompt) for camera + Photos add-only authorization BEFORE instantiating an engine handle, which today calls `AVCaptureDevice.requestAccess(for: .video)` inside `open()`. Static methods don't require the actor; pre-`open()` callers can use them without lifecycle gymnastics. Mirrors `Photos`/`AVFoundation`'s own static-class-method shape.

2026-05-15 [migration-2 D-2P-07] coordinator — SwiftUI ScenePhase pause routes to `SessionState.paused`/`.streaming` via the new `engine.notifyScenePhasePaused(_:)`. Distinct from Phase-2 §2d.5 `.interrupted` (which is reserved for AVF's `wasInterruptedNotification`). Mid-implementation user feedback drove this addition: the existing scenePhase handler closed the GPU submission gate but left `SessionState` at `.streaming`, leaving any `stateStream()` consumer (Phase-3 Pigeon adapter, ErrorPresenterVM) blind to the visible pause. Reuses the existing `.paused` enum case rather than overloading `.interrupted`. The handler now publishes `.paused` on `.inactive`/`.background` and `.streaming` on `.active`. Verified on device: `[scenePhase] state=.paused` / `state=.streaming` log lines fire at the gate transitions.

2026-05-15 [migration-2 §2c streamPixelFormat semantics] coordinator — `SessionCapabilities.streamPixelFormat` value changed from `"420f"` → `"RGBA16F"`. The previous value reported the camera *source* format (YUV 420f, what AVF delivers in the sample buffer), but downstream consumers — including Phase-3's zero-copy texture bridge — care about the *lane buffer* format (what `currentPixelBuffer(stream:)` returns). CameraKit converts YUV→RGBA16F in MetalPipeline's Pass-1; the lane buffers are `kCVPixelFormatType_64RGBAHalf` IOSurface-backed, MTLPixelFormat.rgba16Float. RGBA16F is `CVMetalTextureCacheCreateTextureFromImage`-compatible (CameraKit itself uses the cache with this format in `TexturePoolManager.makeIOSurfaceBackedRGBA16F`), so Phase-3's bridge stays zero-copy — but it must wrap as `.rgba16Float`, not the BGRA the spec's §2d.7 mentioned as the safe-default. Updated the Phase-3 handoff implication: the bridge wraps RGBA16F directly; no per-frame CPU copy needed.

## 2026-05-15 — Error routing rule documented (#6)

Documented the long-standing sync-throw vs. async-stream routing contract
in the `Errors.swift` header. Sync rejections at the command boundary →
typed `EngineError` throw. Async hardware / session / encoding failures →
`CameraError` on `errorStream()`. `EngineError.fatal(CameraError)` is the
bridge. No code change; this codifies what existing throw / emit sites
already do. Post-Stage-12 hardening per
`docs/superpowers/specs/2026-05-15-post-stage-12-hardening-design.md`.

## 2026-05-15 — Engine-authoritative SessionState (#3 + #5 + #11)

CameraEngine now stores its own SessionState via SessionStateMachine
and is the authoritative source. ViewModel holds a downstream
@Observable mirror updated from stateStream() — used for SwiftUI
invalidation, not as the canonical answer. Synchronous truth is
available to actor-isolated callers via the state machine.

The prior stored `isOpen: Bool` is removed; `isOpen` is now a computed
property (`stateMachine.current != .closed`). sessionToken is unchanged
and remains the identity mechanism for watchdog / D-10 race detection
— different concern from lifecycle, explicitly not folded in.

Every publishState site classifies its trigger as `.command` (host /
engine-self) or `.event` (OS-initiated via onSessionEvent or the
RecoveryCoordinator hook). The classifier consults an
expected-transition map that distinguishes the two kinds; off-map
transitions log + DEBUG-assert + apply (observability-first). The
state machine is a diagnostic instrument: a `paused → recovering` log
correlated with a preceding OS notification is the legitimate
interruption-plus-runtime-error overlap; the same log with no
preceding event is the watchdog-race bug the retrospective predicted.

Stage13Phase2InterruptedStateTests was updated to call
`_markOpenForTest()` before posting `.otherInterruption` — the prior
test bypassed normal lifecycle and would now trip a `.closed →
.interrupted (event)` off-map assertion (AVF only fires interruption
notifications against a running session). The seam itself was
adjusted to drive state without emitting on the state stream, matching
the original `isOpen = true` semantics.

`commandMap` was widened during plan execution to include `.closed →
.paused` after the device build surfaced an off-map assertion on every
app launch: SwiftUI scenePhase fires `.background`/`.inactive` before
`engine.open()` resolves, and `ViewModel.handleScenePhase` calls
`engine.notifyScenePhasePaused(true)` unconditionally. D-2P-07 makes
that pre-open publish intentional (Phase-3 Pigeon adapter and
ErrorPresenter rely on the pause being visible on `stateStream`), so
the table accommodates the transition rather than gating the publish
or silencing the assertion. User-selected via AskUserQuestion
2026-05-15 from three options: widen map (chosen) vs. gate publish
vs. drop DEBUG assertionFailure.

Post-Stage-12 hardening per
docs/superpowers/specs/2026-05-15-post-stage-12-hardening-design.md.

2026-05-15 [migration-2 D-2P-08] coordinator — Calibration host methods adopt Option C: iOS-only Pigeon `@HostApi` declarations, no Android Dart→Kotlin move-down. Amends `docs/superpowers/specs/2026-05-14-camerakit-flutter-migration-design.md` §2d.8 (which originally scoped Phase 3 to move Android's calibration loop from `cambrian_camera_controller.dart` into `CameraController.kt`). Rationale: cross-platform symmetry was a design preference, not a forcing function; Pigeon supports per-platform `@HostApi` method availability; Android's existing Dart calibration loop is working production code that shouldn't be touched without a feature reason. Phase 3's iOS plugin declares + implements `calibrateWhiteBalance` / `calibrateBlackBalance` (routing to the Phase-2 `engine.calibrateWhiteBalance()` / `calibrateBlackBalance()` methods); Android plugin does NOT declare them; the Android Dart caller continues to own the loop unchanged. Engine-divergence (Android: processed-lane sampling + green-pivot math in Dart; iOS: natural-lane sampling + `grayWorldGains` engine-side) is now permanent, not transitional. Pigeon contract asymmetry — methods exist on iOS only — is acceptable; mirrors the existing iOS-specific contract additions (permission helpers, `interrupted` SessionState, photos PHAsset return shape).

2026-05-15 [migration-2 D-2P-09] coordinator — RGBA16F → RGBA8 lane-conversion design Open Q #1 resolved: BGRA8 (`kCVPixelFormatType_32BGRA`) on iOS, Android adds a one-byte-swizzle. iOS stays Metal-cache-canonical (`.bgra8Unorm` zero-copy wrap); Android's `GpuRenderer.cpp` adds a channel-reorder at the eglSwapBuffers boundary (output-channel swizzle in the fragment shader, or `glReadPixels(GL_BGRA, ...)`) to match iOS's wire format byte-for-byte. "Identical outputs" is strict byte-identical, achieved by Android adapting to iOS's canonical pair. Documented in `docs/superpowers/specs/2026-05-15-rgba16f-to-rgba8-conversion-design.md` Open Q #1 (resolved). Phase-3 plan that touches `cambrian_camera/android/` carries this Android-side change.

2026-05-15 [migration-2 D-2P-10] coordinator — `captureNaturalPicture` does NOT use `AVCapturePhotoOutput`. Implementation taps the existing natural lane via `currentPixelBuffer(stream: .natural)` (Phase-2 accessor) and JPEG-encodes the buffer using the existing `StillCapture` encode helper (refactored to accept any `CVPixelBuffer` source). No new `AVCaptureOutput` attached to the session, no new delegate type, no `CaptureAtomic` integration. Rationale: the contract method's purpose is "capture the unprocessed image," not "capture from `AVCapturePhotoOutput` specifically." CameraKit already produces the natural lane as a continuous IOSurface-backed stream; reading the latest frame and encoding it satisfies the contract with ~50 lines of new code instead of a second capture pipeline. RAW/HEIF/DNG/Live Photo/depth-data deferred. Documented in `docs/superpowers/specs/2026-05-15-capture-natural-picture-design.md`.

2026-05-15 [migration-2 D-2P-11] coordinator — Pre-Phase-3 RGBA8 lane-conversion design Open Q's #2–#6 resolved: default-on flag (`OpenConfiguration.lanesEightBit = true`); Option B placement (per-lane Pass-7 bridge tap, RGBA16F end-to-end internally — texture mailboxes `latestNaturalTex` / `latestProcessedTex` / `latestTrackerTex` stay `.rgba16Float`; buffer mailboxes `latestNaturalBuffer` / `latestProcessedBuffer` route to BGRA8 when on); tracker lane does not convert (no Phase-3 Pigeon counterpart, saves one Metal pass/frame); `SessionCapabilities.streamPixelFormat` kept as a single string field with extended semantics (`"BGRA8"` default / `"RGBA16F"` opt-out); per-feature test naming (`RgbaConversionTests.swift`, no stage prefix); harness stays on the new default (no opt-out call site in `eva-swift-stitch/UI/ViewModel.swift`). Texture/buffer asymmetry is the design's load-bearing claim — documented inline on every accessor's doc-comment; future readers must not refactor it away. Parallel `MetalPipeline.latestNaturalBufferRGBA16F` mailbox added so `captureNaturalPicture` preserves HDR-grade precision regardless of the flag — `StillCapture.encode`'s vImage RGBA16F → 8-bit path expects half-float input. HITL on iPad 2026-05-15: 30 fps sustained at 4K with conversion on (0 fps-degraded windows, 0 mailbox-overwrite events across ~2 min); still-capture visually unchanged (architectural: Pass-6 blit + still pool + vImage path is structurally independent of Pass-7); MTKView preview unchanged (texture path untouched). Edge-noise flicker observed in both flag states + Apple's built-in Camera app — camera sensor noise, not the conversion pass. Documented in `docs/superpowers/plans/2026-05-15-rgba16f-to-rgba8-conversion.md` and `measurements/phase-3-prep/rgba8-conversion.md`.

2026-05-20 [migration-2 D-2P-12] coordinator — 8-bit BGRA end-to-end delivery. BGRA8 (`kCVPixelFormatType_32BGRA` / `.bgra8Unorm`) is now the *single* delivery format for every CameraKit consumer (Flutter bridge, native Metal preview, C++ tracker, still capture) and every surface type (`CVPixelBuffer` *and* `MTLTexture`); RGBA16F survives only as an internal Metal-compute intermediate (Pass-1 YUV→RGB, Pass-2 color, Pass-4 tracker downsample, Pass-5 NV12, Pass-7 convert) plus WB/BB calibration sampling — the camera is hard-locked to 8-bit, so float precision buys nothing at the boundary. Per-lane strategy: natural/processed convert via the standalone `rgba16fToBgra8` Pass-7; tracker is *fused* (its pool is BGRA8, so Pass-4 writes 8-bit directly — no extra pass, no shader edit). Each lane exposes one IOSurface as both `currentPixelBuffer(stream:)` and `.bgra8Unorm` `currentTexture()`/`currentProcessedTexture()`/`currentTrackerTexture()`. Removed: the `OpenConfiguration.lanesEightBit` flag (conversion unconditional); the texture(16F)/buffer(8-bit) asymmetry that D-2P-11 declared load-bearing; the parallel `latestNaturalBufferRGBA16F` still mailbox; the entire Pass-6 GPU-readback still pipeline (`makeStillCapturePool`, `armCapture`, the pending-capture continuation) and `StillCapture`'s vImage `convertRGBA16FtoRGBA8`. Still capture now reads the latest BGRA8 lane buffer directly (`captureImage` → processed, `captureNaturalPicture` → natural) and `StillCapture.encode` builds the CGImage with BGRA byte order (`byteOrder32Little | noneSkipFirst`). The internal 16F texture mailboxes are renamed `_latestNaturalTex16F` / `_latestProcessedTex16F` for clarity; the app dev-harness MTKView switches `colorPixelFormat` to `.bgra8Unorm` so the preview blit matches. Supersedes D-2P-11 (the asymmetry it protected is intentionally deleted); retains D-2P-09 (BGRA8 as the cross-platform wire format) and D-2P-10 (no `AVCapturePhotoOutput`). Documented in `docs/superpowers/specs/2026-05-20-8bit-bgra-end-to-end-delivery-design.md` and `docs/superpowers/plans/2026-05-20-8bit-bgra-end-to-end-delivery.md`.
2026-05-20 [P2a true-crop] swift-core — P2a true crop — output resolution = crop region size; removed Stage-04 black-out masking; overrides state.md #67 (which recommended dropping setCropRegion / Option B). Crop = a sub-region resolution change: pipeline recreated on setCropRegion (no AVF reconfigure), even-coords enforced for 4:2:0 chroma. Merged onto migration-2 D-2P-12 (8-bit BGRA): natural/processed/8-bit pools, Pass-7 convert, and seedPreviewMailboxes all size to outputSize; seeding populates the renamed `_latest*Tex16F` / `_latest*Bgra8Tex` / `_latest*Buffer` mailboxes.

<!-- new entries go above this line; keep the stage header last -->
