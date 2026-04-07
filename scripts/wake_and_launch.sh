#!/usr/bin/env bash
# wake_and_launch.sh
#
# Ensures the Android device screen is on and unlocked, then launches the app.
#
# Usage:
#   ./scripts/wake_and_launch.sh [device-id]
#
# If no device-id is given, uses the first connected device.
# Assumes the lock screen has no PIN/pattern (swipe-to-unlock only).

set -euo pipefail

PACKAGE="com.example.camera2_flutter_demo"
ACTIVITY=".MainActivity"

# ── Device selection ──────────────────────────────────────────────────────────

ADB="adb"
if [[ -n "${1:-}" ]]; then
  ADB="adb -s $1"
fi

# ── Check screen state ────────────────────────────────────────────────────────

WAKEFULNESS=$($ADB shell dumpsys power | grep -m1 'mWakefulness=' | tr -d ' \r' | cut -d= -f2)
echo "Screen state: $WAKEFULNESS"

if [[ "$WAKEFULNESS" != "Awake" ]]; then
  echo "Waking screen..."
  $ADB shell input keyevent KEYCODE_WAKEUP
  sleep 1
fi

# ── Check lock state ──────────────────────────────────────────────────────────

LOCKED=$($ADB shell dumpsys window | grep -m1 'mDreamingLockscreen=' | tr -d ' \r' | cut -d= -f2)
echo "Lockscreen: $LOCKED"

if [[ "$LOCKED" == "true" ]]; then
  echo "Unlocking (swipe-to-unlock)..."
  # Swipe up from bottom third to top third of screen
  $ADB shell input swipe 540 1600 540 400 300
  sleep 1
fi

# ── Verify we're unlocked ─────────────────────────────────────────────────────

LOCKED_AFTER=$($ADB shell dumpsys window | grep -m1 'mDreamingLockscreen=' | tr -d ' \r' | cut -d= -f2)
if [[ "$LOCKED_AFTER" == "true" ]]; then
  echo "WARNING: Device still shows lockscreen — may have PIN/pattern lock."
  echo "Unlock manually and re-run, or use 'adb shell wm dismiss-keyguard' on debug builds."
fi

# ── Launch app ────────────────────────────────────────────────────────────────

echo "Launching $PACKAGE..."
$ADB shell am start -n "$PACKAGE/$ACTIVITY"
echo "Done."
