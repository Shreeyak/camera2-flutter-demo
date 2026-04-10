#pragma once
// GpuRenderer: manages OpenGL ES 3.0 rendering for the GPU camera pipeline.
//
// Responsibilities:
//   - EGL context + surface lifecycle (window + pbuffer fallback)
//   - OES texture → full-res FBO via single-pass fragment shader
//   - Downscale full-res FBO → tracker (480p) FBO via glBlitFramebuffer
//   - Preview output via EGL window surface blit + eglSwapBuffers
//   - Double-buffered async PBO readback for full-res and tracker outputs
//   - Thread-safe uniform updates (brightness, contrast, saturation, black balance)
//   - Optional raw (passthrough) stream: passthrough shader → rawFBO → rawPBOs
//     and optional raw preview window surface
//
// All GL calls must be issued from the same GL thread. GpuRenderer does not
// manage a thread — the caller (GpuPipeline.kt) is responsible for that.

#include "cambrian_camera_native.h"

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>  // GL_TEXTURE_EXTERNAL_OES

#include <functional>
#include <mutex>

namespace cam {

class GpuRenderer {
public:
    /// Construct with stream dimensions. Does not allocate GL resources.
    /// @param debugLevel  0=errors only, 1=lifecycle, 2=periodic/perf
    GpuRenderer(int width, int height, int debugLevel = 0);
    ~GpuRenderer();

    // Non-copyable, non-movable.
    GpuRenderer(const GpuRenderer&) = delete;
    GpuRenderer& operator=(const GpuRenderer&) = delete;

    /// Initialize EGL context, surfaces, shaders, FBOs, and PBOs.
    /// Must be called on the GL thread before any other GL methods.
    /// @param windowSurface      ANativeWindow for processed preview output; may be null.
    /// @param rawPreviewWindow   ANativeWindow for raw preview output; may be null.
    /// @param rawW               Raw stream width; 0 to disable raw path.
    /// @param rawH               Raw stream height; 0 to disable raw path.
    /// @return true on success; false if EGL or GL init fails (resources are cleaned up).
    bool init(EGLNativeWindowType windowSurface,
              ANativeWindow* rawPreviewWindow = nullptr,
              int rawW = 0, int rawH = 0);

    /// Release all GL and EGL resources. Idempotent — safe to call multiple times.
    /// Must be called on the GL thread.
    void release();

    /// Resize GL resources (FBOs, PBOs, textures) to new dimensions without touching
    /// the EGL display or context. Recompiles shaders and VBO.
    /// Must be called on the GL thread with the EGL context current.
    /// @param newW     New stream width.
    /// @param newH     New stream height.
    /// @param newRawW  New raw stream width; 0 to disable raw path.
    /// @param newRawH  New raw stream height; 0 to disable raw path.
    /// @return true on success; false if GL re-init fails.
    bool resize(int newW, int newH, int newRawW, int newRawH);

    /// Per-frame render + readback.
    ///
    /// Sequence:
    ///   1. Render OES texture → full-res FBO through the OES shader
    ///   2. Blit full-res FBO → tracker FBO (480p downscale, bilinear)
    ///   3. Blit full-res FBO → EGL window surface and swap buffers (preview)
    ///   4. Issue async PBO readbacks for full-res and tracker FBOs (writeIdx)
    ///   5. Map previous frame's PBOs (readIdx) and invoke callbacks
    ///   6. If raw stream enabled: render passthrough → rawFBO, blit to rawEGLSurface,
    ///      issue raw PBO readback, map previous raw PBO and invoke rawCb
    ///
    /// Must be called on the GL thread.
    ///
    /// @param oesTexture   GL_TEXTURE_EXTERNAL_OES texture name from SurfaceTexture
    /// @param texMatrix    4x4 row-major matrix from SurfaceTexture.getTransformMatrix()
    /// @param frameId      Monotonic frame counter
    /// @param meta         Per-frame sensor metadata
    /// @param fullResCb    Called with full-res RGBA data (pointer valid only during call),
    ///                     along with the frameId and metadata stored at write time
    /// @param trackerCb    Called with 480p RGBA data (pointer valid only during call),
    ///                     along with the frameId and metadata stored at write time
    /// @param rawCb        Called with raw (passthrough) RGBA data; not called when raw
    ///                     stream is disabled (rawW == 0) or on the first frame
    using RawCallback = std::function<void(const uint8_t* rgba, int w, int h,
                                           int stride, uint64_t frameId,
                                           const cam::FrameMetadata& meta)>;

