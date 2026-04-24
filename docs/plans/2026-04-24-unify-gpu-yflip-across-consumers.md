# Unified GPU Y-flip across every downstream consumer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `captureImage`, tracker-sink, raw-sink, and any future C++ sink receive the same Y-flipped landscape pixels that the preview and the video encoder currently show. `captureNaturalPicture` (hardware JPEG) stays untouched.

**Architecture:** Two new GL framebuffer objects (`fullResReadbackFbo_`, `rawReadbackFbo_`) act as Y-flipped mirrors of `fbo_` and `rawFbo_`. A Y-inverting `glBlitFramebuffer` is issued into each mirror immediately before the corresponding `glReadPixels`. The tracker path, which already uses an existing `glBlitFramebuffer` downsample from `fbo_` into `trackerFbo_`, gets its dst-Y coordinates swapped in-place — no new FBO needed for tracker. Shader code, preview/video blits, and all Kotlin/Dart code stay unchanged.

**Tech Stack:** C++ (OpenGL ES 3.0 on arm64 Android), Kotlin/JNI shim, Flutter debug APK build. All changes land in `GpuRenderer.{h,cpp}` under `packages/cambrian_camera/android/src/main/cpp/`.

---

## Why this fix is needed (context — read before starting)

Today the shader correctly writes the user's intended "90° rotation + Y-flip" content into `fbo_` / `rawFbo_`. Two different Y-conventions consume those FBOs:

- **Preview** (`glBlitFramebuffer(fbo_ → EGL window)` at `GpuRenderer.cpp:420`), **video encoder** (`glBlitFramebuffer(fbo_ → EGL encoder)` at `:451`), and **raw preview** (`glBlitFramebuffer(rawFbo_ → rawEGLSurface_)` at `:619`) are **GL-native** — they preserve GL's origin-at-bottom-left convention through the compositor. User sees the shader's intended output.
- **All `glReadPixels` paths** (full-res `:478`, tracker `:486`, raw `:636`) return pixels rows-bottom-up. Downstream JPEG/PNG encoders and C++ sink consumers treat row 0 as the top of the image. This implicit Y-flip cancels the shader's Y-flip, so saved files and CV-sink frames lose it.

The shipped `a6a9f30` commit removed a legacy CPU `rotateRgba90CW` that was accidentally compensating for the readback Y-flip. This plan restores consistency by doing the compensation at the GL layer — cheap (GPU blit, ~tens of microseconds), scoped to the readback paths, and transparent to every downstream consumer.

The user has confirmed on-device that preview and video already match each other. Only the `glReadPixels`-fed consumers are broken.

Reference prior analysis and diagrams: `/Users/shrek/.claude/plans/okay-here-s-what-i-whimsical-brooks.md` (internal planning notes).

---

## File Structure — responsibilities

- **`packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h`** — add four new member handles (2 FBOs + 2 color textures). Pure declaration; no logic.
- **`packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp`** — all logic changes: allocate mirrors in `initGl()`, release in `releaseGl()`, modify three sites in `drawAndReadback()` (one existing blit + two new blits). `resize()` needs no modification because it already calls `releaseGl() → initGl()`.

No other files touched. No new tests written (see "Why no new tests" below).

### Why no new tests

Existing coverage:
- `packages/cambrian_camera/android/src/androidTest/kotlin/com/cambrian/camera/GpuSinkConsistencyTest.kt` — verifies that sink deliveries produce non-zero bytes of the expected dimensions. Still valid after this change; re-run to confirm no regression.
- `packages/cambrian_camera/android/src/androidTest/kotlin/com/cambrian/camera/GpuRendererTest.kt` — basic init/release smoke tests. Also still valid.
- `packages/cambrian_camera/android/src/main/cpp/test/SinkRoutingTest.cpp` — routing-only; no pixel-layout assertions.

Writing a **new** test that verifies Y-orientation would require building a test harness that feeds a known pattern through the OES texture and checks specific pixel positions in the PBO output. That is significant scaffolding for a one-line-per-site change. The user will visually verify on device (see Task 8) — adequate signal given the change touches three lines of GL coordinate logic.

---

## Task 1: Add member declarations in GpuRenderer.h

