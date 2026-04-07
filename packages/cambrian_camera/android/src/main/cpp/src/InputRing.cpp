// YUV input ring buffer implementation.
// See InputRing.h for the public interface and invariants.

#include "InputRing.h"

#include <android/log.h>
#include <cstring>  // memcpy

#define TAG  "CambrianCamera"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)

namespace cam {

InputRing::InputRing(int width, int height, int ringSize)
        : width_(width), height_(height), slots_(ringSize) {
    const size_t yBytes  = static_cast<size_t>(width) * height;
    const size_t uvBytes = yBytes / 2;
    for (auto& slot : slots_) {
        slot.yData.resize(yBytes);
        slot.uvData.resize(uvBytes);
    }
    LOGD("InputRing: %d slots pre-allocated for %dx%d (y=%zu uv=%zu bytes/slot)",
         ringSize, width, height, yBytes, uvBytes);
}

void InputRing::push(const uint8_t* y,  int yRowStride,
                     const uint8_t* u,  const uint8_t* v,
                     int uvRowStride,
                     int width, int height,
                     int yuvFormat,
                     uint64_t frameId, const FrameMetadata& meta) {
    std::lock_guard<std::mutex> lock(mu_);
    if (width != width_ || height != height_) {
        LOGD("InputRing::push: dimension mismatch (%dx%d vs %dx%d), dropping frame",
             width, height, width_, height_);
        dimensionMismatchCount_++;
        return;
    }
    if (count_ >= static_cast<int>(slots_.size())) {
        // Ring full — drop frame silently; camera thread must not block.
        return;
    }

    YuvSlot& slot  = slots_[writeIdx_];
    slot.width     = width;
    slot.height    = height;
    slot.yuvFormat = yuvFormat;
    slot.frameId   = frameId;
    slot.meta      = meta;

    // Y plane: copy row-by-row to strip yRowStride padding.
    for (int row = 0; row < height; ++row) {
        memcpy(slot.yData.data() + static_cast<size_t>(row) * width,
               y + static_cast<size_t>(row) * yRowStride,
               static_cast<size_t>(width));
    }

    if (yuvFormat == YUV_FORMAT_I420) {
        // Planar: copy U then V consecutively into uvData.
        const int chromaH = height / 2;
        const int chromaW = width  / 2;
        for (int row = 0; row < chromaH; ++row) {
            memcpy(slot.uvData.data() + static_cast<size_t>(row) * chromaW,
                   u + static_cast<size_t>(row) * uvRowStride,
                   static_cast<size_t>(chromaW));
        }
        for (int row = 0; row < chromaH; ++row) {
            memcpy(slot.uvData.data()
                       + static_cast<size_t>(chromaH) * chromaW
                       + static_cast<size_t>(row) * chromaW,
                   v + static_cast<size_t>(row) * uvRowStride,
                   static_cast<size_t>(chromaW));
        }
    } else {
        // NV21: copy from v (V starts first in VU interleaved memory).
        // NV12: copy from u (U starts first in UV interleaved memory).
        const uint8_t* chromaStart = (yuvFormat == YUV_FORMAT_NV21) ? v : u;
        for (int row = 0; row < height / 2; ++row) {
            memcpy(slot.uvData.data() + static_cast<size_t>(row) * width,
                   chromaStart + static_cast<size_t>(row) * uvRowStride,
                   static_cast<size_t>(width));
        }
    }

    writeIdx_ = (writeIdx_ + 1) % static_cast<int>(slots_.size());
    ++count_;
    cv_.notify_one();
}

bool InputRing::pop(YuvSlot& out) {
    std::unique_lock<std::mutex> lock(mu_);
    cv_.wait(lock, [this] { return count_ > 0 || shutdown_; });
    if (shutdown_ && count_ == 0) return false;

    YuvSlot& src = slots_[readIdx_];

    // Transfer via swap — O(1), reuses existing heap allocations.
    // After swap: out holds the frame data; src holds out's old (possibly pre-sized) vectors.
    out.width     = src.width;
    out.height    = src.height;
    out.yuvFormat = src.yuvFormat;
    out.frameId   = src.frameId;
    out.meta      = src.meta;
    out.yData.swap(src.yData);
    out.uvData.swap(src.uvData);

    // Restore slot to pre-allocated size for future pushes.
    // If out's old buffers were already the right size, resize is a no-op.
    const size_t yBytes = static_cast<size_t>(width_) * height_;
    src.yData.resize(yBytes);
    src.uvData.resize(yBytes / 2);

    readIdx_ = (readIdx_ + 1) % static_cast<int>(slots_.size());
    --count_;
    return true;
}

void InputRing::shutdown() {
    std::lock_guard<std::mutex> lock(mu_);
    shutdown_ = true;
    cv_.notify_all();
}

} // namespace cam
