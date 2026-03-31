// Phase 3 identity image pipeline implementation.
// Receives RGBA frames via processFrame() and blits them row-by-row into an
// ANativeWindow (the Flutter preview Surface).  No image processing is applied.

#include "ImagePipeline.h"

#include <android/log.h>
#include <android/native_window.h>
#include <algorithm> // std::min
#include <cstring>   // memcpy

#define TAG  "CambrianCamera"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace cam {

ImagePipeline::ImagePipeline(ANativeWindow* window) : previewWindow_(window) {
    if (previewWindow_) {
        // Increment the refcount so the pipeline owns its own reference
        // independently of whatever the caller holds.
        ANativeWindow_acquire(previewWindow_);
        LOGD("ImagePipeline created, window=%p", previewWindow_);
    }
}

ImagePipeline::~ImagePipeline() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (previewWindow_) {
        ANativeWindow_release(previewWindow_);
        previewWindow_ = nullptr;
        LOGD("ImagePipeline destroyed");
    }
}

void ImagePipeline::setPreviewWindow(ANativeWindow* window) {
    std::lock_guard<std::mutex> lock(mutex_);
    // Release the old surface before storing the new one.
    if (previewWindow_) {
        ANativeWindow_release(previewWindow_);
        previewWindow_ = nullptr;
    }

    previewWindow_ = window;
    // Reset cached dimensions so setBuffersGeometry runs on the next frame.
    lastWidth_  = 0;
    lastHeight_ = 0;

    if (previewWindow_) {
        ANativeWindow_acquire(previewWindow_);
        LOGD("ImagePipeline preview window updated, window=%p", previewWindow_);
    } else {
        LOGD("ImagePipeline preview window cleared (nullptr)");
    }
}

void ImagePipeline::processFrame(const uint8_t* data,
                                  int width,
                                  int height,
                                  int stride) {
    std::lock_guard<std::mutex> lock(mutex_);

    // Nothing to render into.
    if (!previewWindow_) {
        return;
    }

    // Configure the surface buffer geometry only when dimensions change.
    // ANativeWindow_setBuffersGeometry is not cheap — skip it on the hot path.
    if (width != lastWidth_ || height != lastHeight_) {
        // WINDOW_FORMAT_RGBA_8888 = 4 bytes per pixel.
        int32_t result = ANativeWindow_setBuffersGeometry(
                previewWindow_, width, height, WINDOW_FORMAT_RGBA_8888);
        if (result != 0) {
            LOGE("ANativeWindow_setBuffersGeometry failed: %d", result);
            return;
        }
        lastWidth_  = width;
        lastHeight_ = height;
    }

    // Lock the surface to obtain a writable pixel buffer.
    ANativeWindow_Buffer buffer;
    int32_t result = ANativeWindow_lock(previewWindow_, &buffer, /*inOutDirtyBounds=*/nullptr);
    if (result != 0) {
        LOGE("ANativeWindow_lock failed: %d", result);
        return;
    }

    // buffer.stride is in pixels; multiply by 4 (bytes per RGBA pixel) to get
    // the destination row stride in bytes.
    const int dstStride = buffer.stride * 4;

    // Source row stride is already in bytes (as passed from Kotlin/ImageReader).
    const int srcStride = stride;

    // Clamp to the locked buffer's actual dimensions — ANativeWindow_lock may
    // return a buffer smaller than requested (e.g. during surface resize).
    const int safeHeight = std::min(height, static_cast<int>(buffer.height));
    const int safeWidth  = std::min(width,  static_cast<int>(buffer.width));
    const int copyWidth  = safeWidth * 4;

    auto* dst = reinterpret_cast<uint8_t*>(buffer.bits);
    const uint8_t* src = data;

    for (int row = 0; row < safeHeight; ++row) {
        memcpy(dst, src, copyWidth);
        dst += dstStride;
        src += srcStride;
    }

    // Unlock and submit the buffer to the display compositor.
    ANativeWindow_unlockAndPost(previewWindow_);
}

void ImagePipeline::setParams(const ProcessingParams& p) {
    std::lock_guard<std::mutex> lock(paramsMu_);
    params_ = p;
}

void ImagePipeline::processFrameYuv(
        const uint8_t* yData, int yRowStride,
        const uint8_t* uData, const uint8_t* vData,
        int uvRowStride, int uvPixelStride,
        int width, int height) {

    // Read a local copy of params so the inner loop does not hold paramsMu_.
    ProcessingParams p;
    {
        std::lock_guard<std::mutex> plk(paramsMu_);
        p = params_;
    }

    std::lock_guard<std::mutex> lock(mutex_);

    if (!previewWindow_) {
        return;
    }

    // Configure surface geometry only when dimensions change (expensive call; keep off hot path).
    if (width != lastWidth_ || height != lastHeight_) {
        int32_t res = ANativeWindow_setBuffersGeometry(
                previewWindow_, width, height, WINDOW_FORMAT_RGBA_8888);
        if (res != 0) {
            LOGE("processFrameYuv: setBuffersGeometry failed: %d", res);
            return;
        }
        lastWidth_  = width;
        lastHeight_ = height;
        LOGD("processFrameYuv: geometry set to %dx%d", width, height);
    }

    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(previewWindow_, &buf, nullptr) != 0) {
        LOGE("processFrameYuv: ANativeWindow_lock failed");
        return;
    }

    const float sat       = p.saturation;
    const int   dstStride = buf.stride * 4;   // buf.stride is in pixels; multiply for bytes
    auto* dst = reinterpret_cast<uint8_t*>(buf.bits);

    // Clamp to locked buffer dimensions in case of surface resize races.
    const int safeH = std::min(height, static_cast<int>(buf.height));
    const int safeW = std::min(width,  static_cast<int>(buf.width));

    for (int row = 0; row < safeH; ++row) {
        uint8_t* dstRow = dst + row * dstStride;

        for (int col = 0; col < safeW; ++col) {
            // Y plane: one byte per pixel.
            const float y = static_cast<float>(yData[row * yRowStride + col]);

            // U/V planes: one sample per 2×2 pixel block.
            // uvPixelStride handles both I420 (stride=1) and NV12/NV21 (stride=2).
            const int uvOff = (row / 2) * uvRowStride + (col / 2) * uvPixelStride;
            const float u = static_cast<float>(uData[uvOff]) - 128.f;
            const float v = static_cast<float>(vData[uvOff]) - 128.f;

            // Full-range BT.601 YUV → RGB.
            float r = y + 1.370705f * v;
            float g = y - 0.337633f * u - 0.698001f * v;
            float b = y + 1.732446f * u;

            // Saturation: luminance-deviation method.
            // sat=1.0 → identity  |  sat=0.0 → grayscale  |  sat>1.0 → boosted color
            const float lum = 0.299f * r + 0.587f * g + 0.114f * b;
            r = lum + sat * (r - lum);
            g = lum + sat * (g - lum);
            b = lum + sat * (b - lum);

            // Clamp to [0, 255] and write RGBA (alpha = 255).
            dstRow[col * 4 + 0] = static_cast<uint8_t>(std::min(255.f, std::max(0.f, r)));
            dstRow[col * 4 + 1] = static_cast<uint8_t>(std::min(255.f, std::max(0.f, g)));
            dstRow[col * 4 + 2] = static_cast<uint8_t>(std::min(255.f, std::max(0.f, b)));
            dstRow[col * 4 + 3] = 255;
        }
    }

    ANativeWindow_unlockAndPost(previewWindow_);
}

} // namespace cam
