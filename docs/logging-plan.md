# Logging Plan: Camera Plugin Revised Logging

## Problem

Current logging covers only 3A capture-result snapshots (every 60 frames, gated behind
`verboseDiagnostics`). Three important areas produce zero structured logs:

1. **Camera lifecycle** — state machine transitions (OPENING → STREAMING → RECOVERING → ERROR)
2. **Settings application** — what CaptureRequest was actually built and sent
3. **Dart layer** — open/close lifecycle, state/error receipt

## Design

### Log tag

All logs use tag `"CambrianCamera"`. Filter in logcat with:

```bash
adb logcat -s CambrianCamera
```

### Three tiers

| Tier | When fires | Log level | Gate |
|------|-----------|-----------|------|
| 0 — Lifecycle | On event | `Log.i` | Unconditional |
| 1 — 3A state change | When AE/AF/AWB enum changes | `Log.i` | Unconditional |
| 2 — Heartbeat | Every 30 results (~1 Hz) | `Log.d` | `verboseDiagnostics` |
| — Full result dump | Same period as heartbeat | `Log.d` | `verboseFullResult` (separate flag) |

---

## Tier 0 — Lifecycle events

**Camera state transitions** (unconditional, fired from `setState()`):

```
I CambrianCamera  [CAM] CLOSED → OPENING
I CambrianCamera  [CAM] opening  device=default
I CambrianCamera  [CAM] OPENING → STREAMING
I CambrianCamera  [CAM] streaming  fmt=YUV_420_888 1280×960
I CambrianCamera  [CAM] STREAMING → RECOVERING
I CambrianCamera  [CAM] recovering  error=cameraDisconnected  retry=1/5  backoff=500ms
I CambrianCamera  [CAM] RECOVERING → STREAMING
I CambrianCamera  [CAM] STREAMING → CLOSED
I CambrianCamera  [CAM] RECOVERING → ERROR  code=permissionDenied  fatal=true
```

**Settings applied** (unconditional, fired after each `setRepeatingRequest`):

```
I CambrianCamera  [SETTINGS] iso=manual:800  exp=manual:33ms  focus=auto  wb=auto  zoom=1.0×
I CambrianCamera  [SETTINGS] focus=manual:0.250D
I CambrianCamera  [SETTINGS] wb=locked
```

Only non-null fields are included. Fields that were not changed in the update call are omitted.

**Dart layer** (unconditional `debugPrint`):

```
[CAM] open  handle=1  1280×960  iso=100–8200
[CAM] close  handle=1
[CAM state] streaming
[CAM error] cameraDisconnected  fatal=false: Camera disconnected unexpectedly
```

---

## Tier 1 — 3A state-change events

Fires unconditionally whenever the AE, AF, or AWB state enum changes. Tracks previous state in
`lastAeState`, `lastAfState`, `lastAwbState` class fields (all `@Volatile Int? = null`).

```
I CambrianCamera  [AE] null → SEARCHING  iso=null  exp=null
I CambrianCamera  [AE] SEARCHING → CONVERGED  iso=864  exp=33ms
I CambrianCamera  [AE] CONVERGED → LOCKED  iso=864  exp=33ms

I CambrianCamera  [AF] null → INACTIVE  focus=null
I CambrianCamera  [AF] INACTIVE → PASSIVE_SCAN  focus=null
I CambrianCamera  [AF] PASSIVE_SCAN → PASSIVE_FOCUSED  focus=0.24D
I CambrianCamera  [AF] PASSIVE_FOCUSED → FOCUSED  focus=0.24D

I CambrianCamera  [AWB] null → SEARCHING  wb=null
I CambrianCamera  [AWB] SEARCHING → CONVERGED  wb=[R:1.82 Ge:1.00 Go:0.99 B:1.45]
I CambrianCamera  [AWB] CONVERGED → LOCKED  wb=[R:1.82 Ge:1.00 Go:0.99 B:1.45]
```

State name mapping:

| AE | AF | AWB |
|----|----|-----|
| INACTIVE | INACTIVE | INACTIVE |
| SEARCHING | PASSIVE_SCAN | SEARCHING |
| CONVERGED | PASSIVE_FOCUSED | CONVERGED |
| LOCKED | ACTIVE_SCAN | LOCKED |
| FLASH_REQ | FOCUSED | |
| PRECAPTURE | NOT_FOCUSED | |
| | PASSIVE_UNFOCUSED | |

---

## Tier 2 — Periodic heartbeat

Fires every 30 capture results (~1 Hz at 30 fps). Gated by `CambrianCameraConfig.verboseDiagnostics`.

**Structured summary** (easy to watch live):

```
D CambrianCamera  [3A #30] fps=29.8  ae=CONVERGED iso=864 exp=33ms  af=PASSIVE_FOCUSED focus=0.24D  awb=CONVERGED  drops=0
D CambrianCamera  [3A #60] fps=29.8  ae=CONVERGED iso=912 exp=28ms  af=PASSIVE_FOCUSED focus=0.24D  awb=CONVERGED  drops=0
```

Fields:
- `fps` — derived from `SENSOR_FRAME_DURATION` (hardware-reported, not wall-clock)
- `drops` — `max(0, 30 - (streamFrameCount - lastHeartbeatFrameCount))`, detects ImageReader frame drops
- `iso`, `exp` — actual sensor values from the capture result
- `focus` — `LENS_FOCUS_DISTANCE` (reported regardless of AF locked state — for heartbeat display only)

