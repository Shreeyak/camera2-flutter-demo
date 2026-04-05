# Plan: Explicit PBO Sync with Fence Objects + GPU Timing

## Why

The current PBO readback in `GpuRenderer::drawAndReadback()` uses `GL_MAP_READ_BIT`
alone when mapping the previous frame's buffer:

```cpp
glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, size, GL_MAP_READ_BIT);
```

This tells the driver to ensure the buffer is safe to read, but gives the driver
permission to insert an **implicit sync point** — a hidden stall on the GL thread
until the GPU→CPU DMA completes. The GL thread is the same thread that drives
preview and encoder delivery, so any stall here directly delays the next frame:

```
GL thread (frame N+1):

  ① render → fbo_         [fast]
  ② blit → preview        [fast]
  ③ blit → encoder        [fast]
  ④ glReadPixels → PBO    [fast, enqueues async DMA]
  ⑤ glMapBufferRange ──── driver may stall here until frame N's DMA finishes
  ⑥ C++ sink callbacks
```

At 4K (~32 MB per readback), the DMA can take 5–15 ms on a loaded mobile GPU.
If the one-frame gap between write (step ④) and read (step ⑤) isn't long enough
for the DMA to complete, the driver stalls — potentially pushing past the 33 ms
vsync deadline and dropping a frame.

The problem is invisible: there is no logging, no counter, no metric that reveals
whether stalls are occurring. We could be dropping frames silently on every device.

---

## What We Will Do

Replace the implicit sync with:

1. **Explicit fence objects** (`glFenceSync` / `glClientWaitSync`) so we control
   exactly when we wait and know precisely whether a stall occurred.
2. **`GL_MAP_UNSYNCHRONIZED_BIT`** on the map call, making it legal and correct
   to skip the driver's implicit wait (because we've already waited explicitly).
3. **`GL_TIME_ELAPSED` timing queries** on the readback path so we have real
   numbers for DMA latency and can surface stalls as diagnostics.

---

## Implementation

### Files to change

- `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h`
- `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp`

### Step 1 — Add fence storage to `GpuRenderer`

In `GpuRenderer.h`, add fence handles alongside the existing PBO arrays:

```cpp
// After:
GLuint fullResPbo_[2]  = {0, 0};
GLuint trackerPbo_[2]  = {0, 0};
GLuint rawPbo_[2]      = {0, 0};

// Add:
GLsync fullResFence_[2]  = {nullptr, nullptr};
GLsync trackerFence_[2]  = {nullptr, nullptr};
GLsync rawFence_[2]      = {nullptr, nullptr};
```

Also add timing query objects and a stall counter:

```cpp
GLuint   timeQuery_[2]  = {0, 0};  // GL_TIME_ELAPSED queries, one per PBO slot
uint64_t stallCount_    = 0;       // total frames where fence was not yet signalled
uint64_t frameCount_    = 0;       // total frames processed, for stall rate
```

### Step 2 — Insert fences after `glReadPixels` (step ⑤)

In `drawAndReadback()`, immediately after each `glReadPixels`:

```cpp
// Full-res readback
glBindBuffer(GL_PIXEL_PACK_BUFFER, fullResPbo_[writeIdx]);
glReadPixels(0, 0, width_, height_, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
// Delete old fence for this slot (if any) and insert a new one
if (fullResFence_[writeIdx]) glDeleteSync(fullResFence_[writeIdx]);
fullResFence_[writeIdx] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);

// Tracker readback
glBindBuffer(GL_PIXEL_PACK_BUFFER, trackerPbo_[writeIdx]);
glReadPixels(0, 0, trackerWidth_, trackerHeight_, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
if (trackerFence_[writeIdx]) glDeleteSync(trackerFence_[writeIdx]);
trackerFence_[writeIdx] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
```

### Step 3 — Wait on fence before mapping (step ⑥)

Replace the existing `glMapBufferRange` calls with a fence wait + unsynchronized map:

