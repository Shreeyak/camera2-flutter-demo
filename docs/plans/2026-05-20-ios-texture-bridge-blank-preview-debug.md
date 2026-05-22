# iOS texture-bridge blank-preview debug — starting point

**Date observed:** 2026-05-20, during Plan 3 (`phase-3-plan-3-ios-only-calibration`) on-device verification.
**Device:** Shreeyak's iPad, iOS 26.4.2, USB-tethered, Apple Development signing.
**Symptom:** Both Flutter preview `Texture` widgets render solid colors instead of camera frames despite the engine reporting an active streaming session.

This document captures what was observed, what was ruled out, and concrete next steps so future debugging can pick up without re-discovering the surface.

## Symptoms

- **Left lane (natural / passthrough)** — pure black, even when a bright phone flashlight is pointed directly at the rear camera.
- **Right lane (processed / GPU color pipeline)** — solid mid-grey; doesn't change with scene content.
- The example app's UI chrome (controls sidebar, bottom bar, calibrate buttons) renders normally.
- Tapping on the preview area has no effect on either lane.

## Engine-side evidence (frames ARE being produced)

`flutter run -d <iPad> --debug` log on the streaming-but-blank session:

```
flutter: Camera permission status (pre-request): authorized
flutter: Camera permission status (post-request): authorized
flutter: CC/Dart: opened handle=1 1600×1200
flutter: CC/Dart: setProcessingParams handle=1 ProcessingParams(black=[0.0,0.0,0.0] gamma=1.0 brightness=0.0 contrast=0.0 saturation=0.0)
flutter: CC/Dart: error=CamErrorCode.fpsDegraded fatal=false: 15.0 fps over 30-frame window
…repeats…
```

Key signal: **`fpsDegraded` is the engine's stall watchdog reporting a rolling 30-frame fps average**. It can only fire if frames have actually been delivered to the watchdog's measurement point. So frames *are* being produced by `AVCaptureSession`; they're either being rendered into a texture the Flutter `Texture` widget isn't subscribed to, or the texture's `copyPixelBuffer()` is returning `nil` and the widget falls back to its clear color.

Earlier in the session a different log sequence was seen suggesting a separate lifecycle bug:

```
state=CameraState.streaming
state=CameraState.paused
state=CameraState.error          ← unaccompanied by a CamErrorCode
state=CameraState.streaming
state=CameraState.paused
…
error=CamErrorCode.frameStall fatal=false: gpu: no frame in 3000ms
```

The `state=error` transition with no `onError` payload, followed by a recovery to streaming and then another pause, suggests the scene-phase observer or `.interrupted` lifecycle path on iOS 26 isn't behaving as designed. Spec §5.5 (Plan 2) added `.interrupted` as a distinct state from `.paused` — the Dart side may be misrouting one to the other. **This is independent of the blank-preview issue but lives in the same neighborhood.**

## Dart-side wiring confirmed correct

Ruling out the cheapest hypothesis first:

- `lib/main.dart:46-51` — `_kInitialSettings` sets `enableNaturalStream: true`. So the natural lane isn't disabled at the source.
- `lib/main.dart:1003` and `:1036` — both `Texture(textureId: t.textureId)` widgets are bound to live `CameraTextureInfo` values from the controller's streams. They aren't holding stale or default `0` IDs.

This means the bug, if there is one, lives in the Swift-side bridge/texture publish path, not in how the example app consumes textures.

## What's been tried (and what hasn't moved the needle)

1. **Restart the app** — same symptoms.
2. **Plug in via USB** (vs. wireless debug) — fixes the VM Service discovery but not the preview.
3. **Grant camera permission natively** (`AVCaptureDevice.requestAccess`, not `permission_handler`) — granted; preview still blank.
4. **Trust the developer certificate** in Settings → VPN & Device Management — done; doesn't affect preview.
5. **Wave a flashlight in front of the lens** — both lanes stay the same solid colors. Camera *isn't* just looking at darkness.
6. **Tap on each preview lane** — no effect (no tap-to-focus or wake gesture wired up).

## What hasn't been tried

These are the next discriminating experiments to run, in roughly increasing cost:

