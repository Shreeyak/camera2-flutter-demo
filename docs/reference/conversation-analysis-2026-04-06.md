# Conversation Analysis: 15 Claude Code Sessions

**Date:** 2026-04-06
**Scope:** 15 most recent sessions across main, feature/gpu-shader, feature/video-record, crash-fix branches
**Total messages analyzed:** ~3,500+

---

## Recurring Mistake Patterns

### 1. Over-Engineering (5 instances across 3 sessions)

Claude proposes complex solutions when simpler ones suffice. User repeatedly redirects toward simplicity.

- **Video record session:** User said "no, this is too complicated. Keep it as auto."
- **Hook design session:** User rejected per-edit verification hooks as "too much" and asked for a better design.
- **GPU shader session:** Claude treated all 30 code review comments as blocking; user said "fix major/critical bugs only."

**Guideline:** Default to the simplest implementation. If you're adding configurability, ask first. If the user hasn't asked for options, don't provide them.

### 2. Data Flow / Buffer Ownership Confusion (4 instances across 2 sessions)

Claude repeatedly misunderstood GPU-to-CPU data paths, proposing CPU intermediate buffers when direct GPU surface reads were correct.

- **Video record rebase:** User corrected "Recorder should take frames directly from the GPU" — Claude was proposing PBO/CPU intermediate.
- **GPU shader review:** Cascading CPU pipeline removals weren't immediately obvious after GPU took over color transforms.

**Guideline:** When modifying the rendering pipeline, trace the full data path (source surface -> processing -> destination) before proposing changes. Ask "does this add a CPU copy?" — if yes, it's probably wrong.

### 3. Thread Safety / Concurrency Gaps (6 instances across 3 sessions)

Code review found thread safety issues repeatedly at async/platform boundaries.

- Shared native state accessed without synchronization
- GPU surface rebinding timing issues
- No timeouts on blocking operations (`drainThread.join()` with no timeout)

**Guideline:** At every language/thread boundary (Dart->Kotlin, Kotlin->C++, GL thread->background thread), verify: Is access synchronized? Is there a timeout? What happens if the other side is dead?

### 4. Type Safety at Language Boundaries (3 instances across 2 sessions)

Opaque pipe-delimited strings used instead of typed returns across Pigeon boundary.

- Video recording returned `"path|duration|size"` string — replaced with typed `RecordingResult` data class.
- Null safety gaps at Dart/Kotlin boundary.

**Guideline:** Never encode structured data as delimited strings across the Pigeon boundary. Always use typed Pigeon data classes. If you see a string return that contains `|` or needs parsing, it's a code smell.

### 5. Scope Creep (3 instances across 2 sessions)

Claude proposes broad refactors when user wants targeted changes.

- **Crash fix session:** User said "no, just the uncommitted change in that file" when Claude proposed wider changes.
- **GPU shader session:** User had to explicitly narrow scope to blocking issues only.

**Guideline:** Match the scope of your change to what was asked. A bug fix is not an invitation to refactor surrounding code. Ask before expanding scope.

### 6. Stream / Resource Lifecycle (5 instances across 2 sessions)

Stream subscriptions not closed properly. Missing `onError` handlers on streams.

- Streams without `onError` would crash on error events.
- Widget disposal didn't cancel all subscriptions.

**Guideline:** Every `stream.listen()` must have an `onError` handler. Every subscription must be cancelled in `dispose()`. No exceptions.

### 7. Documentation Drift (4 instances across 3 sessions)

Docs and code get out of sync after architectural changes. Stale comments reference old enum values.

- Comments described old behavior after code changed.
- Duplicate documentation files created in parallel sessions.

**Guideline:** When changing a public API or enum, grep for references in docs/ and comments. Update them in the same commit.

### 8. Incorrect Assertions About Tools/Environment (2 instances)

Claude fabricated CLI UI features that don't exist (e.g., "press right arrow to expand tool result").

**Guideline:** Don't guess about tool capabilities. If uncertain, say so.

---

## Architectural Decisions Made

| Decision | Session | Rationale |
|----------|---------|-----------|
| Add `PAUSED` state to camera state machine | Camera2 design | Distinguish pause (resources released, instance alive) from close (instance dead). Faster app resume. |
| GPU-first processing model | GPU shader | GPU shaders handle all color transforms. CPU receives post-processed frames only. Legacy CPU pipeline stripped. |
| Direct GPU surface for video recording | Video record rebase | Recorder reads GPU surface directly, no CPU intermediate (PBO avoided for performance). |
| 3-phase execution: Observability -> Stability -> Features | Task planning | Logging first ("can't debug what you can't see"), then lifecycle fixes, then new features. |
| Typed returns over string encoding | Video record code review | Replace pipe-delimited strings with Pigeon data classes for compile-time safety. |
| Living document policy | Architecture session | CLAUDE.md and docs/architecture.md must update when system architecture changes. |
| Reject per-edit verification hooks | Architecture session | Too expensive to run after every edit. Seeking lighter-weight alternative. |
| ASCII diagrams in chat, Mermaid for docs | Video record rebase | Different audiences need different formats. |
| User-supplied processing callback for CPU | GPU shader | Replace removed CPU color pipeline with extensible hook for custom processing. |

---

## User Feedback Patterns (How the User Works)

1. **Prefers simplicity** — repeatedly narrows scope and rejects complexity. KISS is a core value.
2. **Focuses on single-file changes** — doesn't want broad refactors unless explicitly requested.
3. **Filters aggressively** — code review: only blocking issues. Tasks: only actionable items.
4. **Asks "why" questions** — wants to understand rationale before accepting changes (e.g., "Why is InputRing being removed? What replaces it?").
5. **Corrects gently** — rarely says "that's wrong", more often redirects with "no, just..." or "keep it as...".
6. **Values ASCII diagrams in conversation** — prefers readability over rendering.

---

## Mistake Frequency by Category

| Category | Count | Severity |
|----------|-------|----------|
| Over-engineering | 5 | Medium — wastes time, needs rework |
| Data flow confusion | 4 | High — leads to wrong architecture |
| Thread safety gaps | 6 | Critical — causes crashes |
| Type safety at boundaries | 3 | High — causes runtime errors |
| Scope creep | 3 | Medium — wastes time |
| Stream lifecycle | 5 | High — causes crashes |
| Documentation drift | 4 | Low — causes confusion |
| Tool/environment assertions | 2 | Low — causes confusion |

---

## Top 5 Guidelines (Highest Impact)

1. **Simplest implementation first.** Don't add options, configurability, or abstractions unless asked. If you're about to add a parameter the user didn't request, stop.

2. **Trace the full data path before modifying pipelines.** GPU surface -> processing -> destination. Any CPU copy is suspicious. Draw the path (ASCII) before coding.

3. **Synchronize and timeout at every boundary.** Dart/Kotlin, Kotlin/C++, GL thread/background thread. No blocking call without a timeout. No shared state without a lock.

4. **Typed data classes across Pigeon, never strings.** If a return value needs parsing, refactor to a data class.

5. **Match scope to request.** Bug fix = fix the bug. Don't refactor, don't add tests for unrelated code, don't update docs that aren't affected.
