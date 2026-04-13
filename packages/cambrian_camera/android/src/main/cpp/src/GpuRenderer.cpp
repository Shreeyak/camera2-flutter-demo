// GpuRenderer.cpp — OpenGL ES 3.0 render + PBO readback for the GPU camera pipeline.
//
// Frame sequence (per drawAndReadback call):
//   1. Snapshot uniforms
//   2. Render OES texture → full-res FBO
//   3. Blit full-res → tracker FBO (480p, bilinear)
//   4. Blit full-res → EGL window surface (preview) + eglSwapBuffers
//   5. Async PBO readback for full-res and tracker (writeIdx)
//   6. Map previous frame PBOs (readIdx) and invoke callbacks
//   7. Advance pboIndex_
//   8. Raw stream path: copy mapped full-res PBO bytes to raw output buffer

#include "GpuRenderer.h"

#include <android/log.h>
#include <chrono>
#include <cinttypes>
#include <cstring>

#define LOG_TAG "CC/Renderer"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

// ---------------------------------------------------------------------------
// Shader sources
// ---------------------------------------------------------------------------

static const char* kVertSrc = R"glsl(
#version 300 es
in  vec2 aPos;
out vec2 vTexCoord;
void main() {
    vTexCoord   = aPos * 0.5 + 0.5;   // [-1,1] -> [0,1]
    gl_Position = vec4(aPos, 0.0, 1.0);
}
)glsl";

static const char* kFragSrc = R"glsl(
#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;

uniform samplerExternalOES uTexture;
uniform mat4  uTexMatrix;
uniform float uBrightness;
uniform float uContrast;
uniform float uSaturation;
uniform vec3  uBlackBalance;
uniform float uGamma;
uniform vec2  uCropScale;
uniform vec2  uCropOffset;

in  vec2 vTexCoord;
out vec4 fragColor;

const vec3 kLuma = vec3(0.299, 0.587, 0.114);

// Brightness: gamma-curve lift (positive) or linear dim (negative).
// uBrightness in [-1, +1]; 0 = identity.
// Input clamped to [0,1] so pow() never receives a negative base.
vec3 applyBrightness(vec3 color, float b) {
    color = clamp(color, 0.0, 1.0);
    if (b >= 0.0) {
        float gamma = pow(2.7, b);
        return 1.0 - pow(1.0 - color, vec3(gamma));
    } else {
        float k = 1.0 + b * 0.75;
        return color * k;
    }
}

// Contrast adjustment in [-1, +1]; 0 = identity.
// Denominator guarded with max(..., 1e-3) to prevent division by zero at c = ±1.
vec3 applyContrast(vec3 color, float c) {
    // UI slider range [-1,1] scaled to [-0.5,0.5] — full sigmoid at ±1
    // produces unusable extremes (solid grey / blown out).
    c = clamp(c, -1.0, 1.0) * 0.5;
    vec3 e = color - 0.5;
    if (c >= 0.0) {
        float k = 1.0 - c;
        vec3 denom = max(k + abs(2.0 * e) * (1.0 - k), vec3(1e-3));
        return 0.5 + e / denom;
    } else {
        float k = 1.0 + c;
        vec3 denom = max(vec3(1.0) - abs(2.0 * e) * (1.0 - k), vec3(1e-3));
        return 0.5 + e * k / denom;
    }
}

// Saturation: blend toward luminance.
// uSaturation in [-1, +1]; 0 = identity, -1 = greyscale, +1 = double sat.
vec3 applySaturation(vec3 color, float s) {
    float lum = dot(color, kLuma);
    return clamp(mix(vec3(lum), color, 1.0 + s), 0.0, 1.0);
}

// Gamma correction. Clamp g away from zero to avoid division by zero.
vec3 applyGamma(vec3 color, float g) {
    return pow(color, vec3(1.0 / max(g, 0.001)));
}

void main() {
    vec2 uv    = vTexCoord * uCropScale + uCropOffset;
    vec2 texUv = (uTexMatrix * vec4(uv, 0.0, 1.0)).xy;
    vec4 color = texture(uTexture, texUv);
    vec3 rgb   = color.rgb;

    rgb = max(rgb - uBlackBalance, 0.0);
    rgb = applyBrightness(rgb, uBrightness);
    rgb = applyContrast(rgb, uContrast);
    rgb = applySaturation(rgb, uSaturation);
    rgb = applyGamma(max(rgb, 0.0), uGamma);

    fragColor = vec4(clamp(rgb, 0.0, 1.0), color.a);
}
)glsl";

// Passthrough fragment shader: pure sensor output, no color adjustments.
// Used by the raw stream path.
static const char* kRawFragSrc = R"glsl(
#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
in vec2 vTexCoord;
out vec4 fragColor;
uniform samplerExternalOES uTexture;
uniform mat4 uTexMatrix;
void main() {
    vec2 texUv = (uTexMatrix * vec4(vTexCoord, 0.0, 1.0)).xy;
    fragColor = vec4(texture(uTexture, texUv).rgb, 1.0);
}
)glsl";

// ---------------------------------------------------------------------------
// Fullscreen quad: 2 triangles covering NDC [-1,1]x[-1,1]
// ---------------------------------------------------------------------------

static const float kQuad[] = {
    -1.f, -1.f,   1.f, -1.f,   -1.f,  1.f,
     1.f, -1.f,   1.f,  1.f,   -1.f,  1.f,
};

// ---------------------------------------------------------------------------
// GL error helper
// ---------------------------------------------------------------------------

static void checkGlError(const char* tag) {
    GLenum err;
    while ((err = glGetError()) != GL_NO_ERROR) {
        LOGE("%s: GL error 0x%x", tag, err);
    }
}

// ---------------------------------------------------------------------------
// Explicit fence wait helper
//
// Returns true if the fence is signalled (or was null — first frame).
// Returns false if the DMA timed out or the wait failed; caller must skip map.
// ---------------------------------------------------------------------------