**Files:**
- Modify: `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h` around lines 220–235 (where the existing `fbo_` / `fboTexture_` / `trackerFbo_` / `trackerTexture_` / `rawFbo_` / `rawFboTexture_` member declarations live).

- [ ] **Step 1: Locate the existing FBO member declarations.** Read `GpuRenderer.h` and find the block that declares `GLuint fbo_`, `GLuint fboTexture_`, `GLuint trackerFbo_`, `GLuint trackerTexture_`, `GLuint rawFbo_`, `GLuint rawFboTexture_`. (Use `grep -n "fbo_\|rawFbo_" GpuRenderer.h` if needed.)

- [ ] **Step 2: Add four new zero-initialised handles immediately after the existing raw-FBO declarations.** Insert:

  ```cpp
  // Y-flipped readback mirrors. Populated via glBlitFramebuffer with inverted
  // dst-Y just before glReadPixels, so the PBO receives rows in image-top-down
  // order. Consumed only by the readback path — preview/video blits continue to
  // read fbo_ / rawFbo_ directly (GL-native).
  GLuint fullResReadbackFbo_ = 0;
  GLuint fullResReadbackTex_ = 0;
  GLuint rawReadbackFbo_     = 0;   // only allocated when rawW_ > 0
  GLuint rawReadbackTex_     = 0;
  ```

- [ ] **Step 3: Verify compile.** Run:

  ```bash
  cd /Users/shrek/work/cambrian/camera2_flutter_demo
  flutter build apk --debug
  ```

  Expected: build succeeds. (No behaviour changed; only declarations added.)

- [ ] **Step 4: Commit.**

  ```bash
  git add packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.h
  git commit -m "feat(gpu): declare Y-flipped readback mirror FBO handles

  No functional change yet — just declares fullResReadbackFbo_/Tex_ and
  rawReadbackFbo_/Tex_ for the upcoming mirror allocations in initGl().

  Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 2: Allocate + release the full-res readback mirror

**Files:**
- Modify: `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp` — `initGl()` around line 884–902 (after the existing `fbo_` allocation) and `releaseGl()` around line 1064 (next to the existing `fbo_` cleanup).

- [ ] **Step 1: Add the mirror allocation right after the existing full-res FBO block in `initGl()`.** Find the block starting with `// --- Full-res FBO ---` (around line 884). After `checkGlError("full-res FBO");` (line 902), insert:

  ```cpp
  // --- Full-res readback mirror (Y-flipped on blit) ---
  glGenTextures(1, &fullResReadbackTex_);
  glBindTexture(GL_TEXTURE_2D, fullResReadbackTex_);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width_, height_, 0,
               GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glBindTexture(GL_TEXTURE_2D, 0);

  glGenFramebuffers(1, &fullResReadbackFbo_);
  glBindFramebuffer(GL_FRAMEBUFFER, fullResReadbackFbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                         GL_TEXTURE_2D, fullResReadbackTex_, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
      LOGE("initGl: full-res readback mirror FBO incomplete");
      releaseGl();
      return false;
  }
  checkGlError("full-res readback mirror FBO");
  ```

  Mirrors the pattern of the existing `fbo_` allocation exactly, except with `GL_NEAREST` filtering (we never sample from this texture; the blit is 1:1 so nearest is appropriate and slightly cheaper).

- [ ] **Step 2: Add cleanup in `releaseGl()`.** Find the line `if (fbo_)            { glDeleteFramebuffers(1, &fbo_);         fbo_            = 0; }` (around line 1064). Immediately above it (so the mirror is freed before the source, matching the raw-before-full-res ordering already in that function), insert:

  ```cpp
  if (fullResReadbackPbo_ /* noop */ , fullResReadbackFbo_) {
      glDeleteFramebuffers(1, &fullResReadbackFbo_); fullResReadbackFbo_ = 0;
  }
  if (fullResReadbackTex_) { glDeleteTextures(1, &fullResReadbackTex_);  fullResReadbackTex_ = 0; }
  ```

  Correction — **actually insert this simpler version** (the `/* noop */` comma trick above is clutter; use the straightforward form):

  ```cpp
  if (fullResReadbackFbo_) { glDeleteFramebuffers(1, &fullResReadbackFbo_); fullResReadbackFbo_ = 0; }
  if (fullResReadbackTex_) { glDeleteTextures(1, &fullResReadbackTex_);      fullResReadbackTex_ = 0; }
  ```

