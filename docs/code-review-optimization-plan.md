# Code Review: cambrian_camera Plugin — Optimization Plan

## Context

We're reviewing the `cambrian_camera` Flutter plugin (Phase 3: Camera2 + minimal C++ identity pipeline) for simplicity, clean interface, and integration-readiness. The plugin wraps Android Camera2 via Kotlin + C++ JNI and will be consumed by multiple apps. Phase 4 (C++ post-processing) is deliberately deferred.

Goals: KISS, DRY, clean interface readable by LLM coding agents, portable across devices.

---

## Priority 1 — Plugin Fixes (the reusable library)

### 1A. Fix background thread leak in `close()` — BUG

**File:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt`

`close()` (line 342) calls `teardown()` but `teardown()` (line 893) does NOT call `backgroundThread.quitSafely()`. Only `release()` (line 567) quits the thread. The plugin's `CambrianCameraPlugin.close()` calls `controller.close()`, never `release()` — so every user-initiated close leaks a `HandlerThread`.

**Fix:** Move `backgroundThread.quitSafely()` into `teardown()`. Then simplify `release()` to just call `teardown()`.

### 1B. Make `resolveStreamFormat` query the device dynamically

**File:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CameraController.kt`

Line 702-703 returns hardcoded `Triple(ImageFormat.YUV_420_888, 4160, 3120)`. Replace with a function that queries `StreamConfigurationMap.getOutputSizes(YUV_420_888)` and picks the largest size, falling back to 1920x1080.

### 1C. Propagate stream resolution to Dart for correct preview aspect ratio

**Files:**
- `packages/cambrian_camera/pigeons/camera_api.dart` — add `streamWidth`, `streamHeight` to `CamCapabilities`
- Regenerate Pigeon (`dart run pigeon --input pigeons/camera_api.dart`)
- `packages/cambrian_camera/android/.../CameraController.kt` — populate from resolved stream format
- `packages/cambrian_camera/lib/src/camera_state.dart` — add fields to `CameraCapabilities`
- `packages/cambrian_camera/lib/src/cambrian_camera_preview.dart` — use `streamWidth`/`streamHeight` instead of `supportedSizes.first`

**Why:** Preview currently uses JPEG sizes for aspect ratio (line 58-63 of preview widget), but actual stream may differ.

**Depends on:** 1B

### 1D. Create central plugin configuration object

**New file:** `packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/CambrianCameraConfig.kt`

Currently, logging flags (`VERBOSE_SETTINGS`, `VERBOSE_DIAGNOSTICS`) are buried in `CameraController.kt`'s companion object. All plugin-level configuration should live in a single visible config object so values are easy to find and change during development.

**Fix:** Create a `CambrianCameraConfig` object with:
- `verboseSettings: Boolean = true` (keep on during development)
- `verboseDiagnostics: Boolean = true` (keep on during development)
- Future config values (e.g., max retries, backoff delays) can be added here

Update `CameraController.kt` to reference `CambrianCameraConfig.verboseSettings` etc. instead of local `const val`.

### 1E. Fix `CameraSettings.copyWith` — can't reset fields to null

**File:** `packages/cambrian_camera/lib/src/camera_settings.dart` lines 57-79

`copyWith(iso: null)` is indistinguishable from "not specified" because `iso ?? this.iso` swallows it. Use a private sentinel object so consumers can reset to auto: `settings.copyWith(iso: null)`.

### 1F. Add mutex to ImagePipeline for thread safety

**Files:** `packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.h` and `.cpp`

`previewWindow_` is accessed from `setPreviewWindow()` (UI thread) and `processFrame()` (camera thread) with no synchronization. Add `std::mutex mutex_` and lock in both methods.

### 1G. Move `ANativeWindow_setBuffersGeometry` out of per-frame path

**File:** `packages/cambrian_camera/android/src/main/cpp/src/ImagePipeline.cpp` line 61

Cache `lastWidth_`/`lastHeight_` and only call `setBuffersGeometry` when dimensions change. Reset in `setPreviewWindow()`.

**Depends on:** 1F (shares the mutex)

---

## Priority 2 — Demo App Cleanup

### 2A. Extract shared shutter speed formatter (DRY)

`camera_settings_bar.dart:127` and `camera_dial_presets.dart:101` both format shutter speed identically. Extract to `lib/camera/camera_format_utils.dart`.