static bool waitFence(GLsync& fence, const char* label) {
    if (!fence) return true;  // no fence yet (first frame)
    GLenum result = glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, 0);
    if (result == GL_WAIT_FAILED) {
        LOGE("PBO fence wait failed: %s — skipping readback", label);
        glDeleteSync(fence);
        fence = nullptr;
        return false;
    }
    if (result == GL_TIMEOUT_EXPIRED) {
        // DMA not done yet — wait up to 8ms before giving up
        result = glClientWaitSync(fence, GL_SYNC_FLUSH_COMMANDS_BIT, 8'000'000);
        if (result == GL_TIMEOUT_EXPIRED) {
            LOGE("PBO fence timeout after 8ms: %s — skipping readback", label);
            // Do not delete the fence here; leave it so releaseGl() cleans it up.
            return false;
        }
        if (result == GL_WAIT_FAILED) {
            LOGE("PBO fence wait failed (retry): %s — skipping readback", label);
            glDeleteSync(fence);
            fence = nullptr;
            return false;
        }
    }
    glDeleteSync(fence);
    fence = nullptr;
    return true;
}

} // anonymous namespace

// ---------------------------------------------------------------------------
// cam::GpuRenderer
// ---------------------------------------------------------------------------

namespace cam {

GpuRenderer::GpuRenderer(int width, int height, int debugLevel)
    : debugLevel_(debugLevel), width_(width), height_(height),
      sourceWidth_(width), sourceHeight_(height)
{
    if (height_ <= 0) {
        LOGE("GpuRenderer: invalid height %d — clamping to 1 to avoid division by zero", height_);
        height_ = 1;
    }
    // Compute tracker FBO size: fixed kTrackerHeight rows, width scaled to preserve aspect,
    // rounded to nearest even width to keep YUV chroma-plane alignment.
    trackerHeight_ = kTrackerHeight;
    trackerWidth_  = ((width_ * kTrackerHeight / height_) + 1) & ~1;
    if (debugLevel_ >= 1) {
        LOGI("GpuRenderer: stream %dx%d, tracker %dx%d",
             width_, height_, trackerWidth_, trackerHeight_);
    }
}

GpuRenderer::~GpuRenderer() {
    // release() is idempotent; call it to be safe if the caller forgot.
    release();
}

// ---------------------------------------------------------------------------
// Public: init / release
// ---------------------------------------------------------------------------

bool GpuRenderer::init(EGLNativeWindowType windowSurface,
                       ANativeWindow* rawPreviewWindow,
                       int rawW, int rawH) {
    if (!initEgl(windowSurface, rawPreviewWindow, rawW, rawH)) {
        LOGE("init: EGL setup failed");
        return false;
    }
    if (!initGl()) {
        LOGE("init: GL setup failed");
        releaseEgl();
        return false;
    }
    if (debugLevel_ >= 1) {
        LOGI("init: OK");
    }
    return true;
}

void GpuRenderer::release() {
    if (debugLevel_ >= 1) {
        LOGI("release");
    }
    // Bind the EGL context before GL teardown so all glDelete* calls have a valid context.
    // The destructor can be invoked off the GL thread during exception handling or unexpected
    // object destruction; eglMakeCurrent ensures GL resources are freed safely.
    if (eglDisplay_ != EGL_NO_DISPLAY &&
        eglContext_ != EGL_NO_CONTEXT &&
        eglPbufferSurface_ != EGL_NO_SURFACE) {
        if (!eglMakeCurrent(eglDisplay_, eglPbufferSurface_, eglPbufferSurface_, eglContext_)) {
            LOGE("release: eglMakeCurrent failed (0x%x) — GL teardown may be incomplete",
                 eglGetError());
        }
    }
    releaseGl();
    releaseEgl();
}

bool GpuRenderer::resize(int newW, int newH, int newRawW, int newRawH) {
    if (debugLevel_ >= 1) LOGI("resize: %dx%d raw=%dx%d", newW, newH, newRawW, newRawH);
    releaseGl();
    width_         = newW;
    height_        = (newH > 0) ? newH : 1;
    sourceWidth_   = width_;        // resize() swaps the camera session — source = output
    sourceHeight_  = height_;
    // Compute tracker FBO size: fixed kTrackerHeight rows, width scaled to preserve aspect,
    // rounded to nearest even width to keep YUV chroma-plane alignment.
    trackerHeight_ = kTrackerHeight;
    trackerWidth_  = ((width_ * kTrackerHeight / height_) + 1) & ~1;
    // releaseGl() zeros rawW_/rawH_ — restore before initGl() or the raw path stays disabled.
    rawW_ = newRawW;
    rawH_ = newRawH;
    return initGl();
}

// ---------------------------------------------------------------------------
// Public: change output dims without touching source dims
//
// Called on the GL thread whenever CamSettings.cropOutputSize changes. The
// SurfaceTexture source stays at (sourceWidth_, sourceHeight_); only the
// output FBO / tracker FBO / raw FBO / PBOs are reallocated. drawAndReadback()
// computes uCropScale / uCropOffset from the output-to-source ratio so the
// shader samples a centered sub-rectangle of the source texture.
//
// Raw dims are passed by the caller (not recomputed here) because the caller
// owns the raw aspect policy. releaseGl() zeros rawW_/rawH_, so we rewrite
// them from the args before initGl() so the raw pipeline survives the resize.
// ---------------------------------------------------------------------------
bool GpuRenderer::setCropOutput(int outW, int outH, int newRawW, int newRawH) {
    if (debugLevel_ >= 1) {
        LOGI("setCropOutput: %dx%d raw=%dx%d (source %dx%d)",
             outW, outH, newRawW, newRawH, sourceWidth_, sourceHeight_);
    }
    if (outW <= 0 || outH <= 0) {
        LOGE("setCropOutput: invalid dims %dx%d", outW, outH);
        return false;
    }
    if (outW > sourceWidth_ || outH > sourceHeight_) {
        LOGE("setCropOutput: output %dx%d exceeds source %dx%d",
             outW, outH, sourceWidth_, sourceHeight_);
        return false;
    }
    releaseGl();
    width_         = outW;
    height_        = outH;
    trackerHeight_ = kTrackerHeight;
    trackerWidth_  = ((width_ * kTrackerHeight / height_) + 1) & ~1;
    rawW_          = newRawW;   // restore after releaseGl() zeroed it
    rawH_          = newRawH;
    // sourceWidth_ / sourceHeight_ intentionally not touched.
    return initGl();
}

// ---------------------------------------------------------------------------
// Public: per-frame render + readback
// ---------------------------------------------------------------------------

void GpuRenderer::drawAndReadback(
    GLuint oesTexture,
    const float texMatrix[16],
    uint64_t frameId,
    const cam::FrameMetadata& meta,
    std::function<void(const uint8_t*, int w, int h, int stride,
                       uint64_t frameId, const cam::FrameMetadata&)> fullResCb,
    std::function<void(const uint8_t*, int w, int h, int stride,
                       uint64_t frameId, const cam::FrameMetadata&)> trackerCb,
    RawCallback rawCb)
{
    // -----------------------------------------------------------------------
    // 1. Snapshot uniforms under the lock so the GL thread gets a consistent copy.
    // -----------------------------------------------------------------------
    float brightness, contrast, saturation, blackBalance[3], gamma;
    {
        std::lock_guard<std::mutex> lk(uniformMu_);
        brightness       = brightness_;
        contrast         = contrast_;
        saturation       = saturation_;
        gamma            = gamma_;
        blackBalance[0]  = blackBalance_[0];
        blackBalance[1]  = blackBalance_[1];
        blackBalance[2]  = blackBalance_[2];
    }

    frameCount_++;
    if (debugLevel_ >= 2 && frameCount_ % 300 == 0) {
        LOGD("frame #%" PRIu64, frameCount_);
    }

    const int writeIdx = pboIndex_;
    const int readIdx  = 1 - pboIndex_;

    // -----------------------------------------------------------------------
    // 2. Render OES texture → full-res FBO
    // -----------------------------------------------------------------------
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glViewport(0, 0, width_, height_);

    glUseProgram(program_);

    // Upload per-frame uniforms
    glUniformMatrix4fv(uTexMatrix_, 1, GL_FALSE, texMatrix);
    glUniform1f(uBrightness_,   brightness);
    glUniform1f(uContrast_,     contrast);
    glUniform1f(uSaturation_,   saturation);
    glUniform3f(uBlackBalance_, blackBalance[0], blackBalance[1], blackBalance[2]);
    glUniform1f(uGamma_,        gamma);
    // Center crop: the shader samples a (width_/sourceWidth_, height_/sourceHeight_)
    // sub-rectangle of the source texture, centered. When width_ == sourceWidth_
    // this degenerates to identity (no crop).
    const float sx = static_cast<float>(width_)  / static_cast<float>(sourceWidth_);
    const float sy = static_cast<float>(height_) / static_cast<float>(sourceHeight_);
    glUniform2f(uCropScale_,  sx, sy);
    glUniform2f(uCropOffset_, (1.f - sx) * 0.5f, (1.f - sy) * 0.5f);

    // Bind the external OES texture to texture unit 0
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, oesTexture);
    glUniform1i(uTexture_, 0);

