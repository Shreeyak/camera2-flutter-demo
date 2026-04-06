#!/usr/bin/env bash
set -euo pipefail

# Context for future maintainers:
# Pigeon (Flutter's platform channel codegen) has a bug in ALL versions through
# v26.3.3 where it generates incorrect type casts in callback error parsing:
#
#   Swift:  PigeonError.details decoded as String? instead of Any?
#   Kotlin: FlutterError.message cast as String instead of String?
#
# This script wraps `dart run pigeon` and patches the generated output.
# See: docs/plans/04-06-2026-fix-pigeon-codegen-type-casts.md
# Related upstream: https://github.com/flutter/flutter/issues/116999

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_DIR="$REPO_ROOT/packages/cambrian_camera"

SWIFT_FILE="$PKG_DIR/ios/Classes/Messages.g.swift"
KOTLIN_FILE="$PKG_DIR/android/src/main/kotlin/com/cambrian/camera/Messages.g.kt"

# Step 1: Run Pigeon
echo "Running dart run pigeon..."
cd "$PKG_DIR"
dart run pigeon --input pigeons/camera_api.dart
echo "Pigeon codegen complete."
echo ""

# Verify generated files exist
if [ ! -f "$SWIFT_FILE" ]; then
    echo "ERROR: Expected Swift file not found: $SWIFT_FILE"
    exit 1
fi
if [ ! -f "$KOTLIN_FILE" ]; then
    echo "ERROR: Expected Kotlin file not found: $KOTLIN_FILE"
    exit 1
fi

# Step 2: Patch Swift — details: String? -> Any?
# Pigeon generates: let details: String? = nilOrValue(listResponse[2])
# Correct form:     let details: Any? = listResponse[2]
echo "Patching Swift type casts..."
SWIFT_COUNT=$(grep -c 'let details: String? = nilOrValue(listResponse\[2\])' "$SWIFT_FILE" || true)
if [ "$SWIFT_COUNT" -gt 0 ]; then
    perl -i -pe 's/let details: String\? = nilOrValue\(listResponse\[2\]\)/let details: Any? = listResponse[2]/g' "$SWIFT_FILE"
    echo "  Patched $SWIFT_COUNT Swift occurrence(s)."
else
    echo "  No Swift occurrences found (may already be correct or pattern changed)."
fi

# Step 3: Patch Kotlin — it[1] as String, -> it[1] as String?,
# Only matches FlutterError constructor lines in callback error paths.
echo "Patching Kotlin type casts..."
KOTLIN_COUNT=$(grep -c 'FlutterError.*it\[1\] as String,' "$KOTLIN_FILE" || true)
if [ "$KOTLIN_COUNT" -gt 0 ]; then
    perl -i -pe 's/(FlutterError\([^)]*it\[1\] as )String,/$1String?,/g' "$KOTLIN_FILE"
    echo "  Patched $KOTLIN_COUNT Kotlin occurrence(s)."
else
    echo "  No Kotlin occurrences found (may already be correct or pattern changed)."
fi

echo ""

# Step 4: Verify — fail if bad patterns remain
SWIFT_REMAINING=$(grep -c 'let details: String? = nilOrValue(listResponse\[2\])' "$SWIFT_FILE" || true)
KOTLIN_REMAINING=$(grep -c 'FlutterError.*it\[1\] as String,' "$KOTLIN_FILE" || true)

if [ "$SWIFT_REMAINING" -gt 0 ] || [ "$KOTLIN_REMAINING" -gt 0 ]; then
    echo "ERROR: Generated files still contain known-bad type casts after patching."
    echo "  Swift:  $SWIFT_REMAINING remaining 'details: String?' violations"
    echo "  Kotlin: $KOTLIN_REMAINING remaining non-nullable message casts"
    exit 1
fi

echo "Pigeon codegen complete. Patched $SWIFT_COUNT Swift + $KOTLIN_COUNT Kotlin type cast bugs."