- [ ] **Step 3: Build to confirm allocation compiles.** Run:

  ```bash
  cd /Users/shrek/work/cambrian/camera2_flutter_demo
  flutter build apk --debug 2>&1 | tail -10
  ```

  Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 4: Commit.**

  ```bash
  git add packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp
  git commit -m "feat(gpu): allocate full-res readback mirror FBO in initGl

  Mirrors fbo_'s dimensions and format. Unused so far; next commit wires
  the Y-flip blit + glReadPixels source change.

  Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 3: Allocate + release the raw readback mirror (conditional on `rawW_ > 0`)

**Files:**
- Modify: `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp` — inside the raw-init block around lines 978–1015 (after the existing raw FBO is created) and near line 1055 (raw release section).

- [ ] **Step 1: Add mirror allocation inside the raw-init block.** Find the existing raw FBO allocation (line ~992 `glGenFramebuffers(1, &rawFbo_);`). After the framebuffer-completeness check that sets `glBindFramebuffer(GL_FRAMEBUFFER, 0)` following success (around line 1001), and **before** the `// Raw PBOs (double-buffered)` comment (line 1004), insert:

  ```cpp
  // Raw readback mirror (Y-flipped on blit). Allocated only when raw is enabled,
  // same failure-cleanup pattern as rawFbo_.
  glGenTextures(1, &rawReadbackTex_);
  glBindTexture(GL_TEXTURE_2D, rawReadbackTex_);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, rawW_, rawH_, 0,
               GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glBindTexture(GL_TEXTURE_2D, 0);

  glGenFramebuffers(1, &rawReadbackFbo_);
  glBindFramebuffer(GL_FRAMEBUFFER, rawReadbackFbo_);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                         GL_TEXTURE_2D, rawReadbackTex_, 0);
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
      LOGE("initGl: raw readback mirror FBO incomplete — disabling raw");
      glBindFramebuffer(GL_FRAMEBUFFER, 0);
      rawW_ = 0;
  } else {
      glBindFramebuffer(GL_FRAMEBUFFER, 0);
      checkGlError("raw readback mirror FBO");
  }
  ```

- [ ] **Step 2: Extend the partial-failure cleanup block to include the new mirror.** Find the cleanup at ~lines 1019–1024:

  ```cpp
  if (rawW_ == 0) {
      if (rawPbo_[0])        { glDeleteBuffers(2, rawPbo_);              rawPbo_[0] = rawPbo_[1] = 0; }
      if (rawFbo_)           { glDeleteFramebuffers(1, &rawFbo_);        rawFbo_        = 0; }
      if (rawFboTexture_)    { glDeleteTextures(1, &rawFboTexture_);     rawFboTexture_ = 0; }
      if (rawProgram_)       { glDeleteProgram(rawProgram_);             rawProgram_    = 0; }
  }
  ```

  Add two lines for the mirror, maintaining the reverse-of-allocation order (mirror freed between PBO and rawFbo_ is fine since they are independent GL objects):

  ```cpp
  if (rawW_ == 0) {
      if (rawPbo_[0])        { glDeleteBuffers(2, rawPbo_);              rawPbo_[0] = rawPbo_[1] = 0; }
      if (rawReadbackFbo_)   { glDeleteFramebuffers(1, &rawReadbackFbo_); rawReadbackFbo_ = 0; }
      if (rawReadbackTex_)   { glDeleteTextures(1, &rawReadbackTex_);     rawReadbackTex_ = 0; }
      if (rawFbo_)           { glDeleteFramebuffers(1, &rawFbo_);        rawFbo_        = 0; }
      if (rawFboTexture_)    { glDeleteTextures(1, &rawFboTexture_);     rawFboTexture_ = 0; }
      if (rawProgram_)       { glDeleteProgram(rawProgram_);             rawProgram_    = 0; }
  }
  ```

