# Spec: Living Coding Guidelines System

## Context

Analysis of 15 Claude Code sessions (143 commits, 13 PRs) revealed recurring mistake patterns: over-engineering (5x), data flow confusion (4x), thread safety gaps (6x), type safety at boundaries (3x). These patterns repeat across sessions because there's no feedback loop — mistakes aren't captured in a form that prevents recurrence.

This system creates a **living guidelines document** that grows automatically from PR analysis and conversation analysis, reviewed by the developer before entries are committed.

**Goal:** Reduce recurring mistakes by feeding lessons learned back into the coding workflow.

---

## File Structure

```
docs/coding-guidelines.md          <- living doc, machine-optimized, referenced by CLAUDE.md
docs/guidelines-pending.md         <- staging file for unapproved entries
docs/conversation-analysis-*.md    <- one-time analysis snapshots (already exists)
```

`CLAUDE.md` gets one line:
```markdown
- **Coding guidelines**: `docs/coding-guidelines.md` — read before implementation tasks.
```

---

## Guidelines Doc Format

```markdown
# Coding Guidelines
<!-- Machine-optimized. Read by Claude Code at session start via CLAUDE.md reference. -->
<!-- Updated incrementally via /reflect and daily session-start analysis. -->

## Meta
- Last updated: 2026-04-06
- Entry count: 14

---

## Pipeline & Data Flow
<!-- Trigger: modifying GPU/CPU pipeline, buffer handling, surfaces, rendering -->

### G-PIP-01: Trace full data path before modifying pipelines
- **Rule:** Map source -> processing -> destination before coding. Any CPU copy in the GPU path is suspicious.
- **Why:** 4 instances of proposing CPU intermediates where direct GPU surface reads were correct.
- **Source:** conversation-analysis-2026-04-06

### G-PIP-02: Synchronize and timeout at every boundary
- **Rule:** At Dart/Kotlin, Kotlin/C++, GL/background thread boundaries: verify lock, timeout, dead-side handling.
- **Why:** 6 thread-safety bugs at async/platform boundaries.
- **Source:** PR #9, #11, #13

---

## API Design
<!-- Trigger: Pigeon interfaces, return types, public Dart API -->

### G-API-01: Typed data classes across Pigeon, never strings
- **Rule:** Never encode structured data as delimited strings across Pigeon. Use typed data classes.
- **Why:** Pipe-delimited strings caused parsing bugs and lost compile-time safety.
- **Source:** PR #13

---

## Scope & Complexity
<!-- Trigger: any implementation task -->

### G-SCP-01: Simplest implementation first
- **Rule:** Don't add options, configurability, or abstractions unless asked. If adding a parameter the user didn't request, stop.
- **Why:** 5 instances of over-engineering rejected by user. KISS is a core value.
- **Source:** conversation-analysis-2026-04-06

---

## Resource Lifecycle
<!-- Trigger: streams, subscriptions, camera state, dispose -->

### G-RES-01: Every stream.listen() needs onError and cancellation
- **Rule:** Every stream subscription must have an onError handler. Every subscription cancelled in dispose(). No exceptions.
- **Why:** 5 stream lifecycle bugs found — missing handlers caused crashes on error events.
- **Source:** PR #11, #13

---

## Documentation
<!-- Trigger: changing public API, enums, architecture -->

### G-DOC-01: Update docs in same commit as API changes
- **Rule:** When changing a public API or enum, grep for references in docs/ and comments. Update in same commit.
- **Why:** 4 instances of stale comments referencing old enum values or removed methods.
- **Source:** PR #9, #13
```

### Format Design Choices

| Element | Purpose |
|---|---|
| `G-PIP-01` IDs | Stable references for reviews and conversations |
| `<!-- Trigger -->` comments | LLM matches current task to relevant section |
| `Why` field | LLM judges edge cases, not blind rule-following |
| `Source` field | Traceability — retire entries when source is outdated |
| `Meta.entry_count` | Quick staleness indicator |

---

## Staging File Format

`docs/guidelines-pending.md`:

```markdown
# Pending Guideline Entries
<!-- Auto-generated. Review with /review-guidelines. -->

## Pending (2026-04-06, from: PR #14 review)

### Proposed: G-PIP-03: Validate surface dimensions before binding
- **Rule:** Check width/height > 0 and match expected aspect ratio before passing Surface to Camera2.
- **Why:** PR #14 review found crash when surface was bound with 0x0 dimensions after config change.
- **Confidence:** High (appeared in 2 separate reviews)
- **Action:** [ ] Approve  [ ] Reject  [ ] Modify

---

## Pending (2026-04-06, from: session analysis)

### Proposed: G-SCP-02: Don't refactor surrounding code during bug fixes
...
```

---

## Triggers

### 1. Daily Session-Start Check (automatic)

**When:** First Claude Code session of each day (check timestamp file `docs/.guidelines-last-check`).

**What it does:**
1. Run `gh pr list --state merged --search "merged:>LAST_CHECK_DATE"` to find new merged PRs
2. Find unanalyzed conversation `.jsonl` files (newer than last check)
3. If new material found:
   a. Analyze PR diffs + review comments for patterns
   b. Analyze conversation logs for corrections, pivots, mistakes
   c. Compare findings against existing `docs/coding-guidelines.md` — skip duplicates
   d. Write new entries to `docs/guidelines-pending.md`
   e. Update `docs/.guidelines-last-check` timestamp
4. Print one-liner notification: *"N new guideline entries pending. Run /review-guidelines when ready."*
5. If nothing new: silent, no output

**Implementation:** Claude Code session-start hook that runs a subagent with read access to PR data and conversation logs.

### 2. `/reflect` Slash Command (manual, on-demand)

**Usage:**
- `/reflect` — analyze current session's conversation for decisions and mistakes
- `/reflect --review 14` — analyze PR #14's review comments
- `/reflect --last-session` — analyze the previous completed session's .jsonl

**What it does:**
1. Read the specified source material
2. Extract: corrections made, decisions taken, mistakes caught, patterns
3. Compare against existing guidelines — skip duplicates
4. Write new entries to `docs/guidelines-pending.md`
5. Print summary of what was found and staged

### 3. `/review-guidelines` Command (approval flow)

**What it does:**
1. Read `docs/guidelines-pending.md`
2. Present each pending entry one at a time
3. For each entry, user chooses: Approve / Reject / Modify
4. Approved entries appended to `docs/coding-guidelines.md` with next available ID
5. Rejected entries deleted
6. Modified entries updated then appended
7. Clear processed entries from pending file
8. Update `Meta.last_updated` and `Meta.entry_count`

---

## Analysis Logic (shared by all triggers)

The analyzer (subagent) follows this process:

1. **Extract signals** from source material:
   - User corrections: "no", "not that", "too complicated", "just the..."
   - Pivots: approach changed mid-session
   - Repeated patterns: same type of issue appearing 2+ times
   - PR review comments: what the reviewer flagged

2. **Classify** each signal into a category:
   - Pipeline / data flow
   - API design
   - Scope / complexity
   - Resource lifecycle
   - Documentation
   - Thread safety
   - (New categories created if none fit)

3. **Deduplicate** against existing `docs/coding-guidelines.md`:
   - If an existing guideline covers the finding -> skip
   - If an existing guideline is related but this is a new nuance -> propose as refinement

4. **Assign confidence:**
   - High: appeared 2+ times across sessions/PRs
   - Medium: appeared once but clearly actionable
   - Low: ambiguous or context-dependent

5. **Write** to `docs/guidelines-pending.md` with proposed ID, category, rule, why, source, confidence

---

## Seeding the Initial Guidelines

The initial `docs/coding-guidelines.md` is seeded from the existing analysis at `docs/conversation-analysis-2026-04-06.md`. The 8 patterns and top 5 guidelines already identified become the first entries (G-PIP-01 through G-DOC-01 as shown in the format section above).

---

## Verification

1. Create `docs/coding-guidelines.md` with initial seed entries
2. Add reference line to `CLAUDE.md`
3. Create `docs/guidelines-pending.md` (empty template)
4. Test `/reflect` on a past session — verify entries appear in pending file
5. Test `/review-guidelines` — approve one entry, reject another, verify guidelines doc updates
6. Test daily check — verify it detects a recent merged PR and stages entries
7. Start a new session — verify the one-liner notification appears when pending entries exist