    // Draw fullscreen quad
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
    glDrawArrays(GL_TRIANGLES, 0, 6);
    glDisableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);

    checkGlError("draw to full-res FBO");

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

    // -----------------------------------------------------------------------
    // 4. Blit full-res FBO → EGL window surface (preview) + swap
    // -----------------------------------------------------------------------
    if (eglWindowSurface_ != EGL_NO_SURFACE) {
        // Switch rendering surface to the window
        if (!eglMakeCurrent(eglDisplay_, eglWindowSurface_, eglWindowSurface_, eglContext_)) {
            LOGE("drawAndReadback: eglMakeCurrent to window failed (0x%x)", eglGetError());
        } else {
            // Blit full-res FBO into the default framebuffer (= window surface)
            glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
            glBlitFramebuffer(
                0, 0, width_, height_,
                0, 0, width_, height_,
                GL_COLOR_BUFFER_BIT, GL_NEAREST);
            checkGlError("blit to window");

            if (!eglSwapBuffers(eglDisplay_, eglWindowSurface_)) {
                EGLint err = eglGetError();
                LOGE("drawAndReadback: eglSwapBuffers (processed) failed: 0x%x", err);
                consecutiveSwapFailures_++;
                if (err == EGL_BAD_SURFACE || err == EGL_BAD_NATIVE_WINDOW) {
                    eglWindowSurface_ = EGL_NO_SURFACE;
                }
            } else {
                consecutiveSwapFailures_ = 0;
            }
        }

        // Switch back to pbuffer so GL state is consistent for readback
        eglMakeCurrent(eglDisplay_, eglPbufferSurface_, eglPbufferSurface_, eglContext_);
    }

    // -----------------------------------------------------------------------
    // 4b. Blit tone-mapped FBO → encoder surface (MediaCodec input, if set)
    // -----------------------------------------------------------------------
    if (eglEncoderSurface_ != EGL_NO_SURFACE) {
        if (!eglMakeCurrent(eglDisplay_, eglEncoderSurface_, eglEncoderSurface_, eglContext_)) {
            LOGE("drawAndReadback: eglMakeCurrent (encoder) failed (0x%x)", eglGetError());
        } else {
            glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
            glBlitFramebuffer(
                0, 0, width_, height_,
                0, 0, width_, height_,
                GL_COLOR_BUFFER_BIT, GL_NEAREST);
            checkGlError("blit to encoder");
            if (!eglSwapBuffers(eglDisplay_, eglEncoderSurface_)) {
                LOGE("drawAndReadback: eglSwapBuffers (encoder) failed (0x%x)", eglGetError());
            }
            if (!eglMakeCurrent(eglDisplay_, eglPbufferSurface_, eglPbufferSurface_, eglContext_)) {
                LOGE("drawAndReadback: eglMakeCurrent (pbuffer restore) failed (0x%x)", eglGetError());
            }
        }
    }

    // -----------------------------------------------------------------------
    // 5. Issue async PBO readbacks (GPU→PBO DMA, no CPU stall)
    //    Wrap processed-path readPixels calls with a GL_TIME_ELAPSED_EXT query to measure
    //    how long the GPU spent setting up the DMA transfer.
    //    Insert explicit GL sync fences after each readback so we can wait on
    //    them precisely before mapping (see step 6).
    // -----------------------------------------------------------------------

    if (hasTimerQuery_) glBeginQuery(GL_TIME_ELAPSED_EXT, timeQuery_[writeIdx]);

    // Full-res readback
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo_);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, fullResPbo_[writeIdx]);
    glReadPixels(0, 0, width_, height_, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    if (fullResFence_[writeIdx]) glDeleteSync(fullResFence_[writeIdx]);
    fullResFence_[writeIdx] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    checkGlError("PBO readback full-res");

    // Tracker readback
    glBindFramebuffer(GL_READ_FRAMEBUFFER, trackerFbo_);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, trackerPbo_[writeIdx]);
    glReadPixels(0, 0, trackerWidth_, trackerHeight_, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    if (trackerFence_[writeIdx]) glDeleteSync(trackerFence_[writeIdx]);
    trackerFence_[writeIdx] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    checkGlError("PBO readback tracker");

    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    if (hasTimerQuery_) glEndQuery(GL_TIME_ELAPSED_EXT);

    // Store metadata for the frame whose readback was just issued
    pboMeta_[writeIdx] = {frameId, meta};

    // -----------------------------------------------------------------------
    // 6. Map previous frame's PBOs and invoke callbacks
    //
    // Use pboMeta_[readIdx] — the metadata stored when that PBO was written —
    // so the pixel data and metadata always refer to the same frame.
    //
    // GL_QUERY_RESULT blocks until the result is ready; since a full frame has
    // elapsed since the query was issued, the result is expected to be available immediately.
    // Then wait explicitly on the fences before mapping.
    // -----------------------------------------------------------------------
    if (!firstFrame_) {
        const auto& storedMeta = pboMeta_[readIdx];

        // Read timing query for the readIdx slot (issued one full frame ago).
        // Use 32-bit variant (GLES3 does not expose glGetQueryObjectui64v);
        // a GLuint holds up to ~4.3s in nanoseconds — sufficient for per-frame DMA timing.
        GLuint dmaEnqueueNs32 = 0;
        if (hasTimerQuery_) glGetQueryObjectuiv(timeQuery_[readIdx], GL_QUERY_RESULT, &dmaEnqueueNs32);
        const double dmaEnqueueNs = static_cast<double>(dmaEnqueueNs32);

        // Wait on fences; measure CPU stall time.
        auto t0 = std::chrono::steady_clock::now();

        bool fullResReady = waitFence(fullResFence_[readIdx], "full-res");
        bool trackerReady = waitFence(trackerFence_[readIdx], "tracker");

        auto stallNs = std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - t0).count();

        if (stallNs > 500'000) {  // > 0.5ms — fence was not yet signalled
            stallCount_++;
            LOGW("PBO stall: waited %.2f ms (frame %" PRIu64 ", stall rate %.1f%%)",
                 stallNs / 1e6, frameId,
                 100.0 * stallCount_ / frameCount_);
        }

        if (debugLevel_ >= 1 && frameCount_ % 300 == 0) {  // every ~10s at 30fps
            LOGI("PBO diagnostics: dma_enqueue=%.2f ms  stall_rate=%.1f%%  "
                 "stalls=%" PRIu64 "/%" PRIu64,
                 dmaEnqueueNs / 1e6,
                 100.0 * stallCount_ / frameCount_,
                 stallCount_, frameCount_);
        }

        // Full-res callback
        if (fullResReady) {
            glBindBuffer(GL_PIXEL_PACK_BUFFER, fullResPbo_[readIdx]);
            auto* fullPtr = static_cast<const uint8_t*>(
                glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0,
                                 static_cast<GLsizeiptr>(width_) * height_ * 4,
                                 GL_MAP_READ_BIT));
            if (fullPtr) {
                fullResCb(fullPtr, width_, height_, width_ * 4,
                          storedMeta.frameId, storedMeta.meta);
                glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
            } else {
                LOGE("drawAndReadback: failed to map full-res PBO[%d]", readIdx);
            }
            checkGlError("map full-res PBO");
        }

        // Tracker callback
        if (trackerReady) {
            glBindBuffer(GL_PIXEL_PACK_BUFFER, trackerPbo_[readIdx]);
            auto* trackPtr = static_cast<const uint8_t*>(
                glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0,
                                 static_cast<GLsizeiptr>(trackerWidth_) * trackerHeight_ * 4,
                                 GL_MAP_READ_BIT));
            if (trackPtr) {
                trackerCb(trackPtr, trackerWidth_, trackerHeight_, trackerWidth_ * 4,
                          storedMeta.frameId, storedMeta.meta);
                glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
            } else {
                LOGE("drawAndReadback: failed to map tracker PBO[%d]", readIdx);
            }
            checkGlError("map tracker PBO");
        }

        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    }

    // -----------------------------------------------------------------------
    // 7. Advance double-buffer index
    // -----------------------------------------------------------------------
    pboIndex_   = 1 - pboIndex_;
    if (loggedFirstFrame_) {
        LOGI("GpuRenderer: first frame rendered successfully (%dx%d)", width_, height_);
        loggedFirstFrame_ = false;
    }
    firstFrame_ = false;

    // -----------------------------------------------------------------------
    // 8. Raw stream: passthrough render → rawFBO, optional preview blit,
    //    double-buffered PBO readback
    // -----------------------------------------------------------------------
    if (rawW_ > 0) {
        const int rawWriteIdx = pboIndex_;        // already advanced above
        const int rawReadIdx  = 1 - pboIndex_;

        // Render passthrough shader → rawFBO
        glBindFramebuffer(GL_FRAMEBUFFER, rawFbo_);
        glViewport(0, 0, rawW_, rawH_);
        glUseProgram(rawProgram_);

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_EXTERNAL_OES, oesTexture);
        glUniform1i(rawUTexture_, 0);
        glUniformMatrix4fv(rawUTexMatrix_, 1, GL_FALSE, texMatrix);

        glBindBuffer(GL_ARRAY_BUFFER, vbo_);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
        glDrawArrays(GL_TRIANGLES, 0, 6);
        glDisableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, 0);
        checkGlError("raw passthrough render");

        // Optional raw preview window blit
        if (rawEGLSurface_ != EGL_NO_SURFACE) {
            eglMakeCurrent(eglDisplay_, rawEGLSurface_, rawEGLSurface_, eglContext_);
            glBindFramebuffer(GL_READ_FRAMEBUFFER, rawFbo_);
            glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
            glBlitFramebuffer(0, 0, rawW_, rawH_,
                              0, 0, rawW_, rawH_,
                              GL_COLOR_BUFFER_BIT, GL_NEAREST);
            if (!eglSwapBuffers(eglDisplay_, rawEGLSurface_)) {
                EGLint err = eglGetError();
                LOGE("drawAndReadback: eglSwapBuffers (raw) failed: 0x%x", err);
                if (err == EGL_BAD_SURFACE || err == EGL_BAD_NATIVE_WINDOW) {
                    rawEGLSurface_ = EGL_NO_SURFACE;
                }
            }
            eglMakeCurrent(eglDisplay_, eglPbufferSurface_, eglPbufferSurface_, eglContext_);
            checkGlError("raw preview blit");
        }

        // Issue async PBO readback for raw frame + insert fence
        glBindFramebuffer(GL_READ_FRAMEBUFFER, rawFbo_);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, rawPbo_[rawWriteIdx]);
        glReadPixels(0, 0, rawW_, rawH_, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
        if (rawFence_[rawWriteIdx]) glDeleteSync(rawFence_[rawWriteIdx]);
        rawFence_[rawWriteIdx] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        checkGlError("raw PBO readback");

        // Store metadata alongside PBO write
        rawPboMeta_[rawWriteIdx] = {frameId, meta};

        // Map previous raw PBO and invoke callback (after explicit fence wait)
        if (!rawFirstFrame_ && rawCb) {
            const auto& rawMeta = rawPboMeta_[rawReadIdx];
            if (waitFence(rawFence_[rawReadIdx], "raw")) {
                glBindBuffer(GL_PIXEL_PACK_BUFFER, rawPbo_[rawReadIdx]);
                auto* rawPtr = static_cast<const uint8_t*>(
                    glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0,
                                     static_cast<GLsizeiptr>(rawW_) * rawH_ * 4,
                                     GL_MAP_READ_BIT));
                if (rawPtr) {
                    rawCb(rawPtr, rawW_, rawH_, rawW_ * 4,
                          rawMeta.frameId, rawMeta.meta);
                    glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
                } else {
                    LOGE("drawAndReadback: failed to map raw PBO[%d]", rawReadIdx);
                }
                glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
                checkGlError("map raw PBO");
            }
        }
        rawFirstFrame_ = false;
    }
}