```cpp
// Helper: wait on fence, log stall if it occurred
static bool waitFence(GLsync& fence, const char* label) {
    if (!fence) return true;  // no fence yet (first frame)
    GLenum result = glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, 0);
    if (result == GL_TIMEOUT_EXPIRED) {
        // DMA not done — wait with a real timeout
        LOGW("PBO fence stall: %s — waiting up to 8ms", label);
        result = glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, 8'000'000);
        if (result == GL_TIMEOUT_EXPIRED) {
            LOGE("PBO fence timeout after 8ms: %s — skipping readback", label);
            return false;  // caller skips this frame's callbacks
        }
    }
    glDeleteSync(fence);
    fence = nullptr;
    return true;
}

// In drawAndReadback(), step ⑥:
if (!firstFrame_) {
    // Full-res
    if (waitFence(fullResFence_[readIdx], "full-res")) {
        glBindBuffer(GL_PIXEL_PACK_BUFFER, fullResPbo_[readIdx]);
        auto* ptr = static_cast<const uint8_t*>(
            glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, width_ * height_ * 4,
                             GL_MAP_READ_BIT | GL_MAP_UNSYNCHRONIZED_BIT));
        if (ptr) {
            fullResCb(ptr, width_, height_, width_ * 4,
                      storedMeta.frameId, storedMeta.meta);
            glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
        }
    }

    // Tracker (same pattern)
    if (waitFence(trackerFence_[readIdx], "tracker")) {
        // ... same pattern
    }
}
```

The zero-timeout `glClientWaitSync` is the key: if the DMA is already done (the
common case), it returns `GL_ALREADY_SIGNALED` instantly with no stall. Only when
the DMA is still in flight does it block — and now we know about it.

### Step 4 — Add `GL_TIME_ELAPSED` timing queries (always on)

`GL_TIME_ELAPSED` measures elapsed GPU time between `glBeginQuery` and
`glEndQuery`. Like PBOs, the result is double-buffered — you read the previous
frame's result while issuing this frame's query, so there is no GPU stall.

The query wraps the `glReadPixels` calls (the DMA enqueue) and is read back one
frame later alongside the fence wait. This tells you how long the GPU spent
setting up the transfer — distinct from the fence wait time, which tells you how
long the CPU waited for it.

```cpp
// Step ⑤ — issue readback + begin timing query
glBeginQuery(GL_TIME_ELAPSED, timeQuery_[writeIdx]);

glBindBuffer(GL_PIXEL_PACK_BUFFER, fullResPbo_[writeIdx]);
glReadPixels(0, 0, width_, height_, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
if (fullResFence_[writeIdx]) glDeleteSync(fullResFence_[writeIdx]);
fullResFence_[writeIdx] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);

glBindBuffer(GL_PIXEL_PACK_BUFFER, trackerPbo_[writeIdx]);
glReadPixels(0, 0, trackerWidth_, trackerHeight_, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
if (trackerFence_[writeIdx]) glDeleteSync(trackerFence_[writeIdx]);
trackerFence_[writeIdx] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);

glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
glEndQuery(GL_TIME_ELAPSED);
```

```cpp
// Step ⑥ — read previous frame's timing, then fence-wait + map
if (!firstFrame_) {
    // Read timing query result from readIdx (non-blocking: GPU has had a full
    // frame to complete it)
    GLuint64 dmaEnqueueNs = 0;
    glGetQueryObjectui64v(timeQuery_[readIdx],
                          GL_QUERY_RESULT_AVAILABLE, nullptr);  // optional check
    glGetQueryObjectui64v(timeQuery_[readIdx], GL_QUERY_RESULT, &dmaEnqueueNs);

    frameCount_++;

    // Fence wait + map (see Step 3 for waitFence helper)
    auto t0 = std::chrono::steady_clock::now();

    bool fullResReady   = waitFence(fullResFence_[readIdx],   "full-res");
    bool trackerReady   = waitFence(trackerFence_[readIdx],   "tracker");

    auto stallNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - t0).count();

    if (stallNs > 500'000) {  // > 0.5ms — fence was not yet signalled
        stallCount_++;
        LOGW("PBO stall: waited %.2f ms (frame %llu, stall rate %.1f%%)",
             stallNs / 1e6, frameId,
             100.0 * stallCount_ / frameCount_);
    }

    // Log DMA enqueue time periodically
    if (frameCount_ % 300 == 0) {  // every ~10s at 30fps
        LOGI("PBO diagnostics: dma_enqueue=%.2f ms  stall_rate=%.1f%%  "
             "stalls=%" PRIu64 "/%" PRIu64,
             dmaEnqueueNs / 1e6,
             100.0 * stallCount_ / frameCount_,
             stallCount_, frameCount_);
    }

    if (fullResReady) {
        glBindBuffer(GL_PIXEL_PACK_BUFFER, fullResPbo_[readIdx]);
        auto* ptr = static_cast<const uint8_t*>(
            glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, width_ * height_ * 4,
                             GL_MAP_READ_BIT | GL_MAP_UNSYNCHRONIZED_BIT));
        if (ptr) {
            fullResCb(ptr, ...);
            glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
        }
    }
    // tracker: same pattern
}
```

