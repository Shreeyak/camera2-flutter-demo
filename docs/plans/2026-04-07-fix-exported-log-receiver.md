# Fix: Restrict LogLevelReceiver to debug builds

**PR comments:** #17 thread 3042286905

## Problem

`LogLevelReceiver` is registered in `AndroidManifest.xml` with `android:exported="true"`. Any app on the device can send `com.cambrian.camera.SET_LOG_LEVEL` and toggle verbose diagnostics.

## Changes

**`packages/cambrian_camera/android/src/main/kotlin/com/cambrian/camera/LogLevelReceiver.kt`:**
- Add a runtime check at the top of `onReceive()`: if not a debuggable build, return early.
  ```kotlin
  if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
      Log.w(TAG, "SET_LOG_LEVEL broadcast ignored in release build")
      return
  }
  ```

## Acceptance criteria

- ADB broadcast has no effect in release builds
- ADB broadcast still works in debug builds