// ---------------------------------------------------------------------------
// Public: uniform update (thread-safe)
// ---------------------------------------------------------------------------

void GpuRenderer::setAdjustments(float brightness, float contrast, float saturation,
                                  float blackR, float blackG, float blackB, float gamma)
{
    std::lock_guard<std::mutex> lk(uniformMu_);
    brightness_      = brightness;
    contrast_        = contrast;
    saturation_      = saturation;
    blackBalance_[0] = blackR;
    blackBalance_[1] = blackG;
    blackBalance_[2] = blackB;
    gamma_           = gamma;
}

// ---------------------------------------------------------------------------
// Public: raw surface rebind
// ---------------------------------------------------------------------------

void GpuRenderer::setEncoderSurface(ANativeWindow* newWindow) {
    if (eglDisplay_ == EGL_NO_DISPLAY) {
        LOGE("setEncoderSurface: EGL not initialized");
        return;
    }
    if (eglEncoderSurface_ != EGL_NO_SURFACE) {
        eglDestroySurface(eglDisplay_, eglEncoderSurface_);
        eglEncoderSurface_ = EGL_NO_SURFACE;
    }
    if (newWindow != nullptr) {
        eglEncoderSurface_ = eglCreateWindowSurface(eglDisplay_, eglConfig_, newWindow, nullptr);
        if (eglEncoderSurface_ == EGL_NO_SURFACE) {
            LOGE("setEncoderSurface: eglCreateWindowSurface failed (0x%x)", eglGetError());
        } else {
            LOGI("setEncoderSurface: encoder EGL surface set");
        }
    }
}

