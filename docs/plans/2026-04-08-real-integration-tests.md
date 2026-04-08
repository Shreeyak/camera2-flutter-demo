# Real Integration Tests + Agentic Test Harness

**Date:** 2026-04-08
**Status:** Draft

## Problem

The current integration tests are smoke tests. They tap UI elements and assert widgets appear — but never verify that the camera actually responded. The gap is between `tester.tap(kChipIso)` and "did Camera2 apply the new ISO?"

Two goals:

1. **Proper integration tests** that assert on native-side state changes — ISO applied, recording started, frame delivery running — not just widget presence.
2. **A harness that lets Claude Code drive the running app** — tap widgets, read state, take screenshots — so it can author and debug tests by exploration rather than writing blind scripts.

## What Exists Today

| Component | Status | Location |
|-----------|--------|----------|
| `WidgetRegistry` + `Testable` wrappers | Done — 21 widgets registered | `lib/testing/` |
| `TestChannel` (service extension) | Wired but unused; will be replaced | `lib/testing/test_channel.dart` |
| `FrameResult` from hardware | ~3 Hz stream: ISO, exposure, focus, WB gains | `frameResultStream` on `CambrianCamera` |
| `CameraSettingsValues` | UI-side settings state model | `lib/camera/camera_settings_values.dart` |
| Dart MCP tools | `get_widget_tree`, `get_app_logs`, `hot_reload`, screenshots | External MCP server (analysis layer) |
| Integration test helpers | `tapEntry`, `openSettings`, `startRecording` | `integration_test/helpers/` |
| `run_tests.sh` | Builds with permissions, runs tests | `scripts/run_tests.sh` |

## Architecture

### How it works — the full picture

```
┌─────────────────────────┐         ┌────────────────────────────┐
│   Claude Code (agent)   │         │  CI runner                 │
│                         │         │  (run_tests.sh)            │
│  calls:                 │         │                            │
│  ./scripts/app_ctl.sh   │         │  runs testWidgets blocks   │
│    tap chip.iso         │         │  that import the same      │
│    get-state            │         │  AppStateReader module     │
│    screenshot           │         │                            │
└────────────┬────────────┘         └──────────┬─────────────────┘
             │                                  │
             │ WebSocket                        │ direct Dart calls
             │ localhost:19400                  │ (in-process)
             ▼                                  ▼
┌──────────────────────────────────────────────────────────────┐
│                    Flutter App (debug build)                  │
│                                                              │
│  TestHarness (WebSocket server)     AppStateReader (shared)  │
│    receives JSON-RPC commands  ──→  reads camera state       │
│    synthesizes pointer events       reads frame results      │
│    captures screenshots             reads widget states      │
│                                                              │
│  WidgetRegistry ← keys/ files ← Testable wrappers           │
│  CambrianCamera ← FrameResult stream ← Camera2 hardware     │
└──────────────────────────────────────────────────────────────┘
```

**Left path (agentic):** Claude Code invokes the `/app-control` skill to learn available commands, then runs `app_ctl.sh` CLI commands that connect to the in-app WebSocket harness. The harness taps widgets, reads state, returns structured JSON. Used for exploration, debugging, authoring new tests.

**Right path (CI):** Standard `testWidgets` blocks import `AppStateReader` directly. Same state-reading logic, no WebSocket. Deterministic scripts for CI.

**Both paths share `AppStateReader`** — one implementation, two consumers. No separate TestChannel service extension needed; the WebSocket serves state directly.

### Relationship to Dart MCP

The Dart MCP and our harness operate on different layers:

| Layer | Tool | Purpose |
|-------|------|---------|
| **Analysis** | Dart MCP | DevTools integration — widget inspector, hot reload, error logs, Dart analysis |
| **Control** | TestHarness + `app_ctl.sh` | Drive the app — tap widgets, change settings, assert on camera state |

They complement each other. The Dart MCP tells you about the Flutter framework. Our harness tells you about the camera.

### Why a Claude skill + CLI, not an MCP

| Factor | MCP Server | Skill + CLI |
|--------|-----------|-------------|
| Discovery | LLM sees typed schemas for entire session — tokens spent whether used or not | Skill loaded on demand via `/app-control`; zero token cost until invoked |
| Invocation | Native tool call: `app_tap(widget_id: "chip.iso")` | Bash: `./scripts/app_ctl.sh tap chip.iso` |
| Response | Structured JSON in tool result | JSON printed to stdout — same data, same format |
| Build cost | MCP server (stdio protocol, JSON-RPC boilerplate, registration) | One bash script + one markdown file |
| Performance | Research shows comparable to skills for this pattern | Research shows comparable to MCP; lighter on token usage |
| Maintenance | Tool schemas must stay in sync with harness commands | Skill markdown must stay in sync — same problem, easier to update |

