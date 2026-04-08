#!/usr/bin/env bash
# run_tests.sh
#
# Builds the debug APK, grants camera permission, then runs integration tests.
#
# The app is compiled with --dart-define=RUNNING_TESTS=true so it never shows
# the system permission dialog. Permissions must be pre-granted here before the
# app launches — if they aren't, the camera won't open and tests will fail.
#
# Usage:
#   ./scripts/run_tests.sh [device-id] [test-file]
#
# Examples:
#   ./scripts/run_tests.sh
#   ./scripts/run_tests.sh 192.168.1.19:35025
#   ./scripts/run_tests.sh 192.168.1.19:35025 integration_test/app_test.dart

set -euo pipefail

PACKAGE="com.example.camera2_flutter_demo"
DEVICE="${1:-}"
TEST_TARGET="${2:-integration_test/}"
DART_DEFINES="--dart-define=RUNNING_TESTS=true"

# ── Resolve device ────────────────────────────────────────────────────────────

if [[ -z "$DEVICE" ]]; then
  DEVICE=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
  if [[ -z "$DEVICE" ]]; then
    echo "ERROR: No ADB device found. Connect a device or pass a device-id."
    exit 1
  fi
fi

echo "Device: $DEVICE"
ADB="adb -s $DEVICE"

# ── Wake and unlock ───────────────────────────────────────────────────────────

echo "Waking device..."
"$(dirname "$0")/wake_and_launch.sh" "$DEVICE" 2>/dev/null || true

# ── Build APK ─────────────────────────────────────────────────────────────────
# Built with RUNNING_TESTS=true so the app never shows the permission dialog.
# Permissions are granted at install time below instead.

echo ""
echo "Building debug APK (RUNNING_TESTS=true)..."
flutter build apk --debug $DART_DEFINES

APK="build/app/outputs/flutter-apk/app-debug.apk"

# ── Grant Permissions ─────────────────────────────────────────────────────────
# Install with -g to auto-grant ALL runtime permissions at install time.
# This is the ONLY place permissions are granted — the app will not show any
# permission dialog because it is compiled with RUNNING_TESTS=true.
#
# -r  replace existing install (preserves data)
# -g  grant all runtime permissions declared in AndroidManifest.xml
#
# Works on Android 6+ including Android 16. Does not require root.

echo ""
echo "Installing APK + granting runtime permissions (adb install -r -g)..."
$ADB install -r -g "$APK"

echo "Permissions granted for: $PACKAGE"

# ── Run Tests ─────────────────────────────────────────────────────────────────

echo ""
echo "Running tests: $TEST_TARGET"
echo "────────────────────────────────────────────"
flutter test "$TEST_TARGET" --device-id "$DEVICE" $DART_DEFINES