**Full result dump** (for investigating unexpected field values):

Gated by a **separate** flag `CambrianCameraConfig.verboseFullResult` (not `verboseDiagnostics`),
so it can be enabled independently without enabling the full diagnostic output:

```
D CambrianCamera  [FULL #30] TotalCaptureResult{CONTROL_AE_STATE=2, CONTROL_AF_STATE=2, ...}
```

This is `TotalCaptureResult.toString()` — all keys including `SENSOR_NOISE_PROFILE`,
`STATISTICS_LENS_SHADING_MAP`, `TONEMAP_CURVE`, etc. Useful when debugging an unexpected field
value without needing to add a targeted extract. Enable only when actively investigating.

---

## Implementation

### New flag in `CambrianCameraConfig`

Add alongside the existing `verboseDiagnostics` and `verboseSettings` flags:

```kotlin
/** Logs the full TotalCaptureResult every 30 frames. Independent of verboseDiagnostics.
 *  Produces verbose output — enable only when investigating an unexpected capture field. */
const val verboseFullResult = false
```

### New class fields in `CameraController`

```kotlin
// 3A state tracking for Tier 1 state-change logs
@Volatile private var lastAeState: Int? = null
@Volatile private var lastAfState: Int? = null
@Volatile private var lastAwbState: Int? = null
@Volatile private var lastHeartbeatFrameCount: Long = 0L
```

Reset all four in `teardown()`.

### Helper functions (private, added near `describeTargetSurface`)

- `aeStateName(state: Int?): String` — maps Camera2 AE state int to name string
- `afStateName(state: Int?): String` — maps AF state int
- `awbStateName(state: Int?): String` — maps AWB state int
- `fmtExpMs(ns: Long?): String` — formats nanoseconds as `"33ms"`
- `buildAeLog(result: TotalCaptureResult, prev: Int?, new: Int?): String` — reads iso + exp from result
- `buildAfLog(result: TotalCaptureResult, prev: Int?, new: Int?): String` — reads focus distance
- `buildAwbLog(result: TotalCaptureResult, prev: Int?, new: Int?): String` — reads WB gains
- `buildHeartbeatLog(result: TotalCaptureResult, count: Long, drops: Long): String` — structured summary

All log-line builders take `TotalCaptureResult` and extract what they need internally — no
pre-extraction of fields in the callback body.

### `setState` update

```kotlin
private fun setState(newState: State) {
    val prev = state
    state = newState
    if (prev == newState) return
    android.util.Log.i("CambrianCamera", "[CAM] $prev → $newState")
}
```

### `repeatingCaptureCallback` update

```kotlin
override fun onCaptureCompleted(..., result: TotalCaptureResult) {
    // Seed manual-mode partner values (unchanged)
    result.get(SENSOR_SENSITIVITY)?.let { lastKnownIso = it }
    result.get(SENSOR_EXPOSURE_TIME)?.let { lastKnownExposureTimeNs = it }
    captureResultCount++

    // Tier 1: 3A state changes (unconditional)
    val newAeState  = result.get(CONTROL_AE_STATE)
    val newAfState  = result.get(CONTROL_AF_STATE)
    val newAwbState = result.get(CONTROL_AWB_STATE)
    if (newAeState  != lastAeState)  { Log.i(TAG, buildAeLog(result, lastAeState, newAeState));   lastAeState  = newAeState  }
    if (newAfState  != lastAfState)  { Log.i(TAG, buildAfLog(result, lastAfState, newAfState));   lastAfState  = newAfState  }
    if (newAwbState != lastAwbState) { Log.i(TAG, buildAwbLog(result, lastAwbState, newAwbState)); lastAwbState = newAwbState }

    // FrameResult to Dart (~3 Hz, every 10th result) — unchanged

    // Tier 2: Heartbeat (verboseDiagnostics-gated, every 30 results)
    if (!CambrianCameraConfig.verboseDiagnostics) return
    if (captureResultCount % 30L != 0L) return
    val drops = maxOf(0L, 30L - (streamFrameCount - lastHeartbeatFrameCount))
    lastHeartbeatFrameCount = streamFrameCount
    Log.d(TAG, buildHeartbeatLog(result, captureResultCount, drops))
    if (CambrianCameraConfig.verboseFullResult) {
        Log.d(TAG, "[FULL #$captureResultCount] $result")
    }
}
```

### Files changed

| File | Change |
|------|--------|
| `CameraController.kt` | New fields, helpers, `setState`, capture callback, `updateSettings` settings log |
| `CambrianCameraConfig.kt` | Add `verboseFullResult` flag |
| `cambrian_camera_controller.dart` | 4 `debugPrint` calls in `open`, `close`, `_onStateChanged`, `_onError` |

---

## Phase 4 deferred items

When Phase 4 C++ consumer fan-out is implemented, add to `ImagePipeline.cpp`:

- `LOGI("[PIPE] sink '%s' registered  ring=%d  drop=%s", ...)` in `addSink()`
- `LOGI("[PIPE] sink '%s' removed", ...)` in `removeSink()`
- `LOGW("[PIPE] sink '%s' ring full — frame #%lld dropped", ...)` when `dropOnFull=false`
- Per-sink ring occupancy in the structured heartbeat
