# Integration Testing: Lessons Learned

<!-- LLM SUMMARY
This document covers the integration test infrastructure for camera2_flutter_demo, a Flutter app that drives Android Camera2 hardware directly. It is useful when: adding new tests, debugging test failures, understanding why certain tools/approaches are forbidden, troubleshooting permission or connectivity issues, or understanding the planned agentic test harness.

Topics covered:
- Why integration_test was chosen over flutter_driver and flutter_drive
- How WidgetRegistry, Testable, and keys/ files work together
- The two-part permission solution (adb install -r -g + RUNNING_TESTS dart-define)
- Why flutter test over WiFi ADB loops; how mcp__dart__run_tests fixes it
- run_tests.sh as the canonical test runner and its required step order
- Common pitfalls with concrete fixes
- Pump timing patterns for animations and recording
- Why smoke tests aren't real integration tests — the gap between widget presence and hardware state
- Frame metadata missing from FrameResult (frameNumber, sensorTimestampNs, 3A states)
- Architecture decision: WebSocket harness + CLI + Claude skill (not MCP)
- Why TestChannel service extensions are being replaced by AppStateReader
- Skill + CLI vs MCP for LLM agent tooling — token efficiency and comparable performance
-->

---

## Table of Contents

1. [What We're Building and Why](#what-were-building-and-why)
2. [Architecture Overview](#architecture-overview)
3. [What We Tried and What Failed](#what-we-tried-and-what-failed)
4. [The Permission Problem](#the-permission-problem)
5. [Widget Keys and the Registry](#widget-keys-and-the-registry)
6. [Running Tests Over WiFi ADB](#running-tests-over-wifi-adb)
7. [Common Pitfalls](#common-pitfalls)
8. [Ideal Patterns](#ideal-patterns)
9. [The Smoke Test Realization](#the-smoke-test-realization)
10. [Frame Metadata: What the Hardware Knows That We Don't](#frame-metadata-what-the-hardware-knows-that-we-dont)
11. [Designing for Agentic Testing](#designing-for-agentic-testing)
12. [Tooling Decisions: Skill + CLI Over MCP](#tooling-decisions-skill--cli-over-mcp)
13. [Architecture Decisions Summary](#architecture-decisions-summary)
14. [Key Insights](#key-insights)

---

## What We're Building and Why

camera2_flutter_demo is a real-time camera control app built on a custom `cambrian_camera` plugin that drives Camera2 directly from Kotlin and a C++ GPU pipeline. The UI exposes ISO, shutter, focus, white balance, zoom, and GPU processing controls over a live viewfinder.

Bugs in this stack tend to be silent — the camera stops opening, recording silently fails, or state is left dirty between tests. Regressions are only caught when a human notices. The integration test suite is designed to automate the user-facing paths: open settings, tap chips, start/stop recording, and assert the app responds correctly at each step.

We chose on-device integration tests (not unit tests) because the interesting failures happen at the Flutter/native boundary — and those only activate with real Camera2 hardware.

---

## Architecture Overview

### How it fits together

```
integration_test/
  app_test.dart                  # test entry point
  helpers/camera_test_helpers.dart  # tapEntry, openSettings, startRecording, …

lib/testing/
  widget_registry.dart           # WidgetRegistry singleton + WidgetEntry
  testable.dart                  # Testable widget wrapper (key + semantics)
  test_channel.dart              # ext.test.cameraState service extension (debug only)
  keys/
    bottom_bar_keys.dart
    camera_settings_bar_keys.dart
    camera_control_keys.dart
    gpu_controls_sidebar_keys.dart

scripts/
  run_tests.sh                   # canonical test runner — always use this
  wake_and_launch.sh             # device wake/unlock (called by run_tests.sh)
```

`lib/testing/` is separated from `lib/widgets/` so test infrastructure doesn't pollute widget code. The `keys/` subdirectory groups key registrations by area.

### Key components

| Component | Role |
|-----------|------|
| `WidgetRegistry` | Singleton; creates and stores all `WidgetEntry` instances; enforces unique IDs via `assert` |
| `WidgetEntry` | Holds an ID, `ValueKey`, label, and description for one testable widget |
| `Testable` | Widget wrapper; applies the `ValueKey` and a `Semantics` node from the registry entry |
| `keys/*_keys.dart` | Top-level `final` variables that call `WidgetRegistry.register()`; one file per widget group |
| `run_tests.sh` | Builds with `RUNNING_TESTS=true`, installs with `-g`, then runs tests |

### The test runner workflow

`run_tests.sh` runs these steps in order — skipping any step breaks something:

| Step | Command | Why it matters |
|------|---------|----------------|
| Wake device | `wake_and_launch.sh` | Tests fail on a locked screen |
| Build APK | `flutter build apk --debug --dart-define=RUNNING_TESTS=true` | Compiles the no-dialog permission guard into the app |
| Grant permissions | `adb install -r -g` | Pre-grants CAMERA before the app ever runs |
| Run tests | `flutter test ... --dart-define=RUNNING_TESTS=true` | Passes the flag to the test shim as well |

---

## What We Tried and What Failed

We went through several frameworks and approaches before landing on the current setup. Here's the full history.

### Framework choices

| Approach | What happened | Root cause | Decision |
|----------|-------------|------------|----------|
| `flutter_driver` | Times out during recording | Camera2 frame callbacks prevent the engine from ever going idle; driver's wait-for-idle hangs | Abandoned; removed from project |
| `flutter drive --use-application-binary` | Times out immediately | `flutter drive` requires `enableFlutterDriverExtension()`; our tests use the `integration_test` binding — incompatible protocols | Abandoned |
| `integration_test` (in-process) | Works | Tests call `app.main()` inside `testWidgets`; direct widget access, no IPC; uses `pump(duration)` instead of wait-for-idle | **Current approach** |

### Permission granting

| Approach | What happened | Root cause | Decision |
|----------|-------------|------------|----------|
| `adb shell pm grant` | `SecurityException` | Android 16 blocks `pm grant` for dangerous permissions without root | Abandoned |
| Rely on `flutter test` to preserve permissions | Dialog appears; camera doesn't open | `flutter test` reinstalls without `-g`, resetting permissions on every run | Abandoned |
| `adb install -r -g` + `RUNNING_TESTS=true` dart-define | No dialog; camera opens | OS-level grant + compile-time flag that suppresses `request()` call in app code | **Current approach** |

### Test runner connectivity

| Approach | What happened | Root cause | Decision |
|----------|-------------|------------|----------|
| `flutter test ... -d 192.168.1.x` over WiFi | "test starting…" loop, never runs | VM service port forwarding is unreliable over TCP-based WiFi ADB | Avoid for interactive use |
| `mcp__dart__run_tests` MCP tool | Connects reliably | MCP tool manages the VM service connection differently | **Use for interactive iteration** |

### Small bugs found along the way

| Bug | Symptom | Fix |
|-----|---------|-----|
| `--use-application-binary` in `flutter test` | "unknown flag" error | Flag only exists in `flutter drive`, not `flutter test` |
| Concurrent `Permission.camera.request()` calls | `PlatformException("request already running")` | Catch exception, wait 500ms, re-check status |
| Lockscreen grep capturing wrong value | Script misread lock state | Changed to `-oE 'mDreamingLockscreen=(true|false)'` |
| `debugPrint` in test file | Compile error | Use `print()` or import `foundation.dart` explicitly |

---

## The Permission Problem

This was the hardest problem. The app needs camera permission to do anything useful in tests, but Android 16 makes it difficult to grant permissions programmatically.

### The failure chain

`flutter test` installs a fresh APK without `-g` → permissions reset → app calls `Permission.camera.request()` → system dialog appears → no one accepts it → camera never opens → tests pass but test nothing meaningful.

### The two-part solution

**Part 1 (OS level):** `adb install -r -g` grants all runtime permissions at install time. Works on Android 6+ including Android 16 without root. This is the only supported mechanism.

**Part 2 (app level):** Build with `--dart-define=RUNNING_TESTS=true`. The app checks this compile-time constant in `_openCamera()` and, when true, skips `Permission.camera.request()` entirely — only calling `Permission.camera.status`. If status isn't granted, it logs a clear message and returns rather than blocking on a dialog.

```dart
const bool runningTests = bool.fromEnvironment('RUNNING_TESTS');
if (runningTests) {
  status = await Permission.camera.status;
  if (!status.isGranted) {
    debugPrint('TEST MODE: camera not granted — use run_tests.sh');
    return;
  }
} else {
  // normal app: request permission if needed
}
```

**Why both parts are required:**

| Scenario | Result |
|----------|--------|
| Part 1 only (`-g` install, no dart-define) | Safe only if `run_tests.sh` installs. Any other tool reinstalls without `-g` and the dialog returns. |
| Part 2 only (dart-define, no `-g` install) | `status` is `denied`; camera never opens; tests fail. |
| Both together | OS says granted; app never asks the user. Solid. |

`bool.fromEnvironment` is **compile-time**, not runtime. A production build without the flag always has `runningTests == false`. There is no risk of accidentally suppressing permission dialogs in production.

---

## Widget Keys and the Registry

Plain `const ValueKey` constants work for finding widgets but carry no metadata, don't enforce uniqueness, and can't be enumerated. `WidgetRegistry` fixes all three.

### Why a registry

| Problem with plain constants | How registry solves it |
|-----------------------------|----------------------|
| No shared label for accessibility | `register()` takes a `label` used by both `Semantics` and test assertions |
| No guard against duplicate keys | `assert(!_entries.containsKey(id))` crashes immediately on duplicate |
| No way to enumerate testable widgets | `WidgetRegistry.instance.all` returns every registered entry |
| Key and semantics applied in two places | `Testable` is the single place that applies both |

### Lazy initialization behavior

Dart top-level `final` variables initialize on first access. Keys only register when their containing widget renders. Widgets behind conditional UI (GPU sidebar, WB segment, auto-toggle dial) won't appear in `WidgetRegistry.instance.all` until that UI is opened. Always use `greaterThanOrEqualTo` for count assertions, never an exact number.

### Key naming convention

`{area}.{widget}[.{sub}]` — for example: `chip.iso`, `gpu.black.r`, `bar.settings`, `hud.recording`. The area prefix groups related widgets for easy scanning.

---

## Running Tests Over WiFi ADB

| Method | Use case | Permission behavior |
|--------|----------|---------------------|
| `./scripts/run_tests.sh` | Clean runs, CI, any time you want guaranteed permission state | Builds + installs with `-g` + runs — fully self-contained |
| `mcp__dart__run_tests` MCP tool | Interactive iteration — reliable VM service over WiFi | Installs without `-g`; relies on a prior `run_tests.sh` install to have left permissions intact |

If the MCP tool is used after a fresh install (e.g., by Android Studio or another tool), run `run_tests.sh` first to restore the permission grant, then use MCP for subsequent iterations.

---

## Common Pitfalls

| Pitfall | What happens | Fix |
|---------|-------------|-----|
| Running `flutter test` directly | APK reinstalled without `-g` and without `RUNNING_TESTS=true`; permission dialog blocks tests | Always use `run_tests.sh` |
| Using `pumpAndSettle()` during recording | Hangs forever — frame callbacks prevent idle | Use `pump(duration)` |
| Exact registry count assertion | Flaky — count changes as conditional UI opens | Use `greaterThanOrEqualTo(N)` |
| Using `flutter drive` with `integration_test` tests | Times out — incompatible protocols | Only use `flutter test` |
| `debugPrint` in test files | Compile error | Use `print()`, or import explicitly |
| `pm grant` on Android 16 | `SecurityException` | Use `adb install -r -g` |
| Registering the same widget key twice | `assert` fires at startup | Check `lib/testing/keys/` for existing IDs |
| Omitting `--dart-define` from build step | `runningTests` compiles to `false`; dialog appears despite `-g` | Pass flag to both `flutter build apk` and `flutter test` |
| MCP tool run after a non-`run_tests.sh` install | Camera permission lost; camera doesn't open | Run `run_tests.sh` to restore grant |

---

## Ideal Patterns

### Pump timing

```dart
// Opening animated panels — settle, then extra time for IgnorePointer to clear
await tapEntry(tester, kBarSettings);
await tester.pumpAndSettle();
await tester.pump(const Duration(milliseconds: 500));

// During recording — explicit duration only, never pumpAndSettle
await tester.pump(const Duration(seconds: 1));
```

The 500ms after `pumpAndSettle()` matters: `IgnorePointer` widgets covering animated panels don't release until the animation fully completes, and `pumpAndSettle()` can declare victory slightly early.

### Recording tests

```dart
await startRecording(tester);                         // pump(1s) internally
expect(find.byKey(kHudRecording.key), findsOneWidget);
await tester.pump(const Duration(seconds: 3));        // let recording run
await stopRecording(tester);                          // pump(3s) for encoder flush
```

The 3-second wait in `stopRecording` covers the MediaRecorder encoder flush. Asserting on output before the flush completes gives inconsistent results.

### Setting dial values programmatically

```dart
final dialState = tester.state<CameraRulerDialState>(find.byKey(kDialIso.key));
dialState.setValue(800.0);
await tester.pump();
```

`CameraRulerDialState` is public and `@visibleForTesting` for this purpose. Simulating drag gestures on the dial is fragile due to velocity sensitivity; `setValue` is the reliable path.

### Verifying semantics during development

```dart
runApp(SemanticsDebugger(child: CameraApp()));
```

`SemanticsDebugger` renders the `Semantics` labels from `Testable` wrappers as on-screen overlays — useful for verifying every widget has the right label before writing assertions against them.

---

## The Smoke Test Realization

After getting all four tests passing — widget registry count, settings panel opens, chips tappable, recording start/stop — we stepped back and asked what these tests actually prove. The answer was uncomfortable: they prove the app doesn't crash when you tap things. That's it.

The tests answer "can a user tap through the UI?" They don't answer "does the camera actually do what the UI says it's doing?" Every assertion is `findsOneWidget` — verifying a widget appeared on screen. No test checks whether Camera2 applied a new ISO, whether a frame was delivered after changing settings, or whether the recorded file contains valid video.

The gap is between `tester.tap()` and what happened in Kotlin. The UI shows a chip labeled "ISO" and the test confirms the chip exists. But the interesting question — did `CameraController.kt` send the new ISO to Camera2 via `CaptureRequest`, and did the next `TotalCaptureResult` come back with `SENSOR_SENSITIVITY` matching? — goes completely unasked.

This matters because the bugs we've been fixing (stall watchdog, recording safety, lifecycle observer failures) are all native-side bugs. A smoke test that only checks widgets would have missed every one of them.

### What smoke tests do and don't catch

| What smoke tests catch | What they miss |
|----------------------|---------------|
| Widget tree renders without crash | Camera settings not applied to hardware |
| Buttons are tappable | Frame delivery stalled after settings change |
| Settings panel opens/closes | Recording produces no output file |
| Recording HUD appears | AE/AF/AWB never converges after parameter change |
| Registry has expected widget count | Concurrent permission requests crash the app (only caught because `PlatformException` propagated to the test) |

The existing `TestChannel` was designed to bridge this gap — it exposes camera state as JSON via a Dart VM service extension — but no test ever calls it. It was wired up and then forgotten, because the smoke tests were "passing" and the urgency to read hardware state was never felt until we looked critically at what "passing" meant.

---

## Frame Metadata: What the Hardware Knows That We Don't

To write tests that assert on hardware behavior, we need the data that Camera2's `TotalCaptureResult` provides. We traced the metadata pipeline from Kotlin through Pigeon to Dart and found significant gaps.

### What `FrameResult` carries today

| Field | Source | Available? |
|-------|--------|-----------|
| `iso` | `SENSOR_SENSITIVITY` | Yes |
| `exposureTimeNs` | `SENSOR_EXPOSURE_TIME` | Yes |
| `focusDistanceDiopters` | `LENS_FOCUS_DISTANCE` | Yes (AF locked only) |
| `wbGainR/G/B` | `COLOR_CORRECTION_GAINS` | Yes |

### What's missing

| Field | Source | Why it matters for testing |
|-------|--------|--------------------------|
| `frameNumber` | `getFrameNumber()` | Deterministic ordering — "after frame 1042, ISO changed to 800" instead of "at some point ISO became 800" |
| `sensorTimestampNs` | `SENSOR_TIMESTAMP` | Correlate UI actions to exact capture times; measure latency between tap and hardware response |
| `frameDurationNs` | `SENSOR_FRAME_DURATION` | Detect frame drops; verify FPS isn't degrading during test |
| `aeState` | `CONTROL_AE_STATE` | Assert "AE converged" before checking exposure values — replaces fragile "poll until stable" pattern |
| `afState` | `CONTROL_AF_STATE` | Assert "focus locked" rather than polling distance for stability |
| `awbState` | `CONTROL_AWB_STATE` | Assert "WB converged" before comparing gain values |

The 3A states are particularly important. Without them, a test that changes ISO and then reads the exposure value has no way to know whether AE has converged yet. It has to poll and hope — typically with a generous timeout and a `closeTo` matcher. With `aeState`, the test can wait for `CONVERGED` and then assert an exact value. The difference is between a flaky test and a deterministic one.

Frame numbers and timestamps together enable a pattern we call **frame-anchored assertions**: "starting at frame N, wait for a frame where condition X holds, then assert Y on that specific frame." This eliminates timing races entirely — you're asserting on a specific capture result, not on "whatever the latest value happens to be."

### Where the extraction happens

The metadata pipeline starts in `CameraController.kt` at the `onCaptureCompleted` callback (~line 1869). Currently it extracts ISO, exposure, focus, and WB gains on every 10th frame (~3 Hz at 30 fps) and sends them to Dart via Pigeon's `CamFrameResult` message. The missing fields (`frameNumber`, `sensorTimestampNs`, 3A states) are available in the same `TotalCaptureResult` object — they just aren't being read.

Adding them requires changes at three layers: the Pigeon message definition (`pigeons/camera_api.dart`), the Kotlin extraction code (`CameraController.kt`), and the Dart `FrameResult` class (`lib/src/frame_result.dart`). See `docs/plans/2026-04-08-real-integration-tests.md` for the implementation plan.

---

## Designing for Agentic Testing

The test infrastructure has two consumers with different needs: a CI pipeline that runs deterministic scripts, and an AI agent that explores the app reactively. We designed the architecture to serve both from the same primitives.

### Two modes, one control surface

```
Agent (Claude Code)              CI (run_tests.sh)
  │                                 │
  │ ./scripts/app_ctl.sh            │ direct Dart calls
  │ over WebSocket                  │ inside testWidgets
  ▼                                 ▼
┌────────────────────────────────────────┐
│  AppStateReader (shared Dart module)   │
│    getCameraState()                    │
│    getLatestFrame()                    │
│    getRecordingState()                 │
│    waitForFrame(predicate, timeout)    │
└────────────────────────────────────────┘
```

Both paths read state through `AppStateReader`. The agent gets there via a WebSocket harness in the app; CI tests get there via direct Dart function calls inside `testWidgets`. One implementation, two consumers.

### Why the WebSocket harness exists

Service extensions (`ext.test.*`) can read state but can't drive the UI — you can't synthesize a tap from a service extension because there's no `WidgetTester` outside `testWidgets`. The WebSocket harness runs inside the app process and can call `WidgetsBinding.instance.handlePointerEvent()` to synthesize taps, and `RenderRepaintBoundary.toImage()` for screenshots. It's a full control plane, not just a state reader.

### What TestChannel was and why it's being replaced

`TestChannel` registered Dart VM service extensions — hooks in the debug protocol that tools like DevTools can query. It was the first attempt at exposing camera state for tests. With the WebSocket harness now serving as the single control surface for both state reads and widget interactions, routing reads through service extensions became pointless indirection. `AppStateReader` replaces `TestChannel` as a plain Dart module — no protocol layer, no VM service dependency.

### The agentic workflow

The agent's interaction pattern looks like this:

1. Agent invokes `/app-control` skill — loads command reference into context
2. Agent runs `./scripts/app_ctl.sh tap chip.iso` — sends JSON-RPC over WebSocket to harness
3. Harness taps the widget, returns `{"ok": true}`
4. Agent runs `./scripts/app_ctl.sh get-frame` — reads latest `FrameResult` from hardware
5. Agent observes `{"frameNumber": 1847, "iso": 800, "aeState": "CONVERGED"}`
6. Agent decides what to verify next, or authors a `testWidgets` block from what it observed

The agent explores the app like a developer would — poke something, observe what changed, decide the next action. But it does it through structured JSON over a CLI, not by squinting at a screen.

---

## Tooling Decisions: Skill + CLI Over MCP

We evaluated three approaches for giving the AI agent access to the test harness:

### Approaches considered

| Approach | How it works | Token cost | Build cost | Error profile |
|----------|-------------|-----------|-----------|---------------|
| **MCP server** | Typed tool schemas loaded at session start; native tool calls | Schema tokens persist for entire session whether used or not | MCP stdio protocol + JSON-RPC boilerplate + tool registration | Low — structured input/output |
| **Claude skill + CLI** | Skill loaded on `/app-control` invocation; Bash calls to `app_ctl.sh` | Zero until invoked; skill content loaded once | One markdown file + one bash script | Low — JSON stdout is predictable; skill documents exact syntax |
| **Raw CLI (no skill)** | Agent reads the script to learn commands | Potentially high if agent reads script repeatedly | One bash script | Higher — agent must discover commands by reading code |

### Why skill + CLI wins

Research shows skills perform comparably to MCP tools for this kind of structured-command-with-JSON-response pattern. The key advantages:

**Token efficiency.** MCP tool schemas are loaded into context for the entire session. The `/app-control` skill loads only when the agent needs to interact with the app. For sessions focused on code review or architecture discussion, the app-control tooling costs zero tokens.

**Simpler to build.** A Claude skill is a markdown file with YAML frontmatter. The CLI is a bash script that opens a WebSocket, sends a JSON-RPC message, and prints the response. No MCP protocol implementation, no stdio transport, no tool registration boilerplate.

**Same maintenance burden.** Both MCP schemas and skill documentation must stay in sync with harness commands. Updating a markdown file is easier than updating a typed schema.

**The skill IS the documentation.** When the agent invokes `/app-control`, it gets the full command reference in context — parameter names, response formats, examples, edge cases. There's no separate docs file to maintain. The skill and the documentation are the same artifact.

**Upgrade path preserved.** If we later find the agent struggles with Bash invocation or stdout parsing (observable via error rates), wrapping the CLI in MCP is mechanical — the WebSocket harness doesn't change.

---

## Architecture Decisions Summary

| Decision | Rationale | Alternatives rejected |
|----------|-----------|----------------------|
| `integration_test` over `flutter_driver` | Camera2 frame callbacks prevent engine idle; driver times out during recording | `flutter_driver` abandoned |
| `adb install -r -g` over `pm grant` | `pm grant` blocked on Android 16 for dangerous permissions without root | `pm grant` abandoned |
| `RUNNING_TESTS` compile-time flag | `bool.fromEnvironment` resolved at build time — can't accidentally enable in production; suppresses permission dialog at source | Runtime flag (could leak to production) |
| Both `-g` and dart-define required | `-g` alone is fragile (any reinstall resets); dart-define alone fails (status is denied); together they form a contract | Either alone |
| `WidgetRegistry` over raw `ValueKey` constants | Enforces unique IDs, centralizes metadata, enables enumeration | Scattered constants (no uniqueness, no labels) |
| `AppStateReader` over `TestChannel` service extensions | WebSocket serves state directly; service extensions are unnecessary indirection; one module serves both agentic and CI paths | `TestChannel` being removed |
| WebSocket harness over service extensions only | Service extensions can read state but can't drive the widget tree (no pointer event synthesis) | Service extensions alone |
| Skill + CLI over MCP | Comparable performance, lighter token usage, simpler to build, skill IS the documentation | MCP (heavier, always-loaded schemas) |
| Fixed port 19400 | Unusual enough to avoid conflicts; simple; app restarts reuse the same port | Dynamic port negotiation (complex) |
| Frame metadata enrichment | `frameNumber` + `sensorTimestampNs` enable deterministic frame-anchored assertions; 3A states replace fragile polling patterns | Polling with generous timeouts (flaky) |
| CLI-first, MCP if needed | CLI validates the harness immediately; MCP upgrade is mechanical if error rates justify it | MCP-first (slower to validate) |
| Complement Dart MCP, don't replace | Dart MCP is the analysis layer (DevTools, hot reload). Our harness is the control layer (camera state, UI interaction). Different concerns. | Replacing Dart MCP (wrong scope) |

---

## Key Insights

### Passing tests aren't the same as tests that prove something

Four green tests felt like progress, but they were asserting on symptoms (widgets appeared) rather than behavior (hardware responded). The distinction matters: a smoke test suite can stay green through every native-side regression we've been fixing — stall watchdog bugs, recording safety issues, lifecycle observer failures — because it never looks past the widget tree.

The realization that `TestChannel` was wired up but unused is a pattern worth watching for: infrastructure built for a purpose but never actually connected to the purpose it was built for. The service extension existed, the state callback was registered, but no test ever called it. The smoke tests were "passing" and the urgency to use the deeper instrumentation was never felt — until we stepped back and asked what "passing" actually meant.

### Documentation-as-interface: the skill → CLI → harness pattern

A Claude skill is documentation-as-interface. The skill file teaches the agent how to use the CLI, and the CLI is just a thin pipe to the real system. This three-layer pattern cleanly separates concerns:

| Layer | Artifact | Concern |
|-------|----------|---------|
| **What the agent knows** | `.claude/skills/app-control/SKILL.md` | Command reference, parameter names, response formats, examples, edge cases |
| **How it communicates** | `scripts/app_ctl.sh` | WebSocket client — connect, send JSON-RPC, print response |
| **What the app does** | `lib/testing/test_harness.dart` | Synthesize taps, read state, capture screenshots, serve over WebSocket |

Each layer can change independently. The harness can add new commands without touching the CLI. The CLI can switch transports without touching the skill. The skill can be rewritten for clarity without touching either. And because the skill is loaded on demand rather than persisted in session context, it costs nothing when the agent isn't doing app interaction work.
