# C++ Image Pipeline — Architecture & Data Flow

> Restricted to the Camera2 → C++ post-processing path. Flutter UI and Kotlin session
> management are out of scope.

---

## 1. Overview

The pipeline is a multi-stage producer/consumer system that:

1. Receives raw YUV_420_888 frames from the Android camera hardware
2. Buffers them in a 4-slot ring so the camera thread never stalls
3. Converts to BGR and applies post-processing on a dedicated processing thread
4. Fans out the result to N registered consumer sinks via per-consumer 1-slot mailboxes
5. Blits both raw (pre-processing) and processed previews to Flutter `ANativeWindow` surfaces

```
 ┌─────────────────────────────────────────────────────────────────────────┐
 │  CAMERA HARDWARE                                                        │
 │  YUV_420_888  4160×3120  ~30fps                                         │
 └───────────────────────────┬─────────────────────────────────────────────┘
                             │ JNI callback (camera thread)
                             ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │  InputRing  (4 pre-allocated slots)                                     │
 │  push(): copy + strip row-stride padding → O(1) swap into write slot    │
 │  drop-on-full: camera thread NEVER blocks                               │
 └───────────────────────────┬─────────────────────────────────────────────┘
                             │ pop(): blocking (processing thread)
                             ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │  processingLoop  (dedicated std::thread)                                │
 │                                                                         │
 │  YuvSlot → cv::Mat bgr (NV12/NV21: cvtColorTwoPlane, I420: memcpy+cvt)│
 │         → rawFrame (shared_ptr<Frame>, zero-copy std::move)             │
 │         → [saturation if != 1.0] → processedFrame (new allocation)     │
 │         → publishToRawConsumer(rawFrame)    ──────► rawConsumer_        │
 │         → publishToConsumers(processedFrame)──────► consumers_[0..N]   │
 └─────────────────────────────────────────────────────────────────────────┘
          │ mailbox drop (lock, swap pending, notify)
          │
          ├──────────────────────────────────────────────┐
          ▼                                              ▼
 ┌──────────────────────┐                    ┌──────────────────────────────┐
 │  rawConsumer_        │                    │  consumers_[0]               │
 │  "__raw_preview"     │                    │  "__preview"                 │
 │  dispatch thread     │                    │  dispatch thread             │
 │                      │                    │                              │
 │  BGR → RGBA          │                    │  BGR → RGBA                  │
 │  blitToWindow(raw)   │                    │  blitToWindow(processed)     │
 └──────────────────────┘                    └──────────────────────────────┘
          │                                              │
          ▼                                              ▼
  Flutter Texture (left pane)              Flutter Texture (right pane)
  raw, unsaturated                         post-processed (saturation etc.)
```

---

## 2. Data Structures

### YuvSlot  _(InputRing.h)_
One pre-allocated ring slot. Row-stride padding is stripped on push so processing
never has to think about camera buffer alignment.

| Field      | Type                   | Size at 4160×3120        | Notes                          |
|------------|------------------------|--------------------------|--------------------------------|
| `yData`    | `vector<uint8_t>`      | 12,979,200 B (≈12.4 MB)  | Packed luma, no padding        |
| `uvData`   | `vector<uint8_t>`      | 6,489,600 B (≈6.2 MB)    | NV21/NV12 interleaved or I420  |
| `yuvFormat`| `int`                  | —                        | NV21=1, NV12=2, I420=3         |
| `frameId`  | `uint64_t`             | —                        | Monotonic counter from Camera2 |
| `meta`     | `FrameMetadata`        | —                        | ISO, exposure, timestamp       |

Ring capacity: 4 slots × ~19 MB = **~76 MB** peak pre-allocated.

### FrameMetadata  _(cambrian_camera_native.h)_
Sensor values captured alongside each frame, forwarded through the entire pipeline
to every sink.

```
frameNumber       int64   monotonic counter
sensorTimestampNs int64   capture start time (ns)
exposureTimeNs    int64   actual exposure duration (ns)
iso               int32   sensor sensitivity
```

### Frame  _(ImagePipeline.h, internal)_
The shared BGR frame passed between the processing thread and consumer dispatch
threads via `shared_ptr`. `cv::Mat` is kept here (not in the public API).

