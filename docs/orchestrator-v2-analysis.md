# Orchestrator v2 Analysis: Post-Mortem, Improvements, and Implementation Plan

**Date:** 2026-04-07
**Context:** Analysis of an 8-plan sequential orchestration run using Claude Code subagents, with concrete improvement proposals for v2.

---

## Table of Contents

1. [Background](#1-background)
2. [What Happened: The v1 Run](#2-what-happened-the-v1-run)
3. [Failure Analysis](#3-failure-analysis)
4. [Orchestrator Prompt v2 Changes](#4-orchestrator-prompt-v2-changes)
5. [CLAUDE.md Improvements for Subagents](#5-claudemd-improvements-for-subagents)
6. [Custom Agent Definitions](#6-custom-agent-definitions)
7. [Git State Management Tooling](#7-git-state-management-tooling)
8. [Subagent Behavior Observations](#8-subagent-behavior-observations)
9. [Context Architecture: What Goes Where](#9-context-architecture-what-goes-where)
10. [Implementation Plan](#10-implementation-plan)
11. [File Locations](#11-file-locations)

---

## 1. Background

### What is the orchestrator?

A prompt given to Claude Code that coordinates subagents to implement a sequence of plan files. The orchestrator never writes code itself — it dispatches implementer subagents, reviewer subagents, and PR subagents, handling their return statuses and managing git state between dispatches.

### The v1 run

8 plans were executed sequentially, each addressing code review feedback from PRs #17-#22. The plans were small, focused fixes to `CameraController.kt`, `GpuRenderer.cpp`, `CameraBridge.cpp`, `LogLevelReceiver.kt`, and `CambrianCameraPlugin.kt`.

### Artifacts

| File | Location | Description |
|------|----------|-------------|
| v1 prompt | `/Users/shrek/Downloads/orchestrator-prompt.md` | Original orchestrator prompt |
| v2 prompt | `/Users/shrek/Downloads/orchestrator-prompt-v2.md` | Improved prompt with fixes |
| v2 rationale | `/Users/shrek/Downloads/orchestrator-prompt-v2-rationale.md` | Detailed rationale for each v2 change |
| CLAUDE.md additions | `/Users/shrek/Downloads/claude-md-subagent-additions.md` | Recommended additions to CLAUDE.md |
| This analysis | `docs/orchestrator-v2-analysis.md` | This file |

---

## 2. What Happened: The v1 Run

### Results Summary

| # | Plan | Status | PR | Agents Used | Issue |
|---|------|--------|-----|-------------|-------|
| 1 | Fix exported log receiver | DONE | #24 `ef22172` | 4 | Clean |
| 2 | Fix FPS degradation gating | DONE | #25 `3af6ee3` | 4 | Clean |
| 3 | Fix GPU renderer diagnostics | DONE | #26 `0dbaf10` | 4 | Clean |
| 4 | Fix lifecycle observer logging | DONE | #27 `4d5849e` | 4 | Clean |
| 5 | Fix native C++ safety | DONE | #28 `db6e1ed` | 4 | Clean |
| 6 | Fix pause recording and KDoc | DONE | #29 `ae492f9` | **10** | Spiraled |
| 7 | Fix stall watchdog initial state | DONE | #30 `c4edd7e` | 4 | Clean |
| 8 | Fix test JNI signatures | DONE | N/A (already done) | 2 | No-op |

**Total subagents: ~36.** A perfect run would have used ~28 (4 per plan, minus Plan 8). Plan 6 alone wasted ~6 extra dispatches.

### Per-Plan Agent Breakdown (Clean Plan)

A clean plan uses exactly 4 subagent dispatches:

```text
Plan N
  │
  ├──① Implementer ──────► DONE
  │
  ├──② Spec reviewer ────► PASS
  │
  ├──③ Quality reviewer ──► PASS
  │
  └──④ PR agent ──────────► Merged
```

### Plan 6 Agent Breakdown (Spiraled)

```text
Plan 6
  │
  ├──① Implementer ──────────────► DONE_WITH_CONCERNS (left TODOs)
  │
  ├──② Fix agent (same worktree) ► Also couldn't find APIs (stale worktree)
  │
  ├──③ Rebase agent ─────────────► Rebased onto current dev
  │
  ├──④ Spec reviewer #1 ────────► PASS (but missed KDoc issue)
  │
  ├──⑤ Quality reviewer #1 ─────► FAIL (threading + missing notification)
  │
  ├──⑥ Fix agent (threading) ───► Fixed both issues
  │
  ├──⑦ Spec reviewer #2 ────────► FAIL (KDoc on old pause(callback) not fixed)
  │
  ├──⑧ Fix agent (KDoc) ────────► Fixed one line
  │
  ├──⑨ Combined reviewer ───────► PASS
  │
  └──⑩ PR agent ────────────────► Merged
```

---

## 3. Failure Analysis

### Failure 1: Worktree Base Branch Divergence (Critical, Plan 6)

**Root cause:** Claude Code's `isolation: "worktree"` feature branches from the main worktree's current `HEAD`. During the run, the main worktree drifted off `dev`:

1. After Plan 2's PR merge, the orchestrator ran `git merge origin/dev` which created merge commits on a leftover feature branch (`fix/fps-degradation-outside-verbose-gate`).
2. The main worktree stayed on that feature branch for subsequent dispatches.
3. By Plan 6, the worktree branched from `79c3b7a` (pre-Plan-1 commit) instead of `db6e1ed` (current `dev` with Plans 1-5 merged).

**Cascade:**
- Implementer couldn't find `gpuPipeline`, `videoRecorder`, `onRecordingStateChanged`
- Left calls as `// TODO` comments (wrong — these APIs exist in current `dev`)
- Fix subagent dispatched into same stale worktree also couldn't find them
- Required a rebase subagent to bring worktree up to date
- Then re-implementation, then KDoc fix, then threading fix

**Cost:** ~6 extra subagent dispatches

**Fix:** Two complementary approaches:
1. **Orchestrator prompt v2:** Mandatory `git fetch origin dev && git reset --hard origin/dev` before every worktree dispatch
2. **Wrapper script:** `scripts/create-worktree.sh` that branches from `origin/dev` directly (not from `HEAD`), eliminating the dependency on main worktree state entirely

### Failure 2: Implementer Left TODOs Instead of Reporting NEEDS_CONTEXT

**Root cause:** No explicit rule told the implementer that commented-out spec requirements are not acceptable. The implementer made a locally reasonable decision: "I can't find this API, so I'll leave a TODO for when it's wired up." But this violated the plan's intent.

**Fix:** 
- CLAUDE.md: "Never leave TODOs for spec-required behavior"
- Custom agent definition: Bake the rule into the implementer's system prompt
- Orchestrator v2: Explicit instructions in every implementer prompt

### Failure 3: `git pull` Failures (3 occurrences)

**Root cause:** `git pull` with `--ff-only` (default config) fails when local and remote have diverged. Squash-merging PRs on GitHub creates new commits that don't share ancestry with local merge commits.

**Fix:** Ban `git pull` entirely. Use `git fetch + git reset --hard` which always succeeds.

### Failure 4: Code Quality Reviewer Caught Real Threading Bug

**Root cause:** The plan's code sample showed `pause()` calling `teardown()` directly. The implementer copied this pattern. But every other teardown path in `CameraController.kt` posts to `backgroundHandler` — the plan's sample was a sketch, not production code.

**Not a process failure** — the quality reviewer correctly caught this. But it could have been prevented if:
- CLAUDE.md documented the threading model
- The implementer's system prompt said "match surrounding code patterns, not plan samples"

### Failure 5: Plan 8 Was a No-Op

**Root cause:** The backward-compatible JNI overloads were already present in `dev`. No pre-flight check existed to detect this.

**Fix:** Orchestrator v2 adds Phase 0.5 (Pre-Flight Triage) that checks if plan changes already exist before dispatching an implementer.

### Failure 6: Worktree Cleanup Failures

**Root cause:** `git worktree remove <path>` fails if the shell CWD is inside the worktree being removed. Also, some worktrees were auto-cleaned by Claude Code's `isolation` feature while others persisted.

**Fix:** Always `cd` to main repo root before cleanup. Use `2>/dev/null || true` to handle already-removed worktrees.

---

## 4. Orchestrator Prompt v2 Changes

Full v2 prompt is at `/Users/shrek/Downloads/orchestrator-prompt-v2.md`. Key changes:

| Change | What | Why |
|--------|------|-----|
| Pre-dispatch sync invariant | `git reset --hard origin/dev` before every worktree dispatch | Prevents stale-base bugs |
| Ban `git pull` | Always `git fetch + reset --hard` | Prevents non-fast-forward failures |
| Pre-flight triage (Phase 0.5) | Check if changes already exist, categorize as trivial/standard | Skip no-ops, use lighter review for trivial plans |
| Hardened implementer contract | "Never leave TODOs, match surrounding patterns, use NEEDS_CONTEXT" | Prevents false DONE status |
| Concern evaluation protocol | Verify DONE_WITH_CONCERNS claims against main worktree | Prevents dispatching fix agents into stale worktrees |
| Spec reviewer anti-TODO rule | "FAIL if spec-required behavior is commented out" | Prevents passing broken implementations |
| Combined review for trivial plans | Single reviewer for <=5 line single-file changes | Saves 1 subagent per trivial plan |
| Worktree cleanup from correct CWD | `cd <main-repo-path>` before `git worktree remove` | Prevents CWD-in-deleted-directory errors |

Full rationale with design principles is at `/Users/shrek/Downloads/orchestrator-prompt-v2-rationale.md`.

---

## 5. CLAUDE.md Improvements for Subagents

Every subagent gets CLAUDE.md automatically. Adding project knowledge there reduces what the orchestrator prompt must include and makes subagents smarter by default. Full analysis is at `/Users/shrek/Downloads/claude-md-subagent-additions.md`.

### Addition 1: CameraController Threading Model (High Impact)

Would have prevented: Plan 6 quality review failure (wrong-thread teardown) and missing Dart notification.

```markdown
## CameraController Threading Model

`CameraController.kt` uses two `Handler` threads with strict rules:

- **`backgroundHandler`** — All Camera2 operations (open, configure, capture,
  teardown) run here. The capture callback, stall watchdog, and recovery logic
  all execute on this thread. If you add a new method that touches Camera2
  state (`captureSession`, `cameraDevice`, surfaces, or the `state` enum),
  wrap the body in `backgroundHandler.post { ... }`.

- **`mainHandler`** — All Dart/Flutter callbacks (`flutterApi.*`,
  `emitState()`, Pigeon completion callbacks) must be posted here. Never call
  Pigeon APIs from `backgroundHandler` directly.

**Pattern to follow** — when adding a new public method:
```kotlin
fun myMethod(callback: (Result<Unit>) -> Unit) {
    backgroundHandler.post {
        // ... do Camera2 work ...
        mainHandler.post { callback(Result.success(Unit)) }
    }
}
```

Look at `backgroundSuspend()`, `backgroundResume()`, and `close()` as
reference implementations. Never call `teardown()` directly from the main
thread.
```

### Addition 2: Rules for AI Agents (High Impact)

Would have prevented: TODOs in Plan 6, pattern mismatches.

```markdown
## Rules for AI Agents

- **Never leave TODOs for required behavior.** If a plan or spec says to call
  an API and you cannot find it, stop and report the issue. Do not comment out
  the call or stub it. Working code is required, not intent markers.
- **Match surrounding patterns.** When adding a new function or code path,
  find 2-3 similar functions nearby and match their threading, error handling,
  logging, and state notification patterns. Code samples in plans are
  illustrative sketches — the codebase is the source of truth for HOW to
  implement.
- **State notifications are mandatory.** Any code path that changes camera
  state, recording state, or error state MUST notify Dart via the appropriate
  `flutterApi.*` callback posted on `mainHandler`. Forgetting a notification
  leaves the Dart state machine inconsistent.
- **Verify before claiming "doesn't exist."** If a plan references an API,
  field, or class you can't find, search broadly (`grep -r` across the full
  `packages/cambrian_camera/` tree). It may be in a different file than you
  expect. Only report NEEDS_CONTEXT after an exhaustive search.
```

### Addition 3: Build Verification Command (Medium Impact)

```markdown
## Verification

After any code change, run this single command to verify nothing is broken:

```bash
flutter build apk --debug
```

**Never use `--release`** for builds or `flutter run`. Debug builds are
sufficient for verification and avoid release-signing complications.

For changes to test files specifically, also run:
```bash
cd packages/cambrian_camera/android && ../../../android/gradlew :cambrian_camera:compileDebugAndroidTestKotlin
```
```

### Addition 4: Key Internal APIs Quick Reference (Medium Impact)

```markdown
## Key Internal APIs (CameraController.kt)

`CameraController.kt` (~1800 lines) is the core orchestrator on the Android
side. Key state fields:

| Field | Type | Purpose |
|-------|------|---------|
| `state` | `State` enum | Camera lifecycle (CLOSED, OPENING, STREAMING, RECOVERING) |
| `gpuPipeline` | `GpuPipeline?` | GPU processing pipeline; manages OpenGL surfaces |
| `videoRecorder` | `VideoRecorder?` | MediaRecorder wrapper for video capture |
| `isRecording` | `Boolean` | Guards recording teardown in `pause()` and `teardown()` |
| `captureSession` | `CameraCaptureSession?` | Active Camera2 session |
| `cameraDevice` | `CameraDevice?` | Open camera handle |
| `lastCaptureResultMs` | `Long` | Monotonic timestamp for stall detection |

When modifying `CameraController.kt`, read the surrounding 50 lines of any
method you're editing to understand its threading and error-handling context.
```

### Addition 5: Living Documents (Revised Wording)

Change existing section from passive ("keep up to date") to active ("read before coding"):

```markdown
## Living Documents

Read these before making changes to the plugin internals:

- **`docs/architecture.md`** — plugin architecture, data flow, component
  relationships. **Read this before modifying any Kotlin or C++ file** to
  understand how components interact.
- **`docs/usage-guide.md`** — public API and usage patterns. **Read this
  before modifying Dart-facing APIs** to understand the consumer contract.

Keep both files up to date whenever the architecture or public API changes.
```

### What NOT to add to CLAUDE.md

These are orchestrator-level concerns, not project knowledge:

| Item | Why not CLAUDE.md |
|------|-------------------|
| Git sync commands | Orchestrator workflow, not project knowledge |
| Return contract (JSON format) | Orchestrator prompt contract |
| Review iteration caps | Orchestrator workflow policy |
| Pre-flight triage logic | Orchestrator decision tree |
| Worktree creation/cleanup | Orchestrator resource management |

---

## 6. Custom Agent Definitions

Claude Code supports custom agent definitions in `.claude/agents/`. Each is a markdown file with YAML frontmatter. The markdown body becomes the agent's system prompt. Subagents receive only this system prompt (not the full Claude Code system prompt).

The orchestrator's `Agent` tool can reference custom agents via `subagent_type: "<agent-name>"`.

### Why custom agents matter

Currently the orchestrator inlines all subagent instructions into every prompt. This means:
- Repeated boilerplate across every dispatch
- Easy to forget a rule in one prompt
- No tool restrictions (a reviewer could accidentally edit files)
- No model pinning (everything uses whatever the orchestrator decides ad-hoc)
- No turn limits (a runaway subagent could burn tokens indefinitely)

Custom agents solve all of these by moving role-specific instructions into reusable definitions.

### Proposed agents

#### `.claude/agents/implementer.md`

```markdown
---
name: implementer
description: Implements a plan in an isolated worktree. Use for code changes with a clear spec.
tools: Read, Write, Edit, Glob, Grep, Bash, Skill
model: sonnet
maxTurns: 50
permissionMode: bypassPermissions
isolation: worktree
skills:
  - superpowers:test-driven-development
---

You are an implementer agent. You receive a plan and implement it.

## Process

1. Read the plan file provided in the prompt.
2. Read `docs/architecture.md` for project context and conventions.
3. Implement the plan. Match surrounding code patterns for threading,
   error handling, logging, and state notifications.
4. Run `flutter build apk --debug` to verify compilation.
5. Self-review your diff. Fix anything you catch.
6. Commit with a descriptive message.

## Critical Rules

- Code samples in plans are illustrative sketches showing WHAT to do.
  The codebase is the source of truth for HOW. Find 2-3 similar functions
  and match their patterns.
- NEVER leave TODO stubs for spec-required behavior. If an API referenced
  in the plan doesn't exist, search broadly (grep across the full
  `packages/cambrian_camera/` tree). If truly missing after exhaustive
  search, return NEEDS_CONTEXT — do not stub.
- Never use `--release` for builds.
- No wildcard imports (Kotlin or Dart).

## Kotlin Threading (CameraController.kt)

- Camera2 operations: wrap in `backgroundHandler.post { ... }`
- Dart/Flutter callbacks: post on `mainHandler`
- Never call `teardown()` from main thread directly
- Every state change must notify Dart via `flutterApi.*` on mainHandler
- Reference: `backgroundSuspend()`, `close()` for correct patterns

## Return Contract

You MUST return EXACTLY this JSON block as the last thing in your response:

```json
{
  "status": "DONE | DONE_WITH_CONCERNS | NEEDS_CONTEXT | BLOCKED",
  "summary": "what was done",
  "commits": ["sha1"],
  "concerns": ["if any — empty array if none"]
}
```

Status definitions:
- DONE: All spec requirements implemented as working, uncommented code.
- DONE_WITH_CONCERNS: Complete but with caveats worth flagging.
- NEEDS_CONTEXT: Cannot proceed — missing information or APIs. List exactly
  what you need.
- BLOCKED: Cannot proceed — fundamental issue. Explain clearly.
```

#### `.claude/agents/spec-reviewer.md`

```markdown
---
name: spec-reviewer
description: Reviews code against a plan spec for compliance. Use after implementation.
tools: Read, Glob, Grep, Bash
model: sonnet
maxTurns: 15
permissionMode: bypassPermissions
---

You are a spec-compliance reviewer. You verify that committed code
implements every requirement in a plan spec.

## Process

1. Read the plan file (the spec).
2. Run `git show <SHA>` to see the diff.
3. Read the full affected files for context (not just the diff).
4. Check every spec requirement individually.

## Rules

- FAIL if ANY required behavior is:
  - Commented out or marked TODO
  - Stubbed with placeholder values
  - Only partially implemented
  - Missing entirely
- FAIL if code was added that the spec did not request (over-implementation).
- Check that acceptance criteria from the spec are satisfied.

## Return Format

Return EXACTLY one of:

```
PASS
<optional brief explanation>
```

or

```
FAIL
- file.kt:NN — description of what's wrong and what the fix should be
- file.kt:NN — next issue
```

Every issue must be line-specific with a clear description of the required fix.
```

#### `.claude/agents/quality-reviewer.md`

```markdown
---
name: quality-reviewer
description: Reviews code for quality, correctness, and codebase consistency. Use after spec review passes.
tools: Read, Glob, Grep, Bash
model: sonnet
maxTurns: 20
permissionMode: bypassPermissions
---

You are a code quality reviewer for a Flutter + Kotlin + C++ camera plugin.

## Process

1. Run `git show <SHA>` to see the diff.
2. Read surrounding code in affected files to understand existing patterns.
3. Check each category below.

## What to Check

1. **Threading correctness** — Camera2 ops on backgroundHandler, Dart
   callbacks on mainHandler. No cross-thread access without @Volatile or
   handler serialization. New public methods must post to backgroundHandler.
2. **State notifications** — Every code path that changes camera, recording,
   or error state must notify Dart via the appropriate `flutterApi.*` callback
   posted on `mainHandler`.
3. **Idiomatic code** — Kotlin/C++ conventions, no wildcard imports, consistent
   naming with surrounding code.
4. **Error handling** — Matches patterns of surrounding code. JNI boundaries
   have try/catch. Camera2 failures are logged and surfaced.
5. **No unnecessary changes** — Nothing beyond the spec was added. No drive-by
   refactoring, no new abstractions for single-use code.

## Return Format

Return EXACTLY one of:

```
PASS
<optional brief explanation>
```

or

```
FAIL
- file.kt:NN — description of issue and required fix
- file.kt:NN — next issue
```

Every issue must reference the exact file and line range.
```

#### `.claude/agents/pr-agent.md`

```markdown
---
name: pr-agent
description: Pushes a branch, creates a GitHub PR targeting dev, and merges it.
tools: Bash
model: haiku
maxTurns: 15
permissionMode: bypassPermissions
---

You push a feature branch, create a PR, and merge it.

## Steps

1. Get branch name: `git branch --show-current`
2. Push: `git push -u origin <branch>`
3. Create PR: `gh pr create --title "<title>" --body "<body>" --base dev`
4. Wait for CI: `sleep 10`
5. Merge: `gh pr merge <number> --squash --delete-branch`
6. Get merge SHA: `gh pr view <number> --json mergeCommit -q .mergeCommit.oid`

The prompt will provide the PR title and body.

## Return Format

Return EXACTLY:
```json
{"branch": "<branch>", "pr_url": "<url>", "merge_sha": "<sha>"}
```

## Error Handling

- If push fails (branch already exists on remote): `git push -u origin <branch> --force-with-lease`
- If merge fails (conflicts): return `{"status": "CONFLICT", "pr_url": "<url>"}`
- If PR creation fails: return `{"status": "ERROR", "message": "<error>"}`
```

### Impact of Custom Agents

| Benefit | Mechanism | Estimated savings per 8-plan run |
|---------|-----------|----------------------------------|
| Threading rules always present | Implementer system prompt | 2 dispatches (no quality review fix cycle) |
| No-TODO rule always present | Implementer system prompt | 3-4 dispatches (no false DONE cycle) |
| Tool restrictions on reviewers | `tools` field — reviewers can't edit | Prevents a class of bugs |
| Model optimization | PR agent on haiku | ~40% cost reduction on PR dispatches |
| Turn limits | `maxTurns` field | Prevents runaway subagents |
| Auto-worktree on implementer | `isolation: worktree` in frontmatter | Simplifies orchestrator logic |
| Skills auto-injected | `skills` field | No prompt duplication |
| Orchestrator prompt shrinks ~60% | All of the above | Less context used per plan |

### How the Orchestrator Prompt Changes with Custom Agents

The per-plan loop simplifies dramatically:

```markdown
### Step 1 · Implement

Pre-dispatch sync (git fetch + reset --hard).
Dispatch with `subagent_type: "implementer"`:
  - Plan path
  - "Plan N of M"

### Step 2 · Spec Review

Dispatch with `subagent_type: "spec-reviewer"`:
  - Plan path
  - Commit SHAs
  - Worktree path

### Step 3 · Quality Review

Dispatch with `subagent_type: "quality-reviewer"`:
  - Commit SHAs
  - Worktree path

### Step 4 · PR

Dispatch with `subagent_type: "pr-agent"`:
  - Title and body
```

No inlined rules, return contracts, or methodology instructions — they live in the agent definitions.

---

## 7. Git State Management Tooling

### The Problem

The orchestrator must maintain a correct `dev` branch state between plan dispatches. When worktrees branch from stale state, subagents work with outdated code.

### Option A: `wtp` Package + `.wtp.yml`

`wtp` is a Go CLI tool for git worktree management. Install: `brew install satococoa/tap/wtp`.

Benefits:
- `.wtp.yml` post-create hooks can enforce sync invariants
- Tab completion for jumping between worktrees
- Atomic cleanup (removes worktree + branch in one command)

Limitation: Still depends on when `git fetch` is called.

### Option B: Wrapper Scripts (Recommended)

Custom scripts give exact guarantees without external dependencies:

**`scripts/create-worktree.sh`:**
```bash
#!/bin/bash
set -euo pipefail

BRANCH_NAME="${1:?Usage: create-worktree.sh <branch-name>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
WORKTREE_BASE="${REPO_ROOT}/.worktrees"
WORKTREE_PATH="${WORKTREE_BASE}/${BRANCH_NAME}"

# Sync to latest origin/dev (the critical invariant)
git fetch origin dev
DEV_SHA="$(git rev-parse origin/dev)"

# Create worktree from the exact SHA (not from HEAD)
mkdir -p "${WORKTREE_BASE}"
git worktree add -b "${BRANCH_NAME}" "${WORKTREE_PATH}" "${DEV_SHA}"

# Copy OpenCV symlink if it exists in main worktree
OPENCV_LINK="$(readlink "${REPO_ROOT}/packages/cambrian_camera/android/opencv" 2>/dev/null || true)"
if [ -n "${OPENCV_LINK}" ]; then
    ln -sf "${OPENCV_LINK}" "${WORKTREE_PATH}/packages/cambrian_camera/android/opencv"
fi

echo "WORKTREE_PATH=${WORKTREE_PATH}"
echo "WORKTREE_BRANCH=${BRANCH_NAME}"
echo "BASE_SHA=${DEV_SHA}"
```

**`scripts/remove-worktree.sh`:**
```bash
#!/bin/bash
set -euo pipefail

WORKTREE_PATH="${1:?Usage: remove-worktree.sh <worktree-path>}"
REPO_ROOT="$(git rev-parse --show-toplevel)"

cd "${REPO_ROOT}"
git worktree remove "${WORKTREE_PATH}" --force 2>/dev/null || true
git worktree prune
echo "Cleaned up: ${WORKTREE_PATH}"
```

**Why `origin/dev` directly?** The critical line is:
```bash
git worktree add -b <branch> <path> origin/dev
```

This branches from `origin/dev` directly, NOT from `HEAD`. This eliminates the entire class of stale-base bugs because the worktree's starting point is independent of the main worktree's current branch or HEAD state.

### Option C: `wtp-mcp` (MCP Server)

The `wtp-mcp` package (https://github.com/bnomei/wtp-mcp) exposes worktree operations as MCP tools. This would let the orchestrator call `create_worktree` / `remove_worktree` as native tool calls instead of shell commands. Worth evaluating but adds a third-party dependency.

### CLAUDE.md Addition for Scripts

```markdown
## Worktree Management

Always use the provided scripts for worktree lifecycle:
- `scripts/create-worktree.sh <branch>` — creates worktree from latest `origin/dev`
- `scripts/remove-worktree.sh <path>` — cleans up worktree and prunes

Never use `git worktree add` directly — the scripts enforce state-sync invariants.
```

---

## 8. Subagent Behavior Observations

This section captures how subagents actually behaved during the run — patterns
that emerged, what worked, what didn't, and what we learned about effective
subagent orchestration.

### 8.1 Subagents Optimize for Returning DONE

The strongest behavioral pattern: subagents treat `DONE` as the success state
and will fill gaps to reach it. When the Plan 6 implementer couldn't find
`gpuPipeline`, it didn't stop — it commented the calls out as TODOs and
returned `DONE_WITH_CONCERNS`. This is locally reasonable ("I did what I could")
but globally wrong ("the spec requires working code").

**Implication:** The return contract must define `DONE` negatively — "DONE does
NOT mean..." — in addition to positively. Without negative examples, subagents
will rationalize edge cases into the DONE bucket.

**What worked:** The `DONE_WITH_CONCERNS` status was valuable. It surfaced the
issue before review. Without it, the spec reviewer might have passed the
commented-out code. The concern text gave the orchestrator enough information
to investigate.

### 8.2 Subagents Are Literal About Code Samples

When the Plan 6 spec included a code sample for `pause()`:
```kotlin
if (isRecording) {
    gpuPipeline?.setEncoderSurface(null)
    try { videoRecorder?.stop() } catch (e: Exception) { ... }
}
```

The implementer treated this as the literal implementation — calling
`teardown()` directly on the caller's thread, exactly as shown. It did not
examine surrounding code to discover that every other teardown path posts to
`backgroundHandler`.

**Implication:** Code samples in plans are dangerous. They communicate intent
effectively but subagents copy them verbatim instead of adapting to codebase
patterns. Plans should either:
1. Include a note: "This is a sketch — match the threading pattern of
   `backgroundSuspend()` / `close()`"
2. Or omit code samples entirely and describe the behavior in prose

**What worked:** The code quality reviewer caught the threading mismatch. The
two-stage review process (spec then quality) proved its value here — spec
review asks "did you build what was requested?" while quality review asks
"did you build it correctly?"

### 8.3 Subagents Don't Search Broadly by Default

When the Plan 6 implementer couldn't find `gpuPipeline` in the immediate
context, it concluded the API didn't exist. It did not search the full file
(~1800 lines) or use grep. The fields were at lines 166 and 183 — the
implementer was working around line 508+.

**Implication:** Subagents need explicit instructions to search broadly before
concluding something doesn't exist. The instruction "grep -r across the full
packages/cambrian_camera/ tree" should be in CLAUDE.md or the agent definition.

### 8.4 The Stale-Worktree Trap

When the orchestrator dispatched a fix subagent into the same stale worktree to
address the Plan 6 implementer's concerns, the fix subagent made the same
observation: "these APIs don't exist." The orchestrator's instructions said
"these APIs DO exist" but the subagent's environment said otherwise.

**The subagent trusted its environment over the orchestrator's instructions.**
This is the correct behavior for an autonomous agent — but it means the
orchestrator must guarantee the environment is correct, not just assert it
in the prompt.

**Key insight:** Subagent claims about the codebase are observations about
their environment, not about the canonical project state. When a subagent
says "X doesn't exist," verify in the main worktree before accepting or
rejecting the claim.

### 8.5 Review Quality Varied by Complexity

| Plan | Spec review | Quality review | Notes |
|------|-------------|----------------|-------|
| 1 (4-line guard) | Trivial PASS | Trivial PASS | Could have been combined |
| 2 (restructure block) | Thorough PASS | Thorough PASS | Correctly verified gating logic |
| 3 (5 C++ changes) | Detailed PASS, checked all 5 | Detailed PASS, verified null safety | Justified separate reviews |
| 4 (replace lambdas) | Trivial PASS | Trivial PASS | Could have been combined |
| 5 (try/catch wrap) | Thorough PASS, noted ANativeWindow cleanup | Thorough PASS, verified JNI correctness | Quality reviewer added value |
| 6 (3 changes + threading) | FAIL → FAIL → PASS (3 rounds) | FAIL → PASS (2 rounds) | Both reviews caught real issues |
| 7 (2-line change) | Trivial PASS | Thorough PASS, verified thread safety | Quality reviewer added unexpected value |

**Pattern:** For Plans 1 and 4, two separate reviews were overkill — a combined
reviewer would have been sufficient. For Plans 3, 5, 6, and 7, the quality
reviewer found meaningful things the spec reviewer wouldn't have caught.

**Rule of thumb:** If the change is syntactic (add a guard, replace a string),
combine reviews. If the change is semantic (alter control flow, add a function,
touch threading), keep them separate.

### 8.6 Subagent Return Format Compliance

Plan 8's implementer returned "The working tree is clean — there are no changes
to commit" without the required JSON format. This required a follow-up subagent
just to get a proper status report.

**Implication:** The return contract should be reinforced with: "You MUST
return the JSON block even if you made no changes. Use status DONE with
empty commits array and explain in summary why no changes were needed."

### 8.7 Model Selection Observations

All subagents used `sonnet` during the v1 run. Observations on where different
models would be appropriate:

| Role | Appropriate model | Reasoning |
|------|-------------------|-----------|
| Implementer (trivial: <=5 lines) | sonnet | Even trivial changes need codebase awareness |
| Implementer (standard: multi-location) | sonnet | Needs to understand threading, patterns |
| Implementer (complex: new function + integration) | opus | Plan 6 would have benefited from opus-level reasoning |
| Spec reviewer | sonnet | Checklist comparison, doesn't need deep reasoning |
| Quality reviewer | sonnet | Needs pattern recognition but well-scoped |
| PR agent | haiku | Mechanical: push, create PR, merge. No reasoning needed |

**Estimated cost savings from model optimization:** Using haiku for PR agents
saves ~40% per PR dispatch. Over 7 PRs, this is meaningful. Using opus for
complex implementations may cost more per dispatch but save 3-4 fix dispatches.

### 8.8 What Subagents Did Well

Not everything failed. The clean plans (1-5, 7) demonstrate that the basic
pattern works when the environment is correct:

1. **Self-review caught issues.** The Plan 5 implementer noticed it needed to
   release the `ANativeWindow` reference on the exception path — a detail not
   in the plan spec. It added the cleanup proactively.

2. **Quality reviewers were thorough.** The Plan 5 quality reviewer verified
   no double-release across all three code paths (early exit, catch, success).
   The Plan 7 reviewer verified the `> 0L` guard removal was safe given the
   new seeding behavior.

3. **Spec reviewers caught real gaps.** The Plan 6 spec reviewer (iteration 2)
   caught that the KDoc fix was only applied to the new `pause()` overload,
   not the original `pause(callback)` at line 508.

4. **The DONE_WITH_CONCERNS escalation worked.** When it was used, it gave the
   orchestrator actionable information. The problem was in what happened AFTER
   the escalation (dispatching into the same stale worktree).

---

## 9. Context Architecture: What Goes Where

### 9.1 The Discovery: AGENTS.md Is Not Supported

Claude Code **does not read AGENTS.md files.** AGENTS.md is an OpenAI Codex/Agents
convention. Claude Code only reads CLAUDE.md files from:
- Project root
- Parent directories (up to git root or home directory)
- `~/.claude/CLAUDE.md` for global user instructions

If you use multiple AI coding tools (Copilot, Codex, Cursor, etc.), you can
maintain CLAUDE.md as the primary source of truth and symlink or generate
tool-specific files from it. The "Rules for AI Agents" content proposed in
section 5 is deliberately tool-agnostic.

### 9.2 How Context Flows to Subagents

Understanding what a subagent sees is critical for designing the context
architecture:

```text
Subagent context
  │
  ├── Custom agent system prompt (.claude/agents/<name>.md body)
  │   └── This is the ONLY system prompt the subagent gets.
  │       It does NOT inherit the full Claude Code system prompt.
  │
  ├── CLAUDE.md files (auto-loaded from project root + parents)
  │   └── Every subagent gets these automatically.
  │       This is the primary channel for project-wide knowledge.
  │
  ├── Skills (if specified in agent frontmatter `skills:` field)
  │   └── Injected into context at startup.
  │       Good for methodology (TDD) but adds context size.
  │
  ├── The orchestrator's dispatch prompt
  │   └── Task-specific: plan path, sequence position, commit SHAs.
  │       Should be minimal when custom agents handle the rest.
  │
  └── Files the subagent reads during execution
      └── The subagent's own exploration of the codebase.
          Depends on what it's told to read + what it discovers.
```

**Key insight:** CLAUDE.md is the only context channel that works for ALL
subagents WITHOUT orchestrator intervention. Everything in CLAUDE.md is
"free" — the orchestrator doesn't have to include it in every prompt.

### 9.3 The Four-Layer Architecture

Each layer has a distinct role. Mixing concerns across layers causes problems:

```text
┌─────────────────────────────────────────────────────────────────┐
│                    Orchestrator Prompt                          │
│  Workflow logic only: plan ordering, status handling,           │
│  git sync, review iteration caps, pre-flight triage             │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─          │
│  Does NOT contain: subagent instructions, project knowledge,    │
│  build commands, coding patterns                                │
├─────────────────────────────────────────────────────────────────┤
│                 Custom Agents (.claude/agents/)                  │
│  Role-specific: system prompts, tool restrictions,              │
│  model selection, return contracts, max turns                   │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─          │
│  Does NOT contain: project-specific knowledge                   │
│  (threading model, build commands) — that's in CLAUDE.md        │
├─────────────────────────────────────────────────────────────────┤
│                      CLAUDE.md                                   │
│  Project knowledge any contributor needs: threading model,      │
│  build commands, key APIs, coding conventions, doc pointers     │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─          │
│  Does NOT contain: workflow rules, return contracts,            │
│  orchestrator-specific logic                                    │
├─────────────────────────────────────────────────────────────────┤
│                    Scripts (scripts/)                            │
│  Repeatable operations with invariant guarantees:               │
│  worktree creation, cleanup, environment validation             │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─          │
│  Replaces: ad-hoc git commands in orchestrator prompt           │
└─────────────────────────────────────────────────────────────────┘
```

### 9.4 How v1 Violated This Architecture

In v1, the orchestrator prompt contained ALL four layers mixed together:

| Content | Should be in | Was in (v1) |
|---------|-------------|-------------|
| "Follow TDD methodology" | Agent definition (`skills:` field) | Orchestrator prompt |
| "Run `flutter build apk --debug`" | CLAUDE.md | Orchestrator prompt (repeated per dispatch) |
| "Return JSON with status/summary/commits" | Agent definition (return contract) | Orchestrator prompt (repeated per dispatch) |
| "No wildcard imports" | CLAUDE.md (already there) | Orchestrator prompt (duplicated) |
| "Read docs/architecture.md" | CLAUDE.md (living docs section) | Orchestrator prompt (repeated per dispatch) |
| "`git fetch origin dev && git reset --hard`" | Scripts | Orchestrator prompt (inline bash) |
| Plan ordering, status handling | Orchestrator prompt | Orchestrator prompt (correct) |

The result: the orchestrator prompt was ~150 lines and had to re-specify rules
in every dispatch. Missing one rule in one dispatch caused Plan 6's threading
bug.

### 9.5 What to Put in CLAUDE.md vs Agent Definitions

This decision matrix helps:

| Question | CLAUDE.md | Agent definition |
|----------|-----------|------------------|
| Would a human contributor need this? | Yes → CLAUDE.md | No |
| Is this specific to a role (implementer vs reviewer)? | No | Yes → agent def |
| Is this project-specific or methodology-specific? | Project → CLAUDE.md | Methodology → agent def |
| Does this change when the project changes? | Yes → CLAUDE.md | No |
| Does this change when the workflow changes? | No | Yes → agent def |

**Examples:**

| Content | Where | Why |
|---------|-------|-----|
| "backgroundHandler for Camera2 ops" | CLAUDE.md | Any contributor needs this |
| "Never use --release" | CLAUDE.md | Project policy for all contributors |
| "FAIL if code has TODOs" | Agent def (spec-reviewer) | Role-specific rubric |
| "Return JSON with status field" | Agent def (implementer) | Workflow contract |
| "Use haiku model" | Agent def (pr-agent) | Role-specific optimization |
| "Match 2-3 similar functions" | Both | CLAUDE.md as project guidance, agent def as enforcement |

### 9.6 CLAUDE.md as the "Day-One Onboarding Doc"

**Mental model:** CLAUDE.md is what you'd tell a new team member in their
first 10 minutes before they touch any code. If a subagent is that new team
member, what do they need?

1. How to build and verify (build commands, debug-only rule)
2. Where the important code lives (key files, key classes)
3. What patterns to follow (threading model, state notifications)
4. What to read first (architecture doc, usage guide)
5. What NOT to do (wildcard imports, TODOs, --release)

Everything else is either workflow (orchestrator prompt), role-specific (agent
definition), or derivable from reading the code.

### 9.7 Custom Agent Frontmatter Capabilities

The full set of frontmatter fields available in `.claude/agents/` definitions:

| Field | Type | Impact on orchestration |
|-------|------|------------------------|
| `name` | string (required) | Referenced by `subagent_type` in `Agent` tool |
| `description` | string (required) | Helps Claude decide when to delegate (can also be explicit) |
| `tools` | list | **Restrict tools per role.** Reviewers get Read/Grep/Bash only — can't edit. |
| `disallowedTools` | list | Alternative to `tools` — remove specific tools from full set |
| `model` | string | **Lock model per role.** PR agent → haiku, implementer → sonnet |
| `permissionMode` | string | `bypassPermissions` eliminates interactive prompts |
| `maxTurns` | int | **Prevent runaway subagents.** Implementer: 50, reviewer: 15, PR: 10 |
| `skills` | list | Auto-inject skills (e.g., `superpowers:test-driven-development`) |
| `isolation` | string | `worktree` auto-creates isolated worktree for the subagent |
| `mcpServers` | list | Scope MCP servers to specific agents |
| `hooks` | list | Lifecycle hooks scoped to the agent |
| `memory` | string | Persistent memory (`user`, `project`, or `local`) |
| `effort` | string | `low`, `medium`, `high`, `max` — controls reasoning depth |
| `color` | string | Visual identification in task list |

**Most impactful fields for orchestration:**
1. `tools` — prevents reviewers from editing files (safety)
2. `model` — cost optimization (haiku for PR agent saves ~40%)
3. `maxTurns` — prevents token burn on stuck subagents
4. `isolation: worktree` — auto-worktree without orchestrator managing it
5. `permissionMode: bypassPermissions` — no interactive prompts

### 9.8 Open Questions for Custom Agent Testing

Before building the full v3 orchestrator around custom agents, verify:

1. **Does `subagent_type: "implementer"` load `.claude/agents/implementer.md`?**
   The research says yes, but this needs empirical verification.

2. **Does `isolation: worktree` in the agent frontmatter interact correctly
   with the `isolation` parameter on the `Agent` tool?** If both are specified,
   which takes precedence? If only the frontmatter specifies it, does the
   worktree branch from `HEAD` (same stale-base risk) or can we control the
   base?

3. **Does CLAUDE.md load in the worktree context or the main worktree context?**
   If the worktree has a different CLAUDE.md (e.g., because it branched from
   an old commit before CLAUDE.md was updated), the subagent gets stale
   instructions. This is the CLAUDE.md analog of the stale-base bug.

4. **Can agent definitions reference project-relative paths?** E.g., can the
   implementer agent's `skills:` field reference a project-local skill?

5. **What happens when `maxTurns` is reached?** Does the subagent return
   whatever it has, or does it fail silently?

These questions should be answered with a small test before Phase 3 of the
implementation plan.

---

## 10. Implementation Plan

### Phase 1: Scripts (Low effort, high impact)
_Prerequisite: None_

1. Create `scripts/create-worktree.sh` and `scripts/remove-worktree.sh`
2. Add worktree management section to CLAUDE.md
3. Add `.worktrees/` to `.gitignore`

### Phase 2: CLAUDE.md Updates (Low effort, high impact)

1. Add threading model section
2. Add rules for AI agents section
3. Add build verification section
4. Add key internal APIs section
5. Revise living documents wording

### Phase 3: Custom Agent Definitions (Medium effort, highest impact)

1. Create `.claude/agents/implementer.md`
2. Create `.claude/agents/spec-reviewer.md`
3. Create `.claude/agents/quality-reviewer.md`
4. Create `.claude/agents/pr-agent.md`
5. Test each agent in isolation with a simple task
6. Update orchestrator prompt v2 to use `subagent_type` references

### Phase 4: Orchestrator Prompt v3 (Medium effort)

1. Rewrite orchestrator prompt to use custom agents (no inlined instructions)
2. Integrate `scripts/create-worktree.sh` into the workflow
3. Test with a small (2-3 plan) run
4. Iterate based on results

### Verification

After implementing all phases, run a test orchestration with 2-3 trivial plans to verify:
- [ ] Worktree scripts create worktrees from `origin/dev` correctly
- [ ] Custom agents load their system prompts
- [ ] `subagent_type: "implementer"` dispatches the custom agent
- [ ] Implementer follows threading rules without being told in the prompt
- [ ] Spec reviewer fails on TODO stubs
- [ ] Quality reviewer catches threading violations
- [ ] PR agent creates and merges PRs
- [ ] Orchestrator prompt is significantly shorter than v1

---

## 11. File Locations

### Existing artifacts (in Downloads, to be moved)

| File | Move to |
|------|---------|
| `~/Downloads/orchestrator-prompt-v2.md` | Project-specific location TBD |
| `~/Downloads/orchestrator-prompt-v2-rationale.md` | `docs/` or alongside prompt |
| `~/Downloads/claude-md-subagent-additions.md` | Apply changes to CLAUDE.md, then delete |

### Files to create

| File | Purpose |
|------|---------|
| `scripts/create-worktree.sh` | Worktree creation with sync invariant |
| `scripts/remove-worktree.sh` | Worktree cleanup |
| `.claude/agents/implementer.md` | Custom implementer agent |
| `.claude/agents/spec-reviewer.md` | Custom spec reviewer agent |
| `.claude/agents/quality-reviewer.md` | Custom quality reviewer agent |
| `.claude/agents/pr-agent.md` | Custom PR agent |

### Files to modify

| File | Changes |
|------|---------|
| `CLAUDE.md` | Add threading model, agent rules, build verification, key APIs, revise living docs |
| `.gitignore` | Add `.worktrees/` |

---

## 12. Meta-Lessons

### For future agents picking up this work

1. **Start with Phase 1 (scripts) and Phase 2 (CLAUDE.md).** These are low-risk,
   immediate-impact changes that don't require testing custom agent behavior.
   You can validate them by running a single plan through the v2 orchestrator.

2. **Phase 3 (custom agents) needs empirical testing.** The `subagent_type`
   integration with custom agent definitions should be verified with a simple
   test before building the full orchestrator prompt around it. Create one
   agent (e.g., `pr-agent` — simplest role), test it manually, then build
   the others. See section 9.8 for specific questions to answer.

3. **The orchestrator prompt is a program.** Treat it like code: test it,
   version it, and fix bugs. Every "convenience" like `git pull` or "handle
   at your discretion" is a potential runtime bug. The v1→v2 diff is a
   bugfix release, not a rewrite.

4. **State management > prompt engineering.** The fanciest subagent prompt
   can't compensate for dispatching into a stale environment. The pre-dispatch
   sync invariant and worktree scripts are more valuable than any prompt
   improvement. This was the #1 lesson from the run.

5. **Triage before execution saves more than optimization during execution.**
   Detecting Plan 8 as a no-op upfront (2 agents saved) is worth more than
   making any single agent 20% faster.

6. **Subagents trust their environment over your instructions.** If the
   orchestrator says "this API exists" but the worktree doesn't have it,
   the subagent will believe the worktree. Fix the environment, not the
   prompt.

7. **Two-stage review earns its cost on complex changes.** For Plans 3, 5, 6,
   and 7, the quality reviewer caught issues the spec reviewer wouldn't have
   found. For Plans 1 and 4, it was overkill. Scale review depth to change
   complexity.

8. **Code samples in plans are a double-edged sword.** They communicate intent
   clearly but subagents copy them literally. Either annotate samples with
   "this is a sketch — match surrounding patterns" or describe behavior in
   prose and let the subagent write the code.

9. **CLAUDE.md is the highest-leverage context channel.** Every subagent gets
   it automatically, the orchestrator doesn't have to include it per-dispatch,
   and it benefits human contributors too. Invest in CLAUDE.md quality before
   optimizing orchestrator prompts.

### Separation of concerns (summary)

| Layer | What belongs there | Does NOT belong |
|-------|-------------------|-----------------|
| CLAUDE.md | Project knowledge any contributor needs | Workflow rules, return contracts |
| Custom agents (`.claude/agents/`) | Role-specific instructions, tool restrictions, model selection | Project-specific knowledge |
| Orchestrator prompt | Workflow logic (plan ordering, status handling, git sync) | Subagent instructions, project knowledge |
| Scripts (`scripts/`) | Repeatable operations with invariant guarantees | Business logic, workflow decisions |

### How to validate improvements

After implementing changes from this analysis, run a 2-3 plan test with these
success criteria:

1. **No stale-base bugs:** Every worktree starts from current `origin/dev`
2. **No TODO stubs:** Implementers either use real APIs or report NEEDS_CONTEXT
3. **Orchestrator prompt < 80 lines:** Custom agents handle role instructions
4. **Total agents per clean plan = 4:** Implementer + spec + quality + PR
5. **Total agents per trivial plan = 3:** Implementer + combined review + PR
6. **No `git pull` errors:** All syncs use fetch + reset --hard
