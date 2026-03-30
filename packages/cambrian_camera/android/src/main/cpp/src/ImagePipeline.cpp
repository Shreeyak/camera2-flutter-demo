// Phase 3 identity image pipeline implementation.
// Receives RGBA frames via processFrame() and blits them row-by-row into an
// ANativeWindow (the Flutter preview Surface).  No image processing is applied.

#include "ImagePipeline.h"

#include <android/log.h>
#include <android/native_window.h>
#include <cstring> // memcpy

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
    if (previewWindow_) {
        ANativeWindow_release(previewWindow_);
        previewWindow_ = nullptr;
        LOGD("ImagePipeline destroyed");
    }
}

void ImagePipeline::setPreviewWindow(ANativeWindow* window) {
    // Release the old surface before storing the new one.
    if (previewWindow_) {
        ANativeWindow_release(previewWindow_);
        previewWindow_ = nullptr;
    }

    previewWindow_ = window;
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
    // Nothing to render into.
    if (!previewWindow_) {
        return;
    }

    // Configure the surface buffer to match the incoming frame geometry.
    // WINDOW_FORMAT_RGBA_8888 = 4 bytes per pixel.
    int32_t result = ANativeWindow_setBuffersGeometry(
            previewWindow_, width, height, WINDOW_FORMAT_RGBA_8888);
    if (result != 0) {
        LOGE("ANativeWindow_setBuffersGeometry failed: %d", result);
        return;
    }

    // Lock the surface to obtain a writable pixel buffer.
    ANativeWindow_Buffer buffer;
    result = ANativeWindow_lock(previewWindow_, &buffer, /*inOutDirtyBounds=*/nullptr);
    if (result != 0) {
        LOGE("ANativeWindow_lock failed: %d", result);
        return;
    }

    // buffer.stride is in pixels; multiply by 4 (bytes per RGBA pixel) to get
    // the destination row stride in bytes.
    const int dstStride = buffer.stride * 4;

    // Source row stride is already in bytes (as passed from Kotlin/ImageReader).
    const int srcStride = stride;

    // Number of bytes we actually want to copy per row (the active image width,
    // not any padding beyond it).
    const int copyWidth = width * 4;

    auto* dst = reinterpret_cast<uint8_t*>(buffer.bits);
    const uint8_t* src = data;

    for (int row = 0; row < height; ++row) {
        memcpy(dst, src, copyWidth);
        dst += dstStride;
        src += srcStride;
    }

    // Unlock and submit the buffer to the display compositor.
    ANativeWindow_unlockAndPost(previewWindow_);
}

} // namespace cam