| Field    | Type          | Size at 4160×3120         |
|----------|---------------|---------------------------|
| `bgr`    | `cv::Mat`     | 38,937,600 B (≈37.1 MB)   |
| `id`     | `uint64_t`    | —                         |
| `meta`   | `FrameMetadata` | —                       |
| `width`  | `int`         | —                         |
| `height` | `int`         | —                         |
| `stride` | `int`         | bytes per row             |
| `format` | `PixelFormat` | BGR (internal)            |

`using SharedFrame = std::shared_ptr<Frame>` — ref-counted lifetime across all
consumer mailboxes.

### SinkFrame  _(cambrian_camera_native.h, public)_
The view into a `Frame` that the public sink callback receives. Raw pointer into
`Frame::bgr.data` — valid only during the callback.

### Consumer  _(ImagePipeline.h, internal)_
Per-sink state block.

```
name           string         unique identifier
callback       SinkCallback   user-supplied function<void(SinkFrame)>
pending        SharedFrame    1-slot mailbox (latest frame wins)
mu             mutex          guards `pending`
cv             condition_var  wakes dispatch thread
dispatchThread thread
running        atomic<bool>
```

### ProcessingParams  _(ImagePipeline.h)_
All user-adjustable processing knobs. Snapshot-copied into processingLoop under
`paramsMu_` at the start of each frame — inner loop holds no lock.

```
blackR/G/B     float   [0, 0.5]   black level (stored, not yet applied)
gamma          float   [0.1, 4.0] (stored, not yet applied)
histBlackPoint float   [0, 1]     (stored, not yet applied)
histWhitePoint float   [0, 1]     (stored, not yet applied)
autoStretch    bool               (stored, not yet applied)
brightness     float   [-1, 1]    (stored, not yet applied)
saturation     float   [0, 3]     ACTIVE — luminance-preserving formula
```

---

## 3. Thread Model

```
┌──────────────────┐   ┌──────────────────────┐   ┌──────────────────────┐
│  Camera thread   │   │  Processing thread   │   │  Consumer threads    │
│  (Android OS)    │   │  (processingLoop)    │   │  (one per Consumer)  │
│                  │   │                      │   │                      │
│  deliverYuv()    │   │  inputRing_.pop()    │   │  dispatch loop:      │
│      │           │   │     (blocks)         │   │    wait on cv        │
│      ▼           │   │         │            │   │    move pending      │
│  InputRing       │──►│  YUV→BGR             │   │    invoke callback   │
│  .push()         │   │  [saturation]        │   │                      │
│  (O(1), never    │   │  publishToConsumers()│──►│  __preview           │
│   blocks)        │   │  publishToRawCons.() │──►│  __raw_preview       │
│                  │   │                      │   │  [user sinks...]     │
└──────────────────┘   └──────────────────────┘   └──────────────────────┘

   Appliction/JNI
   ┌──────────────────┐
   │  Dart/JNI thread │
   │                  │
   │  setParams()     │   → paramsMu_ snapshot
   │  addSink()       │   → consumersMu_ + new thread
   │  removeSink()    │   → consumersMu_ + thread join
   │  setPreviewWindow│   → windowMu_
   └──────────────────┘
```

**Thread count at runtime (typical):**
- 1 processing thread
- 1 dispatch thread for `rawConsumer_` (`__raw_preview`)
- 1 dispatch thread for `consumers_[0]` (`__preview`)
- = **3 pipeline threads** + Android camera thread (managed by OS)

Plus `applySaturation` spawns **4 worker threads per frame** (joined before returning).
Peak goroutine-equivalent: 3 + 4 = 7 threads during saturation.

---

## 4. Lock Ordering & Synchronization

Lock ordering must be strictly respected to prevent deadlock:

```
1. windowMu_       ANativeWindow access (setPreviewWindow, blitToWindow)
2. consumersMu_    consumers_ vector (addSink, removeSink, publishToConsumers)
3. Consumer::mu    per-consumer mailbox (publishToConsumers, dispatch thread)

paramsMu_  independent — never held with any other lock
```

`rawConsumer_->mu` is logically equivalent to a `Consumer::mu` but lives outside
the `consumers_` vector — do not acquire `consumersMu_` while holding it.

**Mailbox semantics:** `publishToConsumers` and `publishToRawConsumer` hold
`Consumer::mu` only long enough to swap the `pending` shared_ptr. The dispatch
thread moves the pointer out immediately. If the consumer is slow, the previous
frame's shared_ptr is released (dropped) and replaced with the latest — latest-frame
semantics, zero queuing.

