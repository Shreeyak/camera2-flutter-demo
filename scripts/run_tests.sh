#!/usr/bin/env bash
# run_tests.sh
#
# Builds the debug APK, installs it, grants camera permission, then runs
# integration tests. This avoids the runtime permission dialog that appears
# when flutter test reinstalls the APK and resets permissions.
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

echo ""
echo "Building debug APK..."
flutter build apk --debug

APK="build/app/outputs/flutter-apk/app-debug.apk"

# ── Install APK ───────────────────────────────────────────────────────────────

echo "Installing APK (with -g to auto-grant all runtime permissions)..."
# -g grants all runtime permissions at install time, avoiding mid-test dialogs.
# Works on Android 6+ and does not require elevated ADB privileges.
$ADB install -r -g "$APK"

# ── Run tests (skip reinstall via --use-application-binary) ──────────────────

echo ""
echo "Running tests: $TEST_TARGET"
echo "────────────────────────────────────────────"
# flutter test preserves runtime permissions when reinstalling with the same
# debug signing key (adb install -r keeps granted permissions). The -g install
# above ensures permissions are granted on a truly fresh install.
flutter test "$TEST_TARGET" --device-id "$DEVICE"
