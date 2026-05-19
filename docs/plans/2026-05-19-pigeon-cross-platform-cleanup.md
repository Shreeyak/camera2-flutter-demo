# Plan stub — Pigeon contract cross-platform cleanup

**Status:** queued, not started. Surfaced 2026-05-19 during Plan 2 (Phase 3) wrap.

**When to do:** after Plan 4 (HITL + device-test harness) lands. The device-test
harness is a prerequisite — every rename / wire-shape change needs end-to-end
verification on both iOS and Android before merge, not just "iOS build green."

## Background

Plan 2's `PigeonValueMapping` (iOS side) revealed several places where
`pigeons/camera_api.dart` encodes Android's Camera2 hardware shape on the wire,
forcing iOS to silent-drop fields, hardcode values, or stuff non-equivalent
quantities into misleadingly-named fields. Plan 2 shipped because the lies are
small and well-localized at the conversion site, but they will compound across
Dart UI code over time.

Plan 3 introduces `pigeons/camera_api_ios.dart` for iOS-only calibration, setting
the precedent for per-platform Pigeon files. This cleanup mirrors that pattern
in the other direction and clarifies the cross-platform subset.

## Scope (Tiers 1–3, ~half-day plan when done together)

**Tier 1 — Doc annotations**
- Add platform-coverage annotation to every cross-platform Pigeon field:
  ```dart
  /// ...
  /// Platform: Android only — iOS ignores (no AVFoundation equivalent).
  int? noiseReductionMode;
  ```
- Touches `pigeons/camera_api.dart` only. Regenerate via `scripts/regenerate_pigeon.sh`.

**Tier 2 — Relocate Android-only fields**
- Create `pigeons/camera_api_android.dart` (mirror of Plan 3's iOS file).
- Move from `CamSettings`:
  - `noiseReductionMode: Int64?`
  - `edgeMode: Int64?`
  - `enableNaturalStream: Bool?`
  - `naturalStreamHeight: Int64?`
- Move from `CamPhotosDestination`:
  - `albumName: String?` (iOS-only; relocate to `pigeons/camera_api_ios.dart`)
- Trim `CamErrorCode` to platform-neutral cases. Drop:
  - `cameraService`, `cameraDisabled`, `maxCamerasInUse`, `previewSurfaceLost`,
    `pipelineError` (or relocate to Android-only enum if Dart UI needs them).
- Dart-side controller branches on `Platform.isAndroid` for the new
  `CameraAndroidHostApi` (parallel to Plan 3's `Platform.isIOS` branch).

**Tier 3 — Fix misleading names + types**
- `CamSettings.focusDistanceDiopters: Double?` → `CamSettings.focusDistance: Double?`
  - iOS impl stops stuffing normalized lensPosition into a "Diopters"-suffixed
    field. UI code uses `CamCapabilities.focusMin/focusMax` for the range; the
    unit is platform-opaque.
- `CamSettings.iso: Int64?` → `CamSettings.iso: Double?`
  - Matches `AVCaptureDevice.iso: Float` native type; no information loss on
    Android (whole-number ISO still fits).
- `CamFrameResult.focusDistanceDiopters: Double?` → `focusDistance: Double?` (parallel rename).
- `CamFrameResult.iso: Int64?` → `Double?`.
- Document `wbGainR/G/B` per-platform scale in field doc.
- Collapse `CamCapabilities` width/height redundancy. Today there are 6 fields:
  `streamWidth/Height`, `sensorStreamWidth/Height`, `naturalStreamWidth/Height`.
  Logical concepts are 2:
  - `captureWidth/Height` (sensor stream — what the camera actually outputs)
  - `outputWidth/Height` (post-GPU-crop dims — what the texture surfaces show)
  Drop `naturalStream*` (natural is always-on at full sensor on both platforms).

## Out of scope for this plan (deferred to a separate Plan 6)

**EV-bias redesign** — replace `evCompensation: Int64?` +
`evCompensationStep: Double` with continuous `exposureBiasEV: Double?` +
`evBiasMin/Max: Double` + `evBiasGranularity: Double` on capabilities. This
changes UI slider semantics on both platforms and warrants its own brainstorm.
See Plan 2 wrap-up notes for the full reasoning.

## Risks

- **Wire-breaking:** every Tier 2/3 change touches Dart consumers
  (`cambrian_camera_controller.dart`, any UI code reading these fields, any
  `SharedPreferences`-persisted state). Coordinate with the camera-UI flow
  in `lib/` before merging.
- **Test coverage gap:** Plan 4's device-test harness is the safety net for
  this plan. Without it, regressions are caught only by manual smoke. Do not
  start this plan before that harness ships.
- **CameraKit (engine) ignorance:** the engine has no opinion on these wire
  fields — all conversions live in `PigeonValueMapping.swift` (iOS) and the
  Android equivalent. The cleanup is plugin-layer-only on both platforms; the
  CameraKit subtree is untouched.

## Prerequisites

- Plan 3 merged (per-platform Pigeon split precedent established).
- Plan 4 merged (device-test harness available for verification).

## Suggested commit shape (~5 commits)

1. `feat(pigeon): Plan 5 Tier 1 — platform-coverage doc annotations`
2. `feat(pigeon): Plan 5 Tier 2 — extract Android-only fields to camera_api_android.dart`
3. `refactor(pigeon): Plan 5 Tier 3 — rename focusDistanceDiopters → focusDistance`
4. `refactor(pigeon): Plan 5 Tier 3 — iso Int64 → Double; capabilities width/height collapse`
5. `chore(pigeon): Plan 5 Tier 3 — trim Android-only CamErrorCode cases`