1. **Add a frame-arrival log to `CameraLaneBridge.swift`** — log each frame the bridge sees and each `textureFrameAvailable(:)` it dispatches to `FlutterTextureRegistry`. If the log fires, the issue is downstream of the bridge (texture registry / Flutter widget binding). If it never fires, the issue is upstream of the bridge (engine stream subscription).
2. **Call `engine.currentPixelBuffer(stream: .natural)` from the host API impl** and log whether it's `nil`. The accessor is `public nonisolated` (CameraKit/CameraEngine.swift §799) and reports whether the engine has a fresh frame to hand out.
3. **Check whether `CameraLaneTexture.copyPixelBuffer()` is being called at all by Flutter** — `FlutterTexture.copyPixelBuffer()` is the pull-side API; Flutter calls it after each `textureFrameAvailable(:)` notification. If `copyPixelBuffer()` is never called, the registry isn't dispatching. If it's called but returning `nil`, the bridge isn't holding a valid buffer.
4. **Compare against pre-Plan-2 baseline.** Plan 2's Cluster F introduced the per-lane texture bridge (commit `530ed3b feat(ios): Phase 3 Plan 2 Cluster F — per-lane texture bridge`). Check out that commit's parent and verify whether the single-lane preview worked there. If it did, the regression is in Cluster F.
5. **Inspect iOS 26 `AVCaptureSession.isInterrupted` behavior** — the system may emit interruptions more aggressively under Stage Manager / Split View; the example app may be running in a multi-window mode that triggers them. Single-window verification is essential.
6. **Watch `os_log` from CameraKit** — `CameraKitLog.notice/.debug` writes via `os.Logger`; open Console.app on the Mac, filter by subsystem `cambrian` (or whatever CameraKit uses), and look for warnings the Flutter-side `flutter:` log filter doesn't surface.

## Suspect files (in priority order)

- `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraLaneBridge.swift` — per-lane subscription + frame-publish wrapper.
- `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/CameraLaneTexture.swift` — `FlutterTexture` impl; pulls pixel buffers on demand.
- `packages/cambrian_camera/ios/cambrian_camera/Sources/cambrian_camera/FlutterApiPump.swift` — possibly misroutes the `.interrupted` state to `.paused` or vice versa (separate lifecycle bug; may not be related to blank preview).
- `packages/cambrian_camera/ios/cambrian_camera/CameraKit/Sources/CameraKit/CameraEngine.swift` — `currentPixelBuffer(stream:)` accessor; verify it returns non-nil during streaming.

## Reproduction

1. Check out `phase-3-plan-3-ios-only-calibration` (or any branch with Plan 2 merged into main).
2. Plug iPad in via USB, unlock it, trust the developer profile if needed.
3. `flutter run -d <iPad-device-id> --debug` from the repo root.
4. Grant camera permission when the system dialog appears.
5. Observe both preview lanes — natural (left) renders pure black, processed (right) renders solid mid-grey.
6. Confirm via Mac Console / `flutter run` output that `fpsDegraded` lines are firing — frames *are* being produced.

## Why this wasn't a Plan 3 issue

Plan 3's commit (`2de8e69 feat(plugin): Phase 3 Plan 3 — iOS calibration (fallback shape)`) touched:

- `pigeons/camera_api.dart` + Pigeon-generated outputs (Dart / Swift / Kotlin)
- `CameraHostApiImpl.swift` — added two calibration adapter methods, called engine snapshots after each calibration
- `CambrianCameraPlugin.kt` — two `not_implemented` stubs (Android)
- `cambrian_camera_controller.dart` — `Platform.isIOS` branch in two calibration methods

**Zero touches to texture-bridge code, GPU pipeline, AVCaptureSession setup, or frame-routing code.** The preview-rendering pipeline is wholly upstream of anything Plan 3 changed; no plausible mechanism by which Plan 3 broke it. The blank-preview issue is either pre-existing on `main` from Plan 2 (which Plan 2's verification on a previous iPad apparently didn't catch) or an iOS-26-specific lifecycle interaction triggered by the restart loops in our session.

## Loose ends to clean up alongside this fix

- The `state=error` transitions without an accompanying `onError` payload need root-causing — they suggest the lifecycle state machine has a transition path that emits `.error` without invoking the error callback. Either fix the omission or downgrade those transitions.
- Plan 4's spec §8.4 device matrix (cases 1–9) covers the basic open / preview / capture path; running it would have caught the blank preview before Plan 3 verification was attempted.

---

## Resolution (2026-05-22)