**Decision: skill + CLI.** A Claude skill (`.claude/skills/app-control/SKILL.md`) documents every command with examples. The agent invokes `/app-control` when it needs to interact with the app, reads the command reference, and calls `app_ctl.sh` via Bash. The WebSocket harness does the real work — the CLI is just a thin client that connects, sends JSON-RPC, prints the response.

### Why TestChannel is removed

`TestChannel` uses Dart VM service extensions — a way to read state via the debug protocol. With the WebSocket harness serving state directly, service extensions are pointless indirection:

```
BEFORE:  CLI → VM service port → Dart VM → service extension → callback → JSON
NOW:     CLI → WebSocket → TestHarness → AppStateReader → JSON
```

The shared `AppStateReader` module replaces `TestChannel`. Both the WebSocket harness and CI test helpers call it directly.

## Frame Metadata — What's Missing

`FrameResult` currently carries ISO, exposure, focus, and WB gains. It's missing the metadata needed for precise test assertions and debugging:

| Field | Currently sent? | Source in TotalCaptureResult | Why it matters |
|-------|----------------|------------------------------|----------------|
| `iso` | Yes | `SENSOR_SENSITIVITY` | — |
| `exposureTimeNs` | Yes | `SENSOR_EXPOSURE_TIME` | — |
| `focusDistanceDiopters` | Yes (AF locked only) | `LENS_FOCUS_DISTANCE` | — |
| `wbGainR/G/B` | Yes | `COLOR_CORRECTION_GAINS` | — |
| **`frameNumber`** | **No** | `getFrameNumber()` | Deterministic ordering: "after frame 1042, ISO changed" |
| **`sensorTimestampNs`** | **No** | `SENSOR_TIMESTAMP` | Correlate events to exact capture times |
| **`frameDurationNs`** | **No** | `SENSOR_FRAME_DURATION` | Detect frame drops, verify FPS |
| **`aeState`** | **No** | `CONTROL_AE_STATE` | Know if AE has converged before asserting exposure values |
| **`afState`** | **No** | `CONTROL_AF_STATE` | Assert "focus locked" rather than polling distance for stability |
| **`awbState`** | **No** | `CONTROL_AWB_STATE` | Assert "WB converged" before comparing gains |

Adding `frameNumber` + `sensorTimestampNs` is the highest priority. With those, `waitForFrameResult` can buffer a ring of recent frames and the agent can say "show me the frame where ISO first became 800" rather than racing a poll loop.

The 3A states are the second priority — they replace fragile "poll until value stabilizes" patterns with definitive "3A algorithm reports CONVERGED" assertions.

### Changes needed in the plugin

| File | Change |
|------|--------|
| `pigeons/camera_api.dart` | Add `frameNumber`, `sensorTimestampNs`, `frameDurationNs`, `aeState`, `afState`, `awbState` to `CamFrameResult` |
| `CameraController.kt` (~line 1897) | Extract new fields from `TotalCaptureResult` and populate `CamFrameResult` |
| `lib/src/frame_result.dart` | Add matching Dart fields |
| `scripts/regenerate_pigeon.sh` | Run to regenerate bindings (never run `dart run pigeon` directly) |

## TestHarness Commands

### Widget interaction

| Command | Parameters | Returns | Notes |
|---------|-----------|---------|-------|
| `tap` | `widgetId: string` | `{ ok: true }` | Resolves registry key → RenderObject → synthesizes pointer events via `WidgetsBinding.handlePointerEvent()` |
| `long-press` | `widgetId: string` | `{ ok: true }` | Same path, longer duration |
| `set-dial` | `widgetId: string, value: number` | `{ ok: true }` | Finds `CameraRulerDialState`, calls `setValue()` |

### State observation

| Command | Parameters | Returns | Notes |
|---------|-----------|---------|-------|
| `get-state` | — | `{ isStreaming, isRecording, iso, exposureTimeNs, aeSeeded, isoAuto, exposureAuto, afEnabled, ... }` | UI-side state from `AppStateReader` |
| `get-frame` | `bufferLast?: int` | `{ frameNumber, sensorTimestampNs, iso, exposureTimeNs, focusDistanceDiopters, wbGainR/G/B, aeState, afState, awbState }` | Hardware-reported values. Optional `bufferLast` returns N most recent frames. |
| `get-recording` | — | `{ state: "recording"\|"idle"\|"error", durationMs?, outputPath? }` | Recording lifecycle state |
| `get-widgets` | — | `{ "chip.iso": { visible: true, selected: true }, ... }` | All registered widgets with visibility/selection state |