### 2B. Replace `List<int>` ranges with named fields

**File:** `lib/camera/camera_settings_values.dart`

`CameraRanges.isoRange` is `List<int>` accessed via `[0]`/`[1]`. Replace with `isoMin`/`isoMax`, `exposureTimeMinNs`/`exposureTimeMaxNs`. Also rename `minFocusDiopters` to `focusMaxDiopters` (it's the max diopter = closest focus).

Update usages in: `main.dart`, `camera_dial_presets.dart`, `camera_settings_values.dart`.

### 2C. Wire ISO/shutter auto-toggle button

**File:** `lib/main.dart`

The auto-toggle button renders for ISO and shutter but `_onAutoToggleTap` has no case for them. Wire it: toggling sets `isoAuto`/`exposureAuto` to true, and `_isAutoMode` returns those values.

### 2D. Add comment explaining dual preview layout

**File:** `lib/main.dart` lines 229-234

Add a comment: the two side-by-side previews demonstrate the future dual-consumer architecture (full-res + low-res).

### 2E. Replace magic numbers in auto-toggle positioning

**File:** `lib/main.dart` line 257-259

`left: (MediaQuery.of(context).size.width / 2) - 400 / 2 - 60` hardcodes dial width and offset. Extract named constants or use layout-relative positioning.

### 2F. Use exhaustive Dart 3 switch patterns

**File:** `lib/main.dart`

Convert `_hasAutoMode`, `_isAutoMode`, `_onAutoToggleTap` from `switch/case/default` to expression-based exhaustive switches. Catches missing cases at compile time.

### 2G. Remove unused `CameraSettingType.af` enum value

**File:** `lib/camera/camera_settings_values.dart`

Clarification: AF *functionality* works correctly — the focus chip's auto-toggle button handles AF on/off. The issue is that `CameraSettingType.af` as an *enum value* is never used to create a chip, dial, or any UI element. It only appears in fallthrough/default cases of switch statements. Since AF toggling is handled by the focus chip's auto-toggle, this enum value is redundant dead code.

Remove the `af` enum value and update switch statements in `camera_control_overlay.dart` and `main.dart` to remove the dead cases.

### 2H. Remove duplicate `wb` case in overlay switch

**File:** `lib/widgets/camera_control_overlay.dart` line 72-74

Clarification: WB *functionality* works correctly via the `_WbControlPanel` at the top of the `build()` method (line 30). The issue is that the switch statement below it *also* has a `case CameraSettingType.wb:` (line 72-74) that can never execute because the wb guard clause already returned. This is just dead code in the switch — not a functional issue.

Remove the unreachable duplicate case.

---

## Priority 3 — Documentation

### 3A. Document `_instances` and `_FlutterApiDispatcher` lifecycle

Add doc comments explaining the static map cleanup contract and per-isolate FlutterApi registration.

### 3B. Comment `minSdk = 33` reasoning

**File:** `packages/cambrian_camera/android/build.gradle.kts`

Add comment explaining: targets OPD2403 hardware running API 33+. Single-device target for now.

---

## Execution Order

**Batch 1 — Plugin core fixes:**
1. **1A** — thread leak bug fix (critical)
2. **1B** — dynamic resolution
3. **1C** — stream dimensions to Dart (depends on 1B, requires Pigeon regen)
4. **1D** — central plugin config object
5. **1F + 1G** — C++ thread safety + geometry optimization
6. **1E** — copyWith null reset

**>>> Test + commit here before proceeding <<<**

**Batch 2 — Demo app cleanup:**
7. **2A** — shared shutter formatter
8. **2C + 2F + 2G + 2H** — auto toggle fix + exhaustive switches + dead code removal (all touch same switch blocks)
9. **2B** — typed ranges (touches many files, do after switches)

**>>> Test + commit here before proceeding. Verify in UI: settings sliders, auto-toggle buttons, preview aspect ratio <<<**

**Batch 3 — Polish:**
10. **2D + 2E** — dual preview comment + magic numbers
11. **3A + 3B** — documentation

## Verification

After all changes:
1. `flutter analyze` — no warnings
2. `flutter test` in `packages/cambrian_camera/` — serializer tests pass
3. `flutter build apk` — NDK build succeeds (verifies C++ changes)
4. Deploy to device — camera opens, preview renders, settings sliders work, auto-toggle buttons are functional
5. Close camera — verify no logcat warnings about leaked threads