**What the two metrics tell you:**

```
dmaEnqueueNs   — how long the GPU spent setting up the transfer.
                 High value → GPU was busy; transfer was queued late.

stallNs        — how long the CPU waited for the transfer to finish.
                 Any non-zero value → one-frame gap was insufficient.
                 Sustained stalls → increase PBO ring depth to 3.
```

### Step 5 — Initialise timing queries and clean up in `releaseGl()`

Allocate queries in `initGl()`:

```cpp
glGenQueries(2, timeQuery_);
```

Delete everything on teardown in `releaseGl()`:

```cpp
for (int i = 0; i < 2; ++i) {
    if (fullResFence_[i])  { glDeleteSync(fullResFence_[i]);    fullResFence_[i]  = nullptr; }
    if (trackerFence_[i])  { glDeleteSync(trackerFence_[i]);    trackerFence_[i]  = nullptr; }
    if (rawFence_[i])      { glDeleteSync(rawFence_[i]);         rawFence_[i]      = nullptr; }
    if (timeQuery_[i])     { glDeleteQueries(1, &timeQuery_[i]); timeQuery_[i]     = 0; }
}
LOGI("GpuRenderer teardown: total frames=%" PRIu64 "  pbo_stalls=%" PRIu64
     "  stall_rate=%.1f%%",
     frameCount_, stallCount_,
     frameCount_ > 0 ? 100.0 * stallCount_ / frameCount_ : 0.0);
```

The teardown log gives a lifetime stall summary — useful for comparing builds or devices.

### Step 6 — Apply same pattern to raw PBOs

The raw stream path (`rawPbo_[2]`) has the same issue. Apply the identical fence
+ unsynchronized map pattern there.

---

## What We Gain

| Scenario | Before | After |
|----------|--------|-------|
| DMA done before map | Driver may or may not stall; invisible | `glClientWaitSync` returns immediately, no stall, no change in behaviour |
| DMA not done before map | Driver stalls GL thread silently | `glClientWaitSync` stalls with a logged warning; we know it happened |
| DMA takes > 8ms | GL thread blocks indefinitely | Readback skipped for that frame; pipeline keeps running |
| Performance analysis | No data | `GL_TIME_ELAPSED` gives actual DMA latency per frame in debug builds |

**In the common case (DMA already done):** zero behavioural difference, zero
overhead (a `glClientWaitSync` with zero timeout on an already-signalled fence
is a no-op).

**In the pathological case (DMA not done):** we stall just as before, but now
we log it, count it, and can set a timeout to skip rather than block forever.

---

## What We Do Not Gain

This does not eliminate stalls if the one-frame gap is genuinely too short for the
DMA to complete. If stalls are frequent, the right fix is to increase the PBO
ring depth from 2 to 3 (write N, write N+1, read N — two frames of headroom).
That's a separate, larger change.

---

## Verification

Run on a real device at 4K with a C++ sink registered (to simulate production load).

**Logcat signals to watch:**

| Tag | Meaning | Action |
|-----|---------|--------|
| `PBO stall: waited X ms` | Fence was not signalled — GL thread blocked | If frequent, increase ring depth to 3 |
| `PBO diagnostics: dma_enqueue=X ms` | How long GPU spent queuing the DMA | Baseline; > 5ms suggests GPU contention |
| `PBO fence timeout after 8ms` | DMA took > 8ms — readback skipped | Severe GPU overload; investigate |
| `GpuRenderer teardown: stall_rate=X%` | Lifetime stall rate | > 1% warrants investigation |

**Baseline test (no stalls expected):**
1. Open camera, register no C++ sinks.
2. Run for 60 seconds.
3. Confirm `stall_rate=0.0%` at teardown and `dma_enqueue` < 2ms.

**Stress test:**
1. Register a C++ sink that sleeps for 5ms per callback (simulating slow consumer).
2. Run for 60 seconds.
3. Confirm stalls are **logged** (not silent), pipeline keeps running, no deadlock.

**Recording test:**
1. Start recording at 4K.
2. Confirm no increase in stall rate vs non-recording baseline.
3. Confirm `dma_enqueue` does not grow (encoder blit should not delay PBO enqueue).