void GpuRenderer::rebindRawSurface(ANativeWindow* newWindow) {
    if (eglDisplay_ == EGL_NO_DISPLAY) {
        LOGE("rebindRawSurface: EGL not initialized");
        return;
    }
    if (rawEGLSurface_ != EGL_NO_SURFACE) {
        eglDestroySurface(eglDisplay_, rawEGLSurface_);
        rawEGLSurface_ = EGL_NO_SURFACE;
    }
    if (newWindow != nullptr && rawW_ > 0) {
        rawEGLSurface_ = eglCreateWindowSurface(eglDisplay_, eglConfig_, newWindow, nullptr);
        if (rawEGLSurface_ == EGL_NO_SURFACE) {
            LOGE("rebindRawSurface: eglCreateWindowSurface failed (0x%x)", eglGetError());
        } else {
            LOGI("rebindRawSurface: raw EGL surface rebound");
        }
    }
}

// ---------------------------------------------------------------------------
// Public: preview surface rebind
// ---------------------------------------------------------------------------

void GpuRenderer::rebindPreviewSurface(ANativeWindow* newWindow) {
    if (eglDisplay_ == EGL_NO_DISPLAY) {
        LOGE("rebindPreviewSurface: EGL not initialized");
        return;
    }
    if (eglWindowSurface_ != EGL_NO_SURFACE) {
        eglDestroySurface(eglDisplay_, eglWindowSurface_);
        eglWindowSurface_ = EGL_NO_SURFACE;
    }
    if (newWindow != nullptr) {
        eglWindowSurface_ = eglCreateWindowSurface(eglDisplay_, eglConfig_, newWindow, nullptr);
        if (eglWindowSurface_ == EGL_NO_SURFACE) {
            LOGE("rebindPreviewSurface: eglCreateWindowSurface failed (0x%x)", eglGetError());
        } else {
            LOGI("rebindPreviewSurface: preview EGL surface rebound");
        }
    }
}

// ---------------------------------------------------------------------------
// Private: EGL setup
// ---------------------------------------------------------------------------