### Waiting

| Command | Parameters | Returns | Notes |
|---------|-----------|---------|-------|
| `wait-for` | `field: string, value: any, timeoutMs: int` | `{ matched: true, frame: {...} }` or `{ matched: false, lastValue: ... }` | Polls `AppStateReader` until field matches or timeout |
| `wait-frames` | `count: int, timeoutMs: int` | `{ frames: [...] }` | Buffers N new `FrameResult`s and returns them all |

### Capture

| Command | Parameters | Returns | Notes |
|---------|-----------|---------|-------|
| `screenshot` | `path?: string` | `{ path: "/tmp/shot.png" }` | `RenderRepaintBoundary.toImage()` → PNG. Saves to path or temp file. |
| `get-logs` | `sinceMs?: int` | `{ lines: [...] }` | `debugPrint` output since timestamp |

## CLI Tool: `app_ctl.sh`

Thin client that connects to the harness WebSocket, sends a JSON-RPC command, and prints the response:

```bash
./scripts/app_ctl.sh tap chip.iso
./scripts/app_ctl.sh get-state
./scripts/app_ctl.sh get-frame
./scripts/app_ctl.sh get-frame --buffer-last 5
./scripts/app_ctl.sh wait-for iso 800 --timeout 5000
./scripts/app_ctl.sh wait-frames 10 --timeout 5000
./scripts/app_ctl.sh screenshot /tmp/screen.png
./scripts/app_ctl.sh set-dial dial.iso 800
./scripts/app_ctl.sh get-widgets
./scripts/app_ctl.sh get-logs --since 1000
```

Every command prints a single line of JSON to stdout. Exit code 0 on success, 1 on error or timeout. A Claude skill documents all commands so the agent doesn't need to read the script.

## Test Patterns

### Pattern 1: State-change assertion (CI test)

```dart
testWidgets('ISO chip changes hardware ISO', (tester) async {
  app.main();
  await tester.pumpAndSettle(const Duration(seconds: 3));

  final before = await stateReader.getLatestFrame();

  await openSettings(tester);
  await tapChip(tester, kChipIso);
  await setDial(tester, kDialIso, 800);
  await closeSettings(tester);

  // Wait for Camera2 hardware to reflect the change
  final after = await stateReader.waitForFrame(
    (f) => f.iso == 800,
    timeout: const Duration(seconds: 5),
  );

  expect(after.iso, equals(800));
  expect(after.frameNumber, greaterThan(before.frameNumber));
});
```

### Pattern 2: Recording lifecycle (CI test)

```dart
testWidgets('recording produces output file', (tester) async {
  app.main();
  await tester.pumpAndSettle(const Duration(seconds: 3));

  await startRecording(tester);
  expect(stateReader.getCameraState()['isRecording'], isTrue);

  // Wait for 10 frames to be captured during recording
  final frames = await stateReader.waitForFrames(count: 10, timeout: 5.seconds);
  expect(frames.length, equals(10));

  await stopRecording(tester);
  final recording = stateReader.getRecordingState();
  expect(recording['state'], equals('idle'));
  expect(File(recording['outputPath']).existsSync(), isTrue);
});
```

### Pattern 3: Agentic exploration → authored test

Claude explores live via `app_ctl.sh`:

```
$ ./scripts/app_ctl.sh tap bar.settings
{"ok":true}
$ ./scripts/app_ctl.sh tap chip.wb
{"ok":true}
$ ./scripts/app_ctl.sh get-state
{"wbLocked":false,"isStreaming":true,...}
$ ./scripts/app_ctl.sh tap dial.wb_segment
{"ok":true}
$ ./scripts/app_ctl.sh get-state
{"wbLocked":true,...}
$ ./scripts/app_ctl.sh get-frame
{"frameNumber":1847,"wbGainR":1.82,"wbGainB":2.05,"awbState":"LOCKED",...}
```

Claude observes the transitions and generates a `testWidgets` block that asserts on those specific state changes — using frame numbers and 3A state rather than timing heuristics.

## Implementation Plan

### Phase 1: Frame metadata + proper CI tests

Enrich `FrameResult` with hardware metadata and write tests that assert on real state. No new infrastructure beyond `AppStateReader`.