    void drawAndReadback(
        GLuint oesTexture,
        const float texMatrix[16],
        uint64_t frameId,
        const cam::FrameMetadata& meta,
        std::function<void(const uint8_t*, int w, int h, int stride,
                           uint64_t frameId, const cam::FrameMetadata&)> fullResCb,
        std::function<void(const uint8_t*, int w, int h, int stride,
                           uint64_t frameId, const cam::FrameMetadata&)> trackerCb,
        RawCallback rawCb = nullptr);

    /// Update shader uniforms. Thread-safe; changes take effect on the next drawAndReadback().
    /// @param brightness   Brightness in [-1, 1]; 0 = identity. Positive: reverse-gamma lift
    ///                     (1 − (1−color)^(2.7^b)); negative: linear dim (color × (1 + b×0.75)).
    /// @param contrast     Contrast in [-1, 1]; 0 = identity. Uses a piecewise sigmoid: positive
    ///                     values squeeze the curve, negative values expand it. Denominator is
    ///                     guarded to prevent division by zero at the ±1 endpoints.
    /// @param saturation   Saturation adjustment [-1, 1]; 0 = identity (shader blends toward luma)
    /// @param blackR/G/B   Per-channel black-level subtraction [0, 0.5]; 0 = identity
    void setAdjustments(float brightness, float contrast, float saturation,
                        float blackR, float blackG, float blackB, float gamma);

    /// Attach or detach the MediaCodec encoder EGL surface.
    /// Must be called on the GL thread. Pass null to detach.
    void setEncoderSurface(ANativeWindow* newWindow);

    /// Rebind the raw preview EGL window surface to a new ANativeWindow.
    /// Call this on the GL thread when Flutter recreates the raw SurfaceProducer surface.
    /// @param newWindow  New ANativeWindow, or null to detach without rebinding.
    void rebindRawSurface(ANativeWindow* newWindow);

    /// Rebind the processed preview EGL window surface to a new ANativeWindow.
    /// Call this on the GL thread when Flutter recreates the SurfaceProducer surface.
    /// @param newWindow  New ANativeWindow, or null to detach without rebinding.
    void rebindPreviewSurface(ANativeWindow* newWindow);

    int trackerWidth()  const { return trackerWidth_; }
    int trackerHeight() const { return trackerHeight_; }

    /// Returns true when consecutive eglSwapBuffers failures have exceeded the threshold,
    /// indicating the preview surface is stale and should be rebound.
    bool needsPreviewRebind() const { return consecutiveSwapFailures_ >= kSwapFailureThreshold; }

    /// Reset the swap failure counter after rebinding the preview surface.
    void clearRebindFlag() { consecutiveSwapFailures_ = 0; }

    /// Sample the center 96×96 pixels of the full-res FBO and return the mean
    /// R, G, B as normalized [0, 1] floats.
    ///
    /// Must be called on the GL thread.
    /// Returns true and fills outR/outG/outB on success.
    /// Returns false (without touching the out-params) if the FBO is not yet
    /// initialised or no frame has been rendered yet — callers must treat this
    /// as an error rather than using the unset output values.
    bool sampleCenterPatch(float& outR, float& outG, float& outB);

private:
    int consecutiveSwapFailures_ = 0;
    static constexpr int kSwapFailureThreshold = 3;
    /// Fixed vertical resolution for the tracker downscale FBO. 480 p is chosen as the
    /// smallest height that preserves enough spatial detail for object/person detection
    /// while keeping GPU readback bandwidth well under 1 MB/frame.
    static constexpr int kTrackerHeight = 480;
    int debugLevel_ = 0;  ///< 0=errors only, 1=lifecycle, 2=periodic/perf
    int width_;
    int height_;
    int trackerWidth_;
    int trackerHeight_;

    // EGL objects
    EGLDisplay eglDisplay_        = EGL_NO_DISPLAY;
    EGLContext eglContext_         = EGL_NO_CONTEXT;
    EGLConfig  eglConfig_          = nullptr;          // stored for surface recreation
    EGLSurface eglWindowSurface_  = EGL_NO_SURFACE;   // preview window; may stay NO_SURFACE
    EGLSurface eglPbufferSurface_ = EGL_NO_SURFACE;   // 1×1 fallback; always created
    EGLSurface eglEncoderSurface_ = EGL_NO_SURFACE;   // MediaCodec encoder window; set at record start