bool GpuRenderer::initEgl(EGLNativeWindowType windowSurface,
                          ANativeWindow* rawPreviewWindow,
                          int rawW, int rawH) {
    eglDisplay_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (eglDisplay_ == EGL_NO_DISPLAY) {
        LOGE("initEgl: eglGetDisplay failed");
        return false;
    }

    EGLint major = 0, minor = 0;
    if (!eglInitialize(eglDisplay_, &major, &minor)) {
        LOGE("initEgl: eglInitialize failed");
        return false;
    }
    LOGI("initEgl: EGL %d.%d", major, minor);

    // Config: RGBA8888, GLES3, window + pbuffer surfaces
    const EGLint configAttribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RED_SIZE,   8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE,  8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE
    };
    EGLConfig config;
    EGLint numConfigs = 0;
    if (!eglChooseConfig(eglDisplay_, configAttribs, &config, 1, &numConfigs)
            || numConfigs == 0) {
        LOGE("initEgl: eglChooseConfig failed (numConfigs=%d)", numConfigs);
        return false;
    }
    eglConfig_ = config;

    const EGLint contextAttribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE
    };
    eglContext_ = eglCreateContext(eglDisplay_, config, EGL_NO_CONTEXT, contextAttribs);
    if (eglContext_ == EGL_NO_CONTEXT) {
        LOGE("initEgl: eglCreateContext failed");
        return false;
    }

    // Always create a 1×1 pbuffer surface so we can make the context current
    // even when no window surface exists (offscreen-only mode).
    const EGLint pbufferAttribs[] = {
        EGL_WIDTH,  1,
        EGL_HEIGHT, 1,
        EGL_NONE
    };
    eglPbufferSurface_ = eglCreatePbufferSurface(eglDisplay_, config, pbufferAttribs);
    if (eglPbufferSurface_ == EGL_NO_SURFACE) {
        LOGE("initEgl: eglCreatePbufferSurface failed");
        eglDestroyContext(eglDisplay_, eglContext_);
        eglContext_ = EGL_NO_CONTEXT;
        return false;
    }

    // Create window surface only if a window was provided
    if (windowSurface != nullptr) {
        eglWindowSurface_ = eglCreateWindowSurface(eglDisplay_, config, windowSurface, nullptr);
        if (eglWindowSurface_ == EGL_NO_SURFACE) {
            LOGE("initEgl: eglCreateWindowSurface failed — continuing offscreen-only");
            // Non-fatal: preview just won't be shown
        }
    }

    // Store raw dimensions (checked by initGl to decide whether to allocate raw resources)
    rawW_ = rawW;
    rawH_ = rawH;

    // Create raw preview window surface if requested
    if (rawW_ > 0 && rawH_ > 0 && rawPreviewWindow != nullptr) {
        rawEGLSurface_ = eglCreateWindowSurface(eglDisplay_, config, rawPreviewWindow, nullptr);
        if (rawEGLSurface_ == EGL_NO_SURFACE) {
            LOGE("initEgl: eglCreateWindowSurface for raw preview failed — raw preview disabled");
            // Non-fatal: raw path continues without preview blit
        }
    }

    // Make the pbuffer current; window surface is only bound during preview blit
    if (!eglMakeCurrent(eglDisplay_, eglPbufferSurface_, eglPbufferSurface_, eglContext_)) {
        LOGE("initEgl: eglMakeCurrent failed");
        releaseEgl();
        return false;
    }

    return true;
}

// ---------------------------------------------------------------------------
// Private: GL resource setup
// ---------------------------------------------------------------------------

bool GpuRenderer::initGl() {
    // --- Shaders ---
    GLuint vert = compileShader(GL_VERTEX_SHADER,   kVertSrc);
    GLuint frag = compileShader(GL_FRAGMENT_SHADER, kFragSrc);
    if (!vert || !frag) {
        glDeleteShader(vert);
        glDeleteShader(frag);
        return false;
    }
    program_ = linkProgram(vert, frag);
    // Shaders are no longer needed once linked
    glDeleteShader(vert);
    glDeleteShader(frag);
    if (!program_) return false;

    // Cache uniform locations
    uTexture_      = glGetUniformLocation(program_, "uTexture");
    uTexMatrix_    = glGetUniformLocation(program_, "uTexMatrix");
    uBrightness_   = glGetUniformLocation(program_, "uBrightness");
    uContrast_     = glGetUniformLocation(program_, "uContrast");
    uSaturation_   = glGetUniformLocation(program_, "uSaturation");
    uBlackBalance_ = glGetUniformLocation(program_, "uBlackBalance");
    uGamma_        = glGetUniformLocation(program_, "uGamma");
    uCropScale_    = glGetUniformLocation(program_, "uCropScale");
    uCropOffset_   = glGetUniformLocation(program_, "uCropOffset");

    // --- Fullscreen quad VBO ---
    glGenBuffers(1, &vbo_);
    glBindBuffer(GL_ARRAY_BUFFER, vbo_);
    glBufferData(GL_ARRAY_BUFFER, sizeof(kQuad), kQuad, GL_STATIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    checkGlError("VBO setup");

    // --- Full-res FBO ---
    glGenTextures(1, &fboTexture_);
    glBindTexture(GL_TEXTURE_2D, fboTexture_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width_, height_, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glBindTexture(GL_TEXTURE_2D, 0);

    glGenFramebuffers(1, &fbo_);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, fboTexture_, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        LOGE("initGl: full-res FBO incomplete");
        releaseGl();
        return false;
    }
    checkGlError("full-res FBO");

    // --- Tracker FBO ---
    glGenTextures(1, &trackerTexture_);
    glBindTexture(GL_TEXTURE_2D, trackerTexture_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, trackerWidth_, trackerHeight_, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glBindTexture(GL_TEXTURE_2D, 0);

    glGenFramebuffers(1, &trackerFbo_);
    glBindFramebuffer(GL_FRAMEBUFFER, trackerFbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, trackerTexture_, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        LOGE("initGl: tracker FBO incomplete");
        releaseGl();
        return false;
    }
    checkGlError("tracker FBO");

    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    // --- Full-res PBOs (double-buffered) ---
    glGenBuffers(2, fullResPbo_);
    for (int i = 0; i < 2; ++i) {
        glBindBuffer(GL_PIXEL_PACK_BUFFER, fullResPbo_[i]);
        glBufferData(GL_PIXEL_PACK_BUFFER,
                     (GLsizeiptr)(width_ * height_ * 4),
                     nullptr, GL_STREAM_READ);
    }
    checkGlError("full-res PBOs");

    // --- Tracker PBOs (double-buffered) ---
    glGenBuffers(2, trackerPbo_);
    for (int i = 0; i < 2; ++i) {
        glBindBuffer(GL_PIXEL_PACK_BUFFER, trackerPbo_[i]);
        glBufferData(GL_PIXEL_PACK_BUFFER,
                     (GLsizeiptr)(trackerWidth_ * trackerHeight_ * 4),
                     nullptr, GL_STREAM_READ);
    }
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    checkGlError("tracker PBOs");

    // --- Timing queries (double-buffered GL_TIME_ELAPSED_EXT) ---
    // Only allocate queries when the extension is actually available.
    {
        const char* exts = reinterpret_cast<const char*>(glGetString(GL_EXTENSIONS));
        hasTimerQuery_ = exts && strstr(exts, "GL_EXT_disjoint_timer_query");
    }
    if (hasTimerQuery_) {
        glGenQueries(2, timeQuery_);
        checkGlError("timing queries");
    }

    // --- Raw stream resources (only when raw dimensions were set in initEgl) ---
    if (rawW_ > 0 && rawH_ > 0) {
        // Compile and link passthrough program
        GLuint rawVert = compileShader(GL_VERTEX_SHADER,   kVertSrc);
        GLuint rawFrag = compileShader(GL_FRAGMENT_SHADER, kRawFragSrc);
        if (!rawVert || !rawFrag) {
            glDeleteShader(rawVert);
            glDeleteShader(rawFrag);
            LOGE("initGl: raw passthrough shader compile failed — disabling raw");
            rawW_ = 0;
        } else {
            rawProgram_ = linkProgram(rawVert, rawFrag);
            glDeleteShader(rawVert);
            glDeleteShader(rawFrag);
            if (!rawProgram_) {
                LOGE("initGl: raw passthrough program link failed — disabling raw");
                rawW_ = 0;
            }
        }

        if (rawW_ > 0) {
            // Cache uniform locations
            rawUTexture_   = glGetUniformLocation(rawProgram_, "uTexture");
            rawUTexMatrix_ = glGetUniformLocation(rawProgram_, "uTexMatrix");

            // Raw FBO with RGBA8 color attachment
            glGenTextures(1, &rawFboTexture_);
            glBindTexture(GL_TEXTURE_2D, rawFboTexture_);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, rawW_, rawH_, 0,
                         GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glBindTexture(GL_TEXTURE_2D, 0);

            glGenFramebuffers(1, &rawFbo_);
            glBindFramebuffer(GL_FRAMEBUFFER, rawFbo_);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                   GL_TEXTURE_2D, rawFboTexture_, 0);
            if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
                LOGE("initGl: raw FBO incomplete — disabling raw");
                glBindFramebuffer(GL_FRAMEBUFFER, 0);
                rawW_ = 0;
            } else {
                glBindFramebuffer(GL_FRAMEBUFFER, 0);
                checkGlError("raw FBO");

                // Raw PBOs (double-buffered)
                glGenBuffers(2, rawPbo_);
                for (int i = 0; i < 2; ++i) {
                    glBindBuffer(GL_PIXEL_PACK_BUFFER, rawPbo_[i]);
                    glBufferData(GL_PIXEL_PACK_BUFFER,
                                 (GLsizeiptr)(rawW_ * rawH_ * 4),
                                 nullptr, GL_STREAM_READ);
                }
                glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
                checkGlError("raw PBOs");

                LOGD("GpuRenderer: raw stream enabled %dx%d", rawW_, rawH_);
            }

            // If any step above disabled raw, clean up partially-allocated resources
            if (rawW_ == 0) {
                if (rawPbo_[0])        { glDeleteBuffers(2, rawPbo_);              rawPbo_[0] = rawPbo_[1] = 0; }
                if (rawFbo_)           { glDeleteFramebuffers(1, &rawFbo_);        rawFbo_        = 0; }
                if (rawFboTexture_)    { glDeleteTextures(1, &rawFboTexture_);     rawFboTexture_ = 0; }
                if (rawProgram_)       { glDeleteProgram(rawProgram_);             rawProgram_    = 0; }
            }
        }
    }

    LOGI("initGl: OK");
    return true;
}