| Task | What | Files |
|------|------|-------|
| 1.1 | Add `frameNumber`, `sensorTimestampNs`, `frameDurationNs`, `aeState`, `afState`, `awbState` to Pigeon `CamFrameResult` | `pigeons/camera_api.dart` |
| 1.2 | Extract new fields from `TotalCaptureResult` in `onCaptureCompleted` | `CameraController.kt` (~line 1897) |
| 1.3 | Add matching fields to Dart `FrameResult` class | `lib/src/frame_result.dart` |
| 1.4 | Regenerate Pigeon bindings | `scripts/regenerate_pigeon.sh` |
| 1.5 | Create `AppStateReader` — shared module that reads camera state, latest frame, recording state, widget states | `lib/testing/app_state_reader.dart` |
| 1.6 | Remove `TestChannel` service extension; wire `AppStateReader` into `_CameraScreenState` | `lib/testing/test_channel.dart` (delete), `lib/main.dart` |
| 1.7 | Add CI test helpers: `getCameraState`, `getLatestFrame`, `waitForFrame`, `waitForFrames` | `integration_test/helpers/` |
| 1.8 | Write ISO change test (Pattern 1) | `integration_test/app_test.dart` |
| 1.9 | Write recording lifecycle test (Pattern 2) | same |
| 1.10 | Write 3A convergence test (change setting → wait for aeState CONVERGED → assert value) | same |

### Phase 2: WebSocket harness + CLI

Build the in-app harness and CLI client so Claude Code can drive the app live.

| Task | What | Files |
|------|------|-------|
| 2.1 | Create `TestHarness` — WebSocket server on port 19400, JSON-RPC dispatch, `kDebugMode` guard | `lib/testing/test_harness.dart` |
| 2.2 | Implement `tap`, `long-press` — resolve registry key → `WidgetsBinding.handlePointerEvent()` | same |
| 2.3 | Implement `get-state`, `get-frame`, `get-recording`, `get-widgets` — delegate to `AppStateReader` | same |
| 2.4 | Implement `wait-for`, `wait-frames` — poll with `Completer` + `Timer` | same |
| 2.5 | Implement `set-dial` — find `CameraRulerDialState`, call `setValue()` | same |
| 2.6 | Implement `screenshot` — `RenderRepaintBoundary.toImage()` → PNG → save to path | same |
| 2.7 | Implement `get-logs` — ring buffer of recent `debugPrint` output | same |
| 2.8 | Start harness from `main.dart` in debug builds | `lib/main.dart` |
| 2.9 | Create `app_ctl.sh` CLI client — connects to WebSocket, sends command, prints JSON | `scripts/app_ctl.sh` |
| 2.10 | Create Claude skill for app control — documents all commands, examples, response formats. Lives at `.claude/skills/app-control/SKILL.md`. Agent invokes via `/app-control`. | `.claude/skills/app-control/SKILL.md` |
| 2.11 | Port-forward WebSocket over ADB for WiFi devices: `adb forward tcp:19400 tcp:19400` | Add to `run_tests.sh` |

### Phase order

Phase 1 is immediately useful — proper tests with frame metadata, no new infrastructure. Phase 2 adds agentic capability with the WebSocket harness, CLI tool, and Claude skill.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| WebSocket in app process affects camera performance | Frame drops during testing | Debug builds only; benchmark with/without; harness is idle when no client connected |
| `handlePointerEvent()` behaves differently than `tester.tap()` | Gesture recognizers miss events | Test both paths; fall back to `GestureBinding.dispatchEvent()`; validate against CI tests |
| `FrameResult` at ~3 Hz is slow for assertions | Long timeouts needed | `waitForFrame` with configurable timeout; 5s default covers 15+ frames |
| ADB port forwarding for WiFi devices | Extra setup step | Automate in `run_tests.sh`; document in skill |
| Security: WebSocket exposes app internals | Debug-mode data leak | `kDebugMode` guard; bind to loopback only; refuse connections in release builds |

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Skill + CLI, no MCP | A skill is loaded on demand (zero token cost until invoked); research shows skills perform comparably to MCP tools; CLI is trivial to build; the WebSocket harness does the real work regardless of client |
| Replace `TestChannel` with `AppStateReader` | WebSocket serves state directly; service extensions are unnecessary indirection; one module shared by both WebSocket and CI paths |
| Fixed port 19400 | Simple; unusual enough to avoid conflicts; app restarts reuse the same port |
| Complement Dart MCP, don't replace | Dart MCP is the analysis layer (DevTools). Our harness is the control layer (camera state + UI interaction). Different concerns. |
| `waitForFrame` buffers on request | Pass `bufferLast` to get N recent frames; default returns latest only; frame numbers + timestamps enable precise comparisons |
| Frame metadata in plugin | `frameNumber`, `sensorTimestampNs`, 3A states flow from `TotalCaptureResult` through Pigeon to Dart — enriches both test assertions and future app features |
