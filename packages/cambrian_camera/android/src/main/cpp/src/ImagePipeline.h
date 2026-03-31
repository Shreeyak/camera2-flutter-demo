#pragma once
// Internal header for the image pipeline.
// Phase 3: identity passthrough (processFrame, kept for reference).
// Phase 4: YUV_420_888 → RGBA conversion + per-frame saturation (processFrameYuv).

#include <android/native_window.h>
#include <cstdint>
#include <mutex>

namespace cam {

/// User-adjustable processing parameters. All fields have identity defaults.
/// setParams() is thread-safe; the per-frame loop reads a snapshot under paramsMu_.
/// Phase 4 uses only saturation. Future phases will apply the remaining fields.
struct ProcessingParams {
    float blackR = 0.f, blackG = 0.f, blackB = 0.f;  // [0, 0.5] per-channel black level
    float gamma           = 1.f;                       // [0.1, 4.0]; 1.0 = identity
    float histBlackPoint  = 0.f;                       // [0, 1]
    float histWhitePoint  = 1.f;                       // [0, 1]
    bool  autoStretch     = false;
    float autoStretchLow  = 0.01f;
    float autoStretchHigh = 0.99f;
    float brightness      = 0.f;                       // [-1, 1]; 0.0 = identity
    float saturation      = 1.f;                       // [0, 3]; 1.0 = identity
};

/// Image pipeline: receives frames from the Android camera, applies post-processing,
/// and outputs processed RGBA frames to an ANativeWindow (Flutter SurfaceProducer).
///
/// Thread safety:
///   - setPreviewWindow() / processFrame() / processFrameYuv() share mutex_ for
///     ANativeWindow access.
///   - setParams() / processFrameYuv() share paramsMu_ for ProcessingParams access.
///   - processFrameYuv() acquires paramsMu_ (params snapshot) then releases it before
///     acquiring mutex_ (window blit); the two locks are never held simultaneously.
class ImagePipeline {
public:
    /// Construct with an optional preview window (acquires its own ANativeWindow reference).
    explicit ImagePipeline(ANativeWindow* window);

    /// Releases the ANativeWindow reference held by this pipeline.
    ~ImagePipeline();

    // Non-copyable, non-movable — owns a raw pointer resource.
    ImagePipeline(const ImagePipeline&) = delete;
    ImagePipeline& operator=(const ImagePipeline&) = delete;

    /// Replace the preview surface (e.g. after Flutter PlatformView recreation).
    void setPreviewWindow(ANativeWindow* window);

    /// Phase 3 identity pipeline (RGBA passthrough). Kept for reference; not called in Phase 4.
    void processFrame(const uint8_t* data, int width, int height, int stride);

    /// Phase 4 pipeline: convert YUV_420_888 planes → RGBA, apply saturation, write to preview.
    ///
    /// @param yData         Y plane pointer (one byte per pixel, yRowStride bytes/row).
    /// @param yRowStride    Row stride of Y plane in bytes.
    /// @param uData         U (Cb) plane pointer (one byte per chroma sample).
    /// @param vData         V (Cr) plane pointer (one byte per chroma sample).
    /// @param uvRowStride   Row stride of U and V planes in bytes.
    /// @param uvPixelStride Pixel stride of U/V planes: 1 for I420, 2 for NV12/NV21.
    /// @param width         Frame width in pixels.
    /// @param height        Frame height in pixels.
    void processFrameYuv(const uint8_t* yData, int yRowStride,
                         const uint8_t* uData, const uint8_t* vData,
                         int uvRowStride, int uvPixelStride,
                         int width, int height);

    /// Atomically update processing parameters. Takes effect on the next frame.
    void setParams(const ProcessingParams& p);

private:
    std::mutex mutex_;
    ANativeWindow* previewWindow_ = nullptr;
    int lastWidth_  = 0;
    int lastHeight_ = 0;

    std::mutex paramsMu_;
    ProcessingParams params_;  // protected by paramsMu_
};

} // namespace cam