// ---------------------------------------------------------------------------
// Private: GL + EGL teardown (idempotent)
// ---------------------------------------------------------------------------

void GpuRenderer::releaseGl() {
    // Log lifetime stall summary before teardown
    if (debugLevel_ > 0) {
        LOGI("GpuRenderer teardown: total frames=%" PRIu64 "  pbo_stalls=%" PRIu64
             "  stall_rate=%.1f%%",
             frameCount_, stallCount_,
             frameCount_ > 0 ? 100.0 * stallCount_ / frameCount_ : 0.0);
    }

    // Delete explicit fences and timing queries
    for (int i = 0; i < 2; ++i) {
        if (fullResFence_[i])  { glDeleteSync(fullResFence_[i]);     fullResFence_[i]  = nullptr; }
        if (trackerFence_[i])  { glDeleteSync(trackerFence_[i]);     trackerFence_[i]  = nullptr; }
        if (rawFence_[i])      { glDeleteSync(rawFence_[i]);          rawFence_[i]      = nullptr; }
        if (hasTimerQuery_ && timeQuery_[i]) { glDeleteQueries(1, &timeQuery_[i]);  timeQuery_[i] = 0; }
    }

    // Raw stream resources
    if (rawPbo_[0])        { glDeleteBuffers(2, rawPbo_);              rawPbo_[0] = rawPbo_[1] = 0; }
    if (rawFbo_)           { glDeleteFramebuffers(1, &rawFbo_);        rawFbo_        = 0; }
    if (rawFboTexture_)    { glDeleteTextures(1, &rawFboTexture_);     rawFboTexture_ = 0; }
    if (rawProgram_)       { glDeleteProgram(rawProgram_);             rawProgram_    = 0; }

    // Processed pipeline resources
    if (fullResPbo_[0]) { glDeleteBuffers(2, fullResPbo_); fullResPbo_[0] = fullResPbo_[1] = 0; }
    if (trackerPbo_[0]) { glDeleteBuffers(2, trackerPbo_); trackerPbo_[0] = trackerPbo_[1] = 0; }
    if (trackerFbo_)     { glDeleteFramebuffers(1, &trackerFbo_);  trackerFbo_     = 0; }
    if (trackerTexture_) { glDeleteTextures(1, &trackerTexture_);  trackerTexture_ = 0; }
    if (fbo_)            { glDeleteFramebuffers(1, &fbo_);         fbo_            = 0; }
    if (fboTexture_)     { glDeleteTextures(1, &fboTexture_);      fboTexture_     = 0; }
    if (vbo_)            { glDeleteBuffers(1, &vbo_);              vbo_            = 0; }
    if (program_)        { glDeleteProgram(program_);              program_        = 0; }

    // Reset per-frame state so init() can be called again
    pboIndex_      = 0;
    firstFrame_    = true;
    rawW_          = 0;
    rawH_          = 0;
    rawFirstFrame_ = true;
    stallCount_    = 0;
    frameCount_    = 0;
}

