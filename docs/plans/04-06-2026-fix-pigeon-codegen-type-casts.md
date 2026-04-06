# Plan: Fix Pigeon Codegen Type-Cast Bug

## Context

### What is Pigeon?

Pigeon is Flutter's official code generator for type-safe platform channels. Our plugin
defines the Dart ↔ native API in `packages/cambrian_camera/pigeons/camera_api.dart`, and
running `dart run pigeon` generates three files:

- `lib/src/messages.g.dart` (Dart)
- `android/src/main/kotlin/com/cambrian/camera/Messages.g.kt` (Kotlin)
- `ios/Classes/Messages.g.swift` (Swift)

These generated files handle serialization/deserialization of method calls and callbacks
between Dart and native code.

### What is the bug?

Pigeon v22.7.4 (and **all versions through the latest v26.3.3**) generates incorrect type
casts in the callback error-parsing code. Two specific problems:

**Swift — `PigeonError.details` narrowed from `Any?` to `String?`:**
```swift
// PigeonError declares: details: Any?
// But generated decoding code does:
let details: String? = nilOrValue(listResponse[2])  // WRONG: forces Any? → String?
```
If the Dart side sends non-string details (e.g., a Map), this crashes at runtime.

**Kotlin — `FlutterError.message` cast as non-nullable:**
```kotlin
// FlutterError declares: message: String? = null
// But generated callback parsing does:
FlutterError(it[0] as String, it[1] as String, it[2] as String?)
//                                    ^^^^^^^^ WRONG: should be String?
```
If the Dart side sends a null message, this throws a ClassCastException.

### Why does it keep coming back?

This bug has been flagged in **6 of 13 PRs** (#2, #4, #6, #9, #12, #13). Each time, a
reviewer catches it, a developer manually edits the generated `.g.swift` / `.g.kt` files
to fix the casts, and the fix holds until the next PR that modifies `camera_api.dart` and
re-runs `dart run pigeon` — which regenerates the files with the same bugs.

The doom loop:

```text
① dart run pigeon ──► generates buggy casts (Pigeon template bug)
       │
② Code review catches it ──► developer manually fixes .g.swift / .g.kt
       │
③ Next PR changes camera_api.dart ──► runs dart run pigeon again
       │
④ Overwrites manual fixes ──► back to ①
```

**You cannot sustainably fix generated code by editing the output.** The fix gets
overwritten every time the generator runs.

### Why not upgrade/downgrade Pigeon?

The bug exists in the Pigeon code generator source itself (`swift_generator.dart:1812`,
`kotlin_generator.dart:1790`). It has not been fixed in any released version. Upgrading
to v26.3.3 would not fix it and would introduce a breaking `Sendable?` change in Swift.
There is a related open issue (flutter/flutter#116999, P2) but no targeted fix.

### What does this plan do?

Create a single wrapper script that replaces raw `dart run pigeon` usage. The script:
1. Runs Pigeon codegen
2. Patches the two known-bad type casts via `sed`
3. Verifies the patches took effect (fails if bad patterns still present)

Plus update CLAUDE.md so that Claude (and any developer) knows to use the script.

---

## Implementation

### Step 1: Create `scripts/regenerate_pigeon.sh`

Location: `scripts/regenerate_pigeon.sh` (new file, executable)

```bash
#!/usr/bin/env bash
set -euo pipefail

# --- Context for future maintainers ---
# Pigeon (Flutter's platform channel codegen) has a bug in ALL versions through
# v26.3.3 where it generates incorrect type casts in callback error parsing:
#
#   Swift:  PigeonError.details decoded as String? instead of Any?
#   Kotlin: FlutterError.message cast as String instead of String?
#
# This script wraps `dart run pigeon` and patches the generated output.
# See: docs/plans/04-06-2026-fix-pigeon-codegen-type-casts.md
# See: docs/code-review-patterns.md, Pattern #7
# Related upstream: https://github.com/flutter/flutter/issues/116999
```

The script should:

1. **`cd` to the plugin package directory** (`packages/cambrian_camera`)
2. **Run Pigeon:**
   ```bash
   dart run pigeon --input pigeons/camera_api.dart
   ```
   Exit immediately if Pigeon fails.

3. **Patch Swift** (`ios/Classes/Messages.g.swift`):
   - Replace `let details: String? = nilOrValue(listResponse[2])` with
     `let details: Any? = listResponse[2]`
   - Print count of replacements

4. **Patch Kotlin** (`android/src/main/kotlin/com/cambrian/camera/Messages.g.kt`):
   - In FlutterError constructor calls within callback parsers, replace
     `it[1] as String,` with `it[1] as String?,`
   - Be careful to only match the callback error paths (lines containing `FlutterError`),
     not other legitimate non-nullable String casts
   - Print count of replacements

5. **Verify** — grep for the bad patterns. If any remain, print an error and exit 1:
   ```
   ERROR: Generated files still contain known-bad type casts after patching.
   Swift:  <count> remaining 'details: String?' violations
   Kotlin: <count> remaining non-nullable message casts
   ```

6. **Success message:**
   ```
   Pigeon codegen complete. Patched <N> Swift + <M> Kotlin type cast bugs.
   ```

### Step 2: Update CLAUDE.md

Add to the **Important Notes** section:

```markdown
## Pigeon Codegen

Pigeon (Flutter's platform channel code generator) has a known bug in all versions
through v26.3.3 that generates incorrect type casts in callback error parsing.
**Never run `dart run pigeon` directly.** Always use:

    scripts/regenerate_pigeon.sh

This script runs Pigeon and patches the generated output. See
`docs/plans/04-06-2026-fix-pigeon-codegen-type-casts.md` for full context.
```

### Step 3 (optional): File upstream bug report

File a focused issue on `flutter/flutter` with the `p: pigeon` label documenting:
- The two specific incorrect casts
- The generator source lines (`swift_generator.dart:1812`, `kotlin_generator.dart:1790`)
- A minimal reproduction
- Link to flutter/flutter#116999 as related

This is optional and does not block the script work.

---

## Verification

After implementation, verify the script works end-to-end:

1. Run `scripts/regenerate_pigeon.sh` — should succeed with patch counts
2. Check `Messages.g.swift` — `details` should be `Any?` in all callback error paths
3. Check `Messages.g.kt` — `message` should be `String?` in all FlutterError constructors
4. Run raw `dart run pigeon` manually — then run the script's verify step to confirm
   it detects the bad patterns (i.e., the lint catches unpatched files)

---

## Files Changed

| File | Action |
|------|--------|
| `scripts/regenerate_pigeon.sh` | New — wrapper script |
| `CLAUDE.md` | Update — add Pigeon codegen section |
| `docs/plans/04-06-2026-fix-pigeon-codegen-type-casts.md` | New — this plan |