---

## 5. Frame Data Flow — Step by Step

```
Camera hardware
    │
    │  YUV_420_888  (width=4160, height=3120)
    │  Y plane:  row-stride ≥ 4160 (Camera2 may pad to 4192 etc.)
    │  UV plane: row-stride ≥ 4160
    ▼
InputRing::push()  [camera thread]
    │
    │  Strip padding: copy width×height bytes to slot.yData  (12.4 MB)
    │                 copy width×height/2 bytes to slot.uvData (6.2 MB)
    │  Detect YUV format (NV21/NV12/I420) from yuvFormat param
    │  Increment writeIdx_ (mod 4), count_++
    │  cv_.notify_one()
    │
    │  If count_ == ringSize: drop frame silently (camera never blocks)
    ▼
InputRing::pop()  [processing thread — blocks on cv_]
    │
    │  swap(slots_[readIdx_], out)  → O(1) pointer exchange
    │  Increment readIdx_ (mod 4), count_--
    ▼
processingLoop()  [processing thread]
    │
    │  ① Snapshot ProcessingParams (paramsMu_ — brief lock)
    │
    │  ② YUV → BGR
    │     NV21/NV12: cv::cvtColorTwoPlane(y_mat, uv_mat, bgr, NV21/NV12)
    │     I420:      memcpy Y+UV into contiguous mat, cv::cvtColor(I420)
    │     Output: cv::Mat bgr  CV_8UC3  4160×3120  (37.1 MB)   ~6ms
    │
    │  ③ Build rawFrame  (SharedFrame)
    │     rawFrame->bgr = std::move(bgr)   ← zero-copy
    │
    │  ④ Processing chain  (lazy-copy pattern)
    │
    │     if |saturation - 1.0| > 1e-4:
    │         applySaturation(rawFrame->bgr, processed, sat)
    │         → spawn 4 std::threads, each handles rows/4
    │         → BT.601 luminance-preserving formula per pixel:
    │              gray = 0.114·B + 0.587·G + 0.299·R
    │              B' = clamp(gray + sat·(B−gray))
    │              G' = clamp(gray + sat·(G−gray))
    │              R' = clamp(gray + sat·(R−gray))
    │         → join 4 threads
    │         → processed: new 37.1 MB cv::Mat      ~24ms (at 4160×3120)
    │         modified = true
    │     else:
    │         processed = (unset), modified = false
    │
    │  ⑤ Dispatch  (non-blocking mailbox writes)
    │
    │     if rawPreviewWindow_ set:
    │         publishToRawConsumer(rawFrame)       ← pre-processing BGR
    │         → lock rawConsumer_->mu, swap pending, notify
    │
    │     if modified:
    │         pFrame->bgr = std::move(processed)   ← zero-copy
    │         publishToConsumers(pFrame)
    │     else:
    │         publishToConsumers(rawFrame)          ← alias, zero-copy
    │         (both rawConsumer_ and consumers_ share same Frame ptr)
    │
    ▼
Consumer dispatch thread  [one per Consumer]
    │
    │  wait on Consumer::cv until pending != null or !running
    │  move SharedFrame out of pending  (mailbox cleared)
    │  build SinkFrame { .data = frame->bgr.data, ... }
    │  invoke callback(sf)
    │
    │  __preview callback:
    │      cv::cvtColor(bgr, previewRgba_, BGR2RGBA)   ← RGBA scratch buffer
    │      blitToWindow(previewWindow_, ...)
    │
    │  __raw_preview callback:
    │      cv::cvtColor(bgr, rawPreviewRgba_, BGR2RGBA)
    │      blitToWindow(rawPreviewWindow_, ...)
    ▼
blitToWindow()
    │  lock windowMu_
    │  ANativeWindow_setBuffersGeometry (once on size change)
    │  ANativeWindow_lock → buf.bits
    │  memcpy row-by-row (safeH × safeW × 4 bytes)
    │  ANativeWindow_unlockAndPost
    ▼
Flutter Texture (rendered by Engine)
```

---

## 6. Memory Budget at 4160×3120