- [ ] **Step 3: Extend the `releaseGl()` raw-cleanup block.** Find the existing block (around lines 1053–1057):

  ```cpp
  // Raw stream resources
  if (rawPbo_[0])        { glDeleteBuffers(2, rawPbo_);              rawPbo_[0] = rawPbo_[1] = 0; }
  if (rawFbo_)           { glDeleteFramebuffers(1, &rawFbo_);        rawFbo_        = 0; }
  if (rawFboTexture_)    { glDeleteTextures(1, &rawFboTexture_);     rawFboTexture_ = 0; }
  if (rawProgram_)       { glDeleteProgram(rawProgram_);             rawProgram_    = 0; }
  ```

  Replace with:

  ```cpp
  // Raw stream resources
  if (rawPbo_[0])        { glDeleteBuffers(2, rawPbo_);              rawPbo_[0] = rawPbo_[1] = 0; }
  if (rawReadbackFbo_)   { glDeleteFramebuffers(1, &rawReadbackFbo_); rawReadbackFbo_ = 0; }
  if (rawReadbackTex_)   { glDeleteTextures(1, &rawReadbackTex_);     rawReadbackTex_ = 0; }
  if (rawFbo_)           { glDeleteFramebuffers(1, &rawFbo_);        rawFbo_        = 0; }
  if (rawFboTexture_)    { glDeleteTextures(1, &rawFboTexture_);     rawFboTexture_ = 0; }
  if (rawProgram_)       { glDeleteProgram(rawProgram_);             rawProgram_    = 0; }
  ```

- [ ] **Step 4: Build to confirm.** Run:

  ```bash
  cd /Users/shrek/work/cambrian/camera2_flutter_demo
  flutter build apk --debug 2>&1 | tail -10
  ```

  Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 5: Commit.**

  ```bash
  git add packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp
  git commit -m "feat(gpu): allocate raw readback mirror FBO when rawW_ > 0

  Mirrors rawFbo_'s dimensions. Disabled with the raw stream if
  framebuffer-completeness fails, same fallback as rawFbo_. Not yet wired
  to the raw readback path.

  Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 4: Y-invert the tracker downsample blit

**Files:**
- Modify: `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp` at the existing `glBlitFramebuffer` call that populates `trackerFbo_`, around lines 401–406.

- [ ] **Step 1: Locate the existing blit.** Find:

  ```cpp
  // -----------------------------------------------------------------------
  // 3. Downscale: blit full-res FBO → tracker FBO (bilinear)
  // -----------------------------------------------------------------------
  glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, trackerFbo_);
  glBlitFramebuffer(
      0, 0, width_,        height_,
      0, 0, trackerWidth_, trackerHeight_,
      GL_COLOR_BUFFER_BIT, GL_LINEAR);
  checkGlError("blit to tracker FBO");
  ```

- [ ] **Step 2: Swap the destination Y coordinates to invert Y during the downsample.** Replace with:

  ```cpp
  // -----------------------------------------------------------------------
  // 3. Downscale: blit full-res FBO → tracker FBO (bilinear) with Y-invert
  //
  // Swap dst Y0/Y1 (from 0..trackerHeight_ to trackerHeight_..0) so the
  // tracker FBO holds a vertically-flipped view of fbo_. The subsequent
  // glReadPixels(trackerFbo_) returns bottom-up rows — which, combined with
  // this Y-flip, delivers image-top-down bytes to the tracker consumer and
  // matches what the user sees on the preview.
  // -----------------------------------------------------------------------
  glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, trackerFbo_);
  glBlitFramebuffer(
      0, 0, width_,        height_,
      0, trackerHeight_, trackerWidth_, 0,
      GL_COLOR_BUFFER_BIT, GL_LINEAR);
  checkGlError("blit to tracker FBO (Y-inverted)");
  ```

  The only functional diff is `0, 0, trackerWidth_, trackerHeight_` → `0, trackerHeight_, trackerWidth_, 0` for the dst rectangle.

- [ ] **Step 3: Build.** Run:

  ```bash
  flutter build apk --debug 2>&1 | tail -10
  ```

  Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 4: Commit.**

  ```bash
  git add packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp
  git commit -m "feat(gpu): Y-invert the tracker downsample blit

  Tracker sink consumers (currently the WB/BB patch sampler and any
  future FULL_RES→TRACKER consumer) now receive image-top-down rows
  matching what the preview shows.

  Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 5: Route full-res readback through the Y-flipped mirror

