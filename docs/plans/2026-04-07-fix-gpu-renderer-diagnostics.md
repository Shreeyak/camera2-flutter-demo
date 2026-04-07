# Fix: GpuRenderer diagnostic logging and GL extension safety

**PR comments:** #22 threads 3042425079, 3042425089, 3042425093, 3042425101, 3042425104

## Problems

1. **waitFence LOGW spam** — Logs warning on every zero-timeout poll expiry, which is expected/normal behavior.
2. **GL_TIME_ELAPSED_EXT unchecked** — Timing queries used without verifying extension support. Generates GL errors on unsupported devices.
3. **Comment/behavior mismatch** — Says "all readPixels" but raw path readPixels is not wrapped in timing query.
4. **PBO diagnostics unconditional** — Periodic stall-rate logs at INFO level every 300 frames regardless of `debugLevel_`.
5. **Teardown summary unconditional** — `releaseGl()` stall summary logged at INFO regardless of `debugLevel_`.

## Changes

### 1. Remove waitFence LOGW (GpuRenderer.cpp ~line 132)
Remove the `LOGW("PBO fence stall…")` inside the zero-timeout branch. The subsequent 8ms wait + timeout error log is sufficient.

### 2. Check extension support (GpuRenderer.cpp — `initGl()`)
Add a `bool hasTimerQuery_` member. In `initGl()`:
```cpp
const char* exts = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
hasTimerQuery_ = exts && strstr(exts, "GL_EXT_disjoint_timer_query");
```
Gate all `glBeginQuery`/`glEndQuery`/`glGenQueries`/`glDeleteQueries` behind `hasTimerQuery_`.

### 3. Fix comment (GpuRenderer.cpp ~line 362)
Change "Wrap all readPixels calls" to "Wrap processed-path readPixels calls".

### 4. Gate periodic diagnostics behind debugLevel (GpuRenderer.cpp ~line 421)
Change the periodic log from unconditional to `if (debugLevel_ >= 1)`.

### 5. Gate teardown summary behind debugLevel (GpuRenderer.cpp ~line 925)
Change to `if (debugLevel_ > 0)`.

## Acceptance criteria

- No LOGW spam on normal fence polling
- Timing queries only used when `GL_EXT_disjoint_timer_query` is available
- Comment matches behavior
- Periodic diagnostics respect `debugLevel_`
- Teardown summary respects `debugLevel_`