| Buffer                            | Size      | Count | Total      | Notes                         |
|-----------------------------------|-----------|-------|------------|-------------------------------|
| InputRing YuvSlot (Y+UV)          | 18.6 MB   | 4     | 74.4 MB    | Pre-allocated, reused         |
| rawFrame BGR (cv::Mat)            | 37.1 MB   | 1     | 37.1 MB    | Moves from YUV conversion     |
| processedFrame BGR (cv::Mat)      | 37.1 MB   | 0–1   | 0–37.1 MB  | Only allocated when sat ≠ 1.0 |
| previewRgba_ scratch              | 49.5 MB   | 1     | 49.5 MB    | Reused each frame             |
| rawPreviewRgba_ scratch           | 49.5 MB   | 1     | 49.5 MB    | Reused each frame             |
| **Total steady-state**            |           |       | **~248 MB**| With saturation active        |

`SharedFrame` ref-counting ensures Frame objects survive until all consumers have
called their callbacks. At ~30fps with up to 2 in-flight frames, peak held is 2×74 MB
for the ring plus 2× Frame objects ≈ **~325 MB** absolute peak.

---

## 7. Key Design Decisions

### Drop-on-full ring buffer
The camera OS callback must return promptly. Blocking would cause `ImageReader`
to run out of buffers and trigger `CAMERA_ERROR`. The ring silently drops frames
when all 4 slots are occupied — processing slowdowns degrade frame rate, not
camera stability.

### Lazy-copy chain
When all processing steps are identity (e.g., `saturation == 1.0`), `processedFrame`
is a `shared_ptr` alias of `rawFrame` — no copy, no extra allocation. Only the first
active step allocates a new `cv::Mat`.

### Separate rawConsumer_
The raw preview consumer is outside `consumers_` so that:
- It receives the pre-processing BGR regardless of what processing is applied
- `publishToRawConsumer` and `publishToConsumers` can be called independently
- `shutdownConsumers()` (teardown of user sinks) does not affect the raw preview

### 1-slot mailbox (latest-frame semantics)
Each consumer holds at most one pending frame. If a consumer's dispatch thread
is slow (e.g., blit stalls on vsync), the next published frame overwrites the
pending one. Old frames are dropped, not queued — this prevents unbounded memory
growth and latency buildup.

### 4-thread manual saturation
`cv::parallel_for_` is single-threaded with the prebuilt OpenCV (no TBB/OpenMP
backend). Explicit `std::thread[4]` with row-split achieves ~4× speedup on
Android big cores. Thread spawn overhead (~0.1ms) is negligible vs. 24ms processing.

### -O2 baseline for all build types
OpenCV prebuilt is always compiled at -O2. Without matching optimization, the
per-pixel saturation loop runs at -O0 (debug default) and is 20-50× slower.
`-O2 -ftree-vectorize` is set for ALL configs; `-O3 -ffast-math` for Release only.

---

## 8. Profiling Output Format

Every 60 frames the processing thread logs:

```
perf [240] fps=15.0  total=40.4ms  pop=25.1ms  yuv=4.3ms  sat=10.9ms  pub=0.1ms
```

| Field   | What it measures                                              |
|---------|---------------------------------------------------------------|
| `fps`   | Wall-clock frames per second over the last 60-frame interval  |
| `total` | Full per-frame wall time including pop wait                   |
| `pop`   | Time blocked in `inputRing_.pop()` waiting for next frame    |
| `yuv`   | YUV → BGR color conversion (OpenCV)                          |
| `sat`   | `applySaturation` (4-thread pixel loop)                      |
| `pub`   | `publishToConsumers` + `publishToRawConsumer` mailbox writes  |

`total ≈ pop + yuv + sat + pub`. A large `pop` value (e.g. 25ms at 30fps) means
the pipeline is idle waiting for camera — processing is not the bottleneck.
A large `sat` value means the pixel loop is slow (check build flags).

---

## 9. Public Extension Points

External code (Kotlin or Dart via JNI) can register additional sinks:

```cpp
IImagePipeline* pipeline = /* cast from CameraController.getNativePipelineHandle() */;

pipeline->addSink({"my_sink"}, [](const cam::SinkFrame& f) {
    // f.data   — raw BGR pixel data (valid only during this call)
    // f.width  — frame width
    // f.height — frame height
    // f.stride — bytes per row (may exceed width * 3)
    // f.meta   — ISO, exposure, timestamp
    // f.frameId — monotonic counter
});

pipeline->removeSink("my_sink");  // blocks until dispatch thread exits
```

Each registered sink gets its own dispatch thread and 1-slot mailbox. Slow sinks
drop frames independently — one slow consumer cannot block others.
