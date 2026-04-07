# Fix: Log lifecycle observer failures

**PR comments:** #20 thread 3042375028

## Problem

The `ProcessLifecycleOwner` observer calls `backgroundSuspend { }` and `backgroundResume { }` with empty callbacks. If these fail, the error is silently swallowed.

## Changes

**`CambrianCameraPlugin.kt` — `lifecycleObserver`:**

Replace empty callbacks with error-logging callbacks:
```kotlin
sessions.values.forEach { session ->
    session.controller.backgroundSuspend { result ->
        result.exceptionOrNull()?.let { e ->
            Log.e(TAG, "backgroundSuspend failed for session ${session.producer.id()}", e)
        }
    }
}
```

Same pattern for `backgroundResume`.

## Acceptance criteria

- Lifecycle observer failures are logged at ERROR level
- No functional change to happy path