On-device re-investigation (Shreeyak's iPad, iOS 26.4.2) found this was **two
distinct bugs** stacked on top of each other. (Note: the example app's preview
layout has since changed — it now shows **processed on the left, raw/natural on
the right**; refer to lanes by name below, not by side.)

### Bug A — wrong texture id for the processed pane (FIXED in cam2fd)

The Dart `toneMappedTexture` getter rendered `textureId: _handle` (the camera
handle). That holds on **Android** (the handle *is* the processed
`SurfaceProducer.id()`), but **not on iOS** — there the engine `HandleRegistry`
handle and the Flutter texture-registry ids are unrelated, and the low handle
**collided with the natural texture's id**, so the "processed" pane actually
rendered the **natural** lane. That collision is also why earlier sessions saw
the natural image appear on the processed pane (masking Bug B).

**Fix:** added `previewTextureId` to the `CamCapabilities` contract (it already
carried `naturalStreamTextureId`; the processed id was simply never there).
iOS populates it from the real Flutter texture id (`state.previewTextureId`);
Android populates it explicitly (`= handle`) for contract uniformity; Dart
exposes it as `CameraCapabilities.streamTextureId` and `toneMappedTexture`
renders that. Engine untouched. This is the right model: a **session handle and
a render-surface id are different concepts** and Dart must not assume they're
equal. (Commit: `fix(ios): render processed lane on its own texture id`.)

The earlier "left lane pure black" symptom (2026-05-20) has since resolved — the
**natural lane now renders correctly** (verified: live preview + `captureNaturalPicture`
produces a correct image).

### Bug B — processed lane renders grey (cam2fd CONTRAST CONVENTION; engine exonerated)

> **Earlier drafts of this section were wrong.** They blamed the engine (first a
> Pass-7 shader bug, then a `TexturePoolManager` IOSurface-sharing bug). On-device
> probes (2026-05-22) disproved both. The engine is **not** at fault.

With Bug A fixed, the processed pane correctly targets the processed lane — and
still rendered **solid grey**. Device-log probes (`grey-probe` NSLog/debugPrint in
`CameraLaneBridge`, `CameraLaneTexture`, `lib/main.dart`, read via `idevicesyslog`)
showed the **delivery path is fully healthy**:

| Probe | Observed | Meaning |
|---|---|---|
| `bridge signal stream=processed id=1` | firing steadily | engine delivers `.processed` to cam2fd |
| `copyPixelBuffer stream=processed` | `bufferNil=false fmt=0x42475241` | Flutter pulls a **valid BGRA8** buffer |
| Dart `PROCESSED hasData=true id=1` | building `Texture(1)` | widget is fed |

So the buffer was valid BGRA8 the whole time — its **content** was grey. Root
cause: a **contrast convention mismatch**. The engine color shader
(`ColorShaders.metal`) computes `out = (in-0.5)*contrast + 0.5`, so **contrast
1.0 = identity** (like `gamma`). But cam2fd's `ProcessingParams` defaulted
`contrast = 0.0` (a normalized "[-1,1], 0 = identity" API matching brightness/
saturation) and passed it straight through `toCam()` **without translation** — so
the default reached the engine as zero-contrast → solid mid-grey on every startup.
(White-balance still read non-uniform values because it samples a pre-contrast
tap, which is why "frames are arriving" was true even while the preview was grey.)

**Fix (cam2fd Dart, not the engine):** translate at the serialization boundary —
`ProcessingParams.toCam()` adds `engineContrastIdentityOffset` (1.0); new
`ProcessingParams.fromCam()` subtracts it; `getPersistedProcessingParams` routes
through `fromCam`. Stale "piecewise sigmoid" docstring corrected to the engine's
linear math. Device-verified: processed pane shows the live scene at the default
slider position.

### Bug C — raw/natural lane stayed black (`0`-as-sentinel, cam2fd Dart)

`FlutterTextureRegistry.register()` assigns the first-registered lane id **`0`**
(a valid id — Flutter paints `Texture(0)` fine, confirmed by a now-present
`copyPixelBuffer stream=natural` probe). But `_rawTextureStream` guarded on
`naturalStreamTextureId != 0`, hiding the lane whenever it registered first. Fixed
by gating on intent (`_enableNaturalStream`) like the processed lane, plus
hardening `CameraCapabilities.empty()` to seed `noTextureId = -1`. Device-verified:
raw pane now renders.

### Net status (2026-05-22, all device-verified)

- Natural/raw lane: **works** (preview + still).
- Processed lane: **works** (preview + still); grey was the contrast default, now
  fixed.
- Engine (`eva-swift-stitch` / CameraKit): **exonerated** — no changes needed; the
  `PROCESSED_LANE_GREY_HANDOFF.md` handoff is moot.
- The `.interrupted`-mismapped-to-`.error` lifecycle loose-end was also fixed
  separately (added `CameraState.interrupted` to the Dart enum + `fromString`).