void GpuRenderer::releaseEgl() {
    if (eglDisplay_ == EGL_NO_DISPLAY) return;

    eglMakeCurrent(eglDisplay_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

    if (eglEncoderSurface_ != EGL_NO_SURFACE) {
        eglDestroySurface(eglDisplay_, eglEncoderSurface_);
        eglEncoderSurface_ = EGL_NO_SURFACE;
    }
    if (rawEGLSurface_ != EGL_NO_SURFACE) {
        eglDestroySurface(eglDisplay_, rawEGLSurface_);
        rawEGLSurface_ = EGL_NO_SURFACE;
    }
    if (eglWindowSurface_ != EGL_NO_SURFACE) {
        eglDestroySurface(eglDisplay_, eglWindowSurface_);
        eglWindowSurface_ = EGL_NO_SURFACE;
    }
    if (eglPbufferSurface_ != EGL_NO_SURFACE) {
        eglDestroySurface(eglDisplay_, eglPbufferSurface_);
        eglPbufferSurface_ = EGL_NO_SURFACE;
    }
    if (eglContext_ != EGL_NO_CONTEXT) {
        eglDestroyContext(eglDisplay_, eglContext_);
        eglContext_ = EGL_NO_CONTEXT;
    }

    eglTerminate(eglDisplay_);
    eglDisplay_ = EGL_NO_DISPLAY;
}

// ---------------------------------------------------------------------------
// Private: shader helpers
// ---------------------------------------------------------------------------

GLuint GpuRenderer::compileShader(GLenum type, const char* src) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &src, nullptr);
    glCompileShader(shader);

    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        GLint len = 0;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &len);
        if (len > 1) {
            std::string log(len, '\0');
            glGetShaderInfoLog(shader, len, nullptr, log.data());
            LOGE("compileShader(%s): %s",
                 type == GL_VERTEX_SHADER ? "vert" : "frag",
                 log.c_str());
        }
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

GLuint GpuRenderer::linkProgram(GLuint vert, GLuint frag) {
    GLuint prog = glCreateProgram();
    glAttachShader(prog, vert);
    glAttachShader(prog, frag);
    // Bind the single vertex attribute aPos to location 0 before linking
    glBindAttribLocation(prog, 0, "aPos");
    glLinkProgram(prog);

    GLint ok = 0;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        GLint len = 0;
        glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &len);
        if (len > 1) {
            std::string log(len, '\0');
            glGetProgramInfoLog(prog, len, nullptr, log.data());
            LOGE("linkProgram: %s", log.c_str());
        }
        glDeleteProgram(prog);
        return 0;
    }
    return prog;
}

// ---------------------------------------------------------------------------
// Public: center-patch sampling
// ---------------------------------------------------------------------------

/**
 * @brief Samples the center 96×96 pixel patch of the rendered frame and writes
 *        trimmed-mean RGB values to the output references.
 *
 * Binds the full-resolution FBO, calls glReadPixels to fetch RGBA pixel data,
 * then computes a 15% trimmed mean per channel using an O(n) histogram approach
 * to suppress hot pixels, specular highlights, and dust artefacts.
 *
 * @param[out] outR  Trimmed-mean red channel value, normalised to [0.0, 1.0].
 * @param[out] outG  Trimmed-mean green channel value, normalised to [0.0, 1.0].
 * @param[out] outB  Trimmed-mean blue channel value, normalised to [0.0, 1.0].
 * @return true on success; false if fbo_ is uninitialised, no frame has been
 *         rendered yet, the framebuffer is smaller than the patch, or a GL
 *         error occurs during readback.
 *
 * @note Must be called on the GL thread. glReadPixels blocks until the GPU
 *       completes the readback.
 */
bool GpuRenderer::sampleCenterPatch(float& outR, float& outG, float& outB) {
    // fbo_ == 0: pipeline not yet initialised.
    // firstFrame_: GPU has not rendered any frame yet — readback would return garbage.
    if (fbo_ == 0 || firstFrame_) {
        return false;
    }

    constexpr int   kPatchW       = 96;
    constexpr int   kPatchH       = 96;
    constexpr int   kN            = kPatchW * kPatchH;   // 9 216 pixels
    constexpr int   kBytesPerPixel = 4;                  // GL_RGBA: 1 byte per channel (R=0, G=1, B=2, A=3)
    // Discard the lowest and highest 15% of values per channel before averaging.
    // This removes hot pixels, specular highlights, and dust artefacts without
    // requiring a full sort — the histogram approach is O(n) for 8-bit data.
    constexpr float kTrimFraction = 0.15f;               // discard bottom/top 15% per channel
    constexpr int   kTrimCount    = static_cast<int>(kN * kTrimFraction);  // 1 382

    // Guard against framebuffers smaller than the patch — glReadPixels with a
    // negative origin or a patch that exceeds the surface is undefined behaviour.
    if (width_ < kPatchW || height_ < kPatchH) {
        return false;
    }

    const int cx = (width_  - kPatchW) / 2;
    const int cy = (height_ - kPatchH) / 2;

    uint8_t pixels[kN * kBytesPerPixel];  // 36 864 bytes — well within GL-thread stack

    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glReadPixels(cx, cy, kPatchW, kPatchH, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
    const GLenum readError = glGetError();
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    if (readError != GL_NO_ERROR) {
        return false;
    }

    // Build per-channel histograms (256 bins — full uint8_t range).
    int histR[256]{}, histG[256]{}, histB[256]{};
    for (int i = 0; i < kN; i++) {
        histR[pixels[i * kBytesPerPixel + 0]]++;
        histG[pixels[i * kBytesPerPixel + 1]]++;
        histB[pixels[i * kBytesPerPixel + 2]]++;
    }

    // Trimmed mean from histogram: skip kTrimCount pixels from each end,
    // accumulate the remainder, normalise to [0, 1].
    auto histTrimmedMean = [kN](const int hist[256], int trimCount) -> float {
        const int lo = trimCount;
        const int hi = kN - trimCount;
        uint64_t sum  = 0;
        int      count = 0;
        int      cumulative = 0;
        for (int v = 0; v < 256; v++) {
            const int n         = hist[v];
            const int end       = cumulative + n;
            const int inc_start = cumulative < lo ? lo : cumulative;
            const int inc_end   = end > hi ? hi : end;
            if (inc_end > inc_start) {
                sum   += static_cast<uint64_t>(v) * (inc_end - inc_start);
                count += (inc_end - inc_start);
            }
            cumulative = end;
        }
        // count == 0 is impossible with 15% trim on 9 216 pixels, but guard anyway.
        // 255.0f: uint8_t max — normalises the histogram bin index to [0.0, 1.0].
        return count > 0 ? static_cast<float>(sum) / (count * 255.0f) : -1.0f;
    };

    outR = histTrimmedMean(histR, kTrimCount);
    outG = histTrimmedMean(histG, kTrimCount);
    outB = histTrimmedMean(histB, kTrimCount);

    // A negative result from histTrimmedMean means the degenerate case fired.
    if (outR < 0.0f || outG < 0.0f || outB < 0.0f) return false;

    return true;
}

} // namespace cam