**Files:**
- Modify: `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp` at the full-res readback site around lines 473–481.

- [ ] **Step 1: Locate the current full-res readback block.**

  ```cpp
  if (hasTimerQuery_) glBeginQuery(GL_TIME_ELAPSED_EXT, timeQuery_[writeIdx]);

  // Full-res readback
  glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
  glBindBuffer(GL_PIXEL_PACK_BUFFER, fullResPbo_[writeIdx]);
  glReadPixels(0, 0, width_, height_, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  if (fullResFence_[writeIdx]) glDeleteSync(fullResFence_[writeIdx]);
  fullResFence_[writeIdx] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
  checkGlError("PBO readback full-res");
  ```

- [ ] **Step 2: Insert the Y-flip blit before the readback and change the read source.** Replace the block above with:

  ```cpp
  if (hasTimerQuery_) glBeginQuery(GL_TIME_ELAPSED_EXT, timeQuery_[writeIdx]);

  // Full-res readback — first mirror fbo_ into fullResReadbackFbo_ with dst Y
  // inverted so the subsequent (bottom-up) glReadPixels returns rows in
  // image-top-down order matching the preview.
  glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fullResReadbackFbo_);
  glBlitFramebuffer(0, 0, width_, height_,
                    0, height_, width_, 0,
                    GL_COLOR_BUFFER_BIT, GL_NEAREST);
  checkGlError("Y-flip blit to full-res readback mirror");

  glBindFramebuffer(GL_READ_FRAMEBUFFER, fullResReadbackFbo_);
  glBindBuffer(GL_PIXEL_PACK_BUFFER, fullResPbo_[writeIdx]);
  glReadPixels(0, 0, width_, height_, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  if (fullResFence_[writeIdx]) glDeleteSync(fullResFence_[writeIdx]);
  fullResFence_[writeIdx] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
  checkGlError("PBO readback full-res");
  ```

  Key change: `glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_)` → mirror blit → `glBindFramebuffer(GL_READ_FRAMEBUFFER, fullResReadbackFbo_)` before `glReadPixels`.