    // GL program + geometry
    GLuint program_ = 0;
    GLuint vbo_     = 0;   // fullscreen quad (6 vertices × 2 floats)

    // Full-resolution FBO (width_ × height_)
    GLuint fbo_        = 0;
    GLuint fboTexture_ = 0;

    // Tracker FBO (trackerWidth_ × trackerHeight_)
    GLuint trackerFbo_        = 0;
    GLuint trackerTexture_    = 0;

    // Double-buffered PBOs for async readback
    GLuint fullResPbo_[2] = {0, 0};
    GLuint trackerPbo_[2] = {0, 0};
    int    pboIndex_        = 0;     // index being written this frame; read = 1 - pboIndex_
    bool   firstFrame_      = true;  // skip readback on frame 0 (no previous write)
    bool   loggedFirstFrame_ = true; // one-time first-frame log flag (per instance)
    uint64_t frameCount_    = 0;

    // Explicit GL sync fences — one per PBO slot, for full-res, tracker, and raw streams.
    // Inserted immediately after glReadPixels; waited on before glMapBufferRange.
    GLsync fullResFence_[2]  = {nullptr, nullptr};
    GLsync trackerFence_[2]  = {nullptr, nullptr};
    GLsync rawFence_[2]      = {nullptr, nullptr};

    // GL_TIME_ELAPSED timing queries (double-buffered) — measure DMA enqueue cost.
    // Only used when GL_EXT_disjoint_timer_query is available (see hasTimerQuery_).
    bool     hasTimerQuery_ = false;  ///< true if GL_EXT_disjoint_timer_query is supported
    GLuint   timeQuery_[2]  = {0, 0};
    uint64_t stallCount_    = 0;  ///< frames where fence was not yet signalled at map time

    // Metadata stored alongside each PBO write to avoid off-by-one delivery
    struct PboMeta { uint64_t frameId; cam::FrameMetadata meta; };
    PboMeta pboMeta_[2] = {};

    // Raw stream resources (all zero/null when raw is disabled)
    int rawW_ = 0;
    int rawH_ = 0;
    GLuint rawProgram_    = 0;
    GLuint rawFbo_        = 0;
    GLuint rawFboTexture_ = 0;
    GLuint rawPbo_[2]      = {0, 0};
    bool   rawFirstFrame_  = true;
    PboMeta rawPboMeta_[2] = {};
    EGLSurface rawEGLSurface_ = EGL_NO_SURFACE;

    // Cached uniform locations for passthrough program
    GLint rawUTexture_   = -1;
    GLint rawUTexMatrix_ = -1;

    // Pending uniforms — written by setAdjustments(), read under uniformMu_ at draw time
    std::mutex uniformMu_;
    float brightness_      = 0.f;
    float contrast_        = 0.f;   // 0 = identity; shader applies uContrast + 1.0
    float saturation_      = 0.f;   // 0 = identity; shader applies uSaturation + 1.0
    float blackBalance_[3] = {0.f, 0.f, 0.f};
    float gamma_           = 1.f;

    // Cached uniform locations
    GLint uTexture_      = -1;
    GLint uTexMatrix_    = -1;
    GLint uBrightness_   = -1;
    GLint uContrast_     = -1;
    GLint uSaturation_   = -1;
    GLint uBlackBalance_ = -1;
    GLint uGamma_        = -1;
    GLint uCropScale_    = -1;
    GLint uCropOffset_   = -1;

    // -- Private helpers ----------------------------------------------------------

    /// Initialize EGL display, config, context, and surfaces.
    /// @param rawPreviewWindow  Optional ANativeWindow for raw preview EGL surface.
    /// @param rawW              Raw stream width (stored to rawW_); 0 = disabled.
    /// @param rawH              Raw stream height (stored to rawH_); 0 = disabled.
    bool initEgl(EGLNativeWindowType windowSurface,
                 ANativeWindow* rawPreviewWindow, int rawW, int rawH);

    /// Initialize GL objects (shaders, VBO, FBOs, PBOs). Assumes EGL is current.
    bool initGl();

    /// Delete all GL objects. Called by release() and on initGl() failure.
    void releaseGl();

    /// Destroy EGL surfaces and context. Called by release().
    void releaseEgl();

    /// Compile a single shader stage. Returns 0 on failure.
    GLuint compileShader(GLenum type, const char* src);

    /// Link a vertex + fragment shader into a program. Returns 0 on failure.
    GLuint linkProgram(GLuint vert, GLuint frag);
};

} // namespace cam