- [ ] **Step 3: Build.**

  ```bash
  flutter build apk --debug 2>&1 | tail -10
  ```

  Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 4: Commit.**

  ```bash
  git add packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp
  git commit -m "feat(gpu): Y-flip full-res readback via mirror FBO

  captureImage and any FULL_RES sink consumer now receives pixels in
  image-top-down order matching the preview. Y-flip is done via a
  glBlitFramebuffer with inverted dst-Y into fullResReadbackFbo_, then
  glReadPixels runs against that mirror.

  Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 6: Route raw readback through the Y-flipped mirror

**Files:**
- Modify: `packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp` at the raw readback site around lines 633–640.

- [ ] **Step 1: Locate the current raw readback block.**

  ```cpp
  // Issue async PBO readback for raw frame + insert fence
  glBindFramebuffer(GL_READ_FRAMEBUFFER, rawFbo_);
  glBindBuffer(GL_PIXEL_PACK_BUFFER, rawPbo_[rawWriteIdx]);
  glReadPixels(0, 0, rawW_, rawH_, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  if (rawFence_[rawWriteIdx]) glDeleteSync(rawFence_[rawWriteIdx]);
  rawFence_[rawWriteIdx] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  checkGlError("raw PBO readback");
  ```

- [ ] **Step 2: Insert the Y-flip blit and change the read source.** Replace with:

  ```cpp
  // Issue async PBO readback for raw frame — first mirror rawFbo_ into
  // rawReadbackFbo_ with dst Y inverted so the subsequent (bottom-up)
  // glReadPixels returns rows in image-top-down order, matching the
  // raw preview surface (and the processed preview).
  glBindFramebuffer(GL_READ_FRAMEBUFFER, rawFbo_);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, rawReadbackFbo_);
  glBlitFramebuffer(0, 0, rawW_, rawH_,
                    0, rawH_, rawW_, 0,
                    GL_COLOR_BUFFER_BIT, GL_NEAREST);
  checkGlError("Y-flip blit to raw readback mirror");

  glBindFramebuffer(GL_READ_FRAMEBUFFER, rawReadbackFbo_);
  glBindBuffer(GL_PIXEL_PACK_BUFFER, rawPbo_[rawWriteIdx]);
  glReadPixels(0, 0, rawW_, rawH_, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  if (rawFence_[rawWriteIdx]) glDeleteSync(rawFence_[rawWriteIdx]);
  rawFence_[rawWriteIdx] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
  glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  checkGlError("raw PBO readback");
  ```

- [ ] **Step 3: Build.**

  ```bash
  flutter build apk --debug 2>&1 | tail -10
  ```

  Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk`.

- [ ] **Step 4: Commit.**

  ```bash
  git add packages/cambrian_camera/android/src/main/cpp/src/GpuRenderer.cpp
  git commit -m "feat(gpu): Y-flip raw readback via mirror FBO

  Raw CV-sink consumers now receive pixels in image-top-down order,
  matching the raw preview and the processed preview.

  Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 7: Run existing instrumented/unit tests for no-regression

**Files:** None modified. Purely verification.

- [ ] **Step 1: Run JVM unit tests for the plugin.**

  ```bash
  cd /Users/shrek/work/cambrian/camera2_flutter_demo/android
  ./gradlew :cambrian_camera:testDebugUnitTest 2>&1 | tail -30
  ```

  Expected: tests pass. (The pre-existing failure in `teardown while recording emits error recording state` is known and unrelated — see earlier commit `f88a760`'s notes; it is NOT caused by this change.)

- [ ] **Step 2: (Optional, requires connected device) Run instrumented tests.**

  ```bash
  cd /Users/shrek/work/cambrian/camera2_flutter_demo/android
  ./gradlew :cambrian_camera:connectedDebugAndroidTest 2>&1 | tail -30
  ```

  Expected: `GpuSinkConsistencyTest` + `GpuRendererTest` pass (they verify sink-delivery byte counts and dimensions — unaffected by our orientation change).

  If no device connected or instrumented tests cannot run in the environment, skip this step and rely on Task 8's on-device visual check.

- [ ] **Step 3: No commit for this task** (no files changed).

---

## Task 8: On-device visual verification

**Files:** None. Manual testing.

- [ ] **Step 1: Install the debug APK and open the demo app.**

  ```bash
  flutter install 2>&1 | tail -5
  ```

  Expected: APK installs; app launches.

- [ ] **Step 2: Confirm preview is unchanged.** The processed preview must show the same landscape-with-Y-flip orientation it showed before this change. If it looks different (e.g. upside down or rotated differently), a coordinate got swapped incorrectly — abort and re-check Tasks 4–6.

- [ ] **Step 3: Confirm video recording is unchanged.** Tap RECORD, capture ~3s, tap STOP, play back. Frames must match the preview orientation (they should be unchanged from pre-fix behaviour since video blit is untouched).

- [ ] **Step 4: Confirm `captureImage` now matches preview.** Tap CAPTURE. Open the resulting file (Photos app on device, or `adb pull` and open on desktop). The saved image must display in the same orientation as the preview — including the Y-flip. Top of what you saw on screen = top of saved file. This is the primary fix criterion.

- [ ] **Step 5: Confirm WB/BB calibration still works.** Toggle CALIBRATE COLOR, run a calibration cycle (e.g. tap white balance on a neutral patch). The sampler averages a centered region so it is orientation-agnostic, but the round-trip (calibration → gain update → visible preview change) is a good end-to-end sanity check.

- [ ] **Step 6: Confirm `captureNaturalPicture` is untouched.** If the demo UI exposes this (separate from CAPTURE), trigger it. The saved file must continue to orient itself via EXIF based on device rotation — NOT with the Y-flip. This path has no GPU involvement, so no change is expected.

- [ ] **Step 7: No commit for this task.**

---

## Task 9: Update the architecture doc to reflect the new readback path

**Files:**
- Modify: `docs/architecture.md` — the "Fixed output transform: 90° rotation + vertical flip" subsection added in commit `fa2335d`.

- [ ] **Step 1: Locate the subsection** (search for the heading "Fixed output transform: 90° rotation + vertical flip" in `docs/architecture.md`).

- [ ] **Step 2: Update the paragraph about "Every GPU sink inherits this transform for free."** Find the paragraph that lists the four sinks (preview, video encoder, captureImage, raw). After the list, add:

  ```markdown

  **Readback-path Y-flip mirror FBOs.** The `captureImage` / tracker / raw
  glReadPixels paths go through small dedicated mirror FBOs
  (`fullResReadbackFbo_`, `rawReadbackFbo_`) populated by a
  `glBlitFramebuffer` with inverted dst-Y; the tracker path's existing
  downsample blit uses inverted dst-Y directly. This compensates for the
  GL → image-encoder row-order mismatch (`glReadPixels` returns bottom-up
  while encoders and CV consumers interpret rows top-down) so every sink
  sees the same orientation as the preview. Preview and video encoder
  paths do not touch the mirrors — they blit directly from `fbo_` /
  `rawFbo_` as before.
  ```

- [ ] **Step 3: Commit.**

  ```bash
  git add docs/architecture.md
  git commit -m "docs(arch): note Y-flipped readback mirror FBOs for sink consumers

  Co-Authored-By: Claude Sonnet 4.6 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 10: Final sanity-check and wrap-up

**Files:** None.

- [ ] **Step 1: Review the git log of this session.**

  ```bash
  git log --oneline -10
  ```

  Expected: 8 new commits from Tasks 1–6 and Task 9. Each focused on one concern, each message describes the why.

- [ ] **Step 2: Run `flutter analyze` to confirm no Dart-side regressions.**

  ```bash
  cd /Users/shrek/work/cambrian/camera2_flutter_demo
  flutter analyze lib/ packages/cambrian_camera/lib/ 2>&1 | tail -10
  ```

  Expected: only the 4 pre-existing `curly_braces_in_flow_control_structures` info-level warnings in `cambrian_camera_controller.dart` — none introduced by this change.

- [ ] **Step 3: Verify memory footprint expectation by inspecting actual FBO dims.** With the demo's default settings (`cropOutputSize: CameraSize(1600, 1200)`, `rawStreamHeight: 720`), the mirror footprint is:
  - `fullResReadbackTex_`: 1600 × 1200 × 4 = ~7.3 MB
  - `rawReadbackTex_`: ~1280 × 720 × 4 = ~3.5 MB
  - **Total extra GPU memory: ~11 MB** at demo defaults. ~50 MB worst case at full-sensor resolution.

  Grep the logs while the app is running for `GpuRenderer:` lines to confirm dimensions are reasonable:

  ```bash
  adb logcat | grep "CC/Renderer"
  ```

- [ ] **Step 4: No commit.** Report back to the user with the list of commits and confirm the APK at `build/app/outputs/flutter-apk/app-debug.apk` is ready for install + test.

---

## Self-review (done by plan author)

**Spec coverage:**
- "Every consumer except captureNaturalPicture sees the Y-flipped image" → Tasks 4 (tracker), 5 (full-res + captureImage), 6 (raw) cover all three `glReadPixels`-fed consumers. `captureNaturalPicture` is on a separate hardware-JPEG path (`CameraController.kt:1441`), untouched by all GL changes.
- "Same ops as preview, video" → no changes to preview/video blits; the mirror FBOs + Y-inverted blits only affect the readback path, so preview and video continue to display identically.
- "No new CPU overhead in hot paths" → the three blits are GPU-side; no CPU loop. Rejected alternative (CPU row-flip in `ImagePipeline.cpp`) explicitly documented.

**Placeholder scan:** No `TBD`/`TODO`/`implement later`/placeholder language in the plan. All code blocks are complete, all commands are runnable. One stumble in Task 2 Step 2 where an initial draft had a `/* noop */` trick — corrected inline to the plain form.

**Type/signature consistency:** Member handles used consistently: `fullResReadbackFbo_` / `fullResReadbackTex_` / `rawReadbackFbo_` / `rawReadbackTex_`. All lowercase-camel with trailing underscore, matching the existing convention of `fbo_` / `fboTexture_` / `rawFbo_` / `rawFboTexture_`.

**Task ordering:** Declarations (Task 1) before allocations (Tasks 2–3) before usage (Tasks 4–6). Tests/verification (Tasks 7–8) after all code changes. Doc update (Task 9) after verification confirms behaviour. Mirrors the existing codebase pattern of "header decls → init/release → runtime use".
