// Image pipeline: converts YUV_420_888 frames to RGBA with post-processing
// (saturation, and in future: black balance, gamma, histogram stretch) and
// writes the result to an ANativeWindow (Flutter SurfaceProducer).

#include "ImagePipeline.h"

#include <android/log.h>
#include <android/native_window.h>
#include <algorithm> // std::min, std::max
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
    shutdownSinks();

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

            // Full-range BT.601 YUV → RGB (ITU-R BT.601, Y/U/V all in [0,255], U/V centred at 128).
            float r = y + 1.402000f * v;
            float g = y - 0.344136f * u - 0.714136f * v;
            float b = y + 1.772000f * u;

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

    // Dispatch processed RGBA to registered sinks before releasing the buffer.
    dispatchToSinks(reinterpret_cast<const uint8_t*>(buf.bits), safeW, safeH, dstStride);

    ANativeWindow_unlockAndPost(previewWindow_);
}

// -----------------------------------------------------------------------------
// Consumer sink management
// -----------------------------------------------------------------------------

int ImagePipeline::addSink(const SinkConfig& config, SinkCallback callback) {
    auto slot = std::make_unique<SinkSlot>();
    slot->config   = config;
    slot->callback = std::move(callback);

    // Use pipeline's last known dimensions if config requests passthrough (0).
    // Reading lastWidth_/lastHeight_ without mutex_ is an intentional benign race:
    // worst case is a slightly stale dimension for the initial ring allocation,
    // which only affects pre-allocated buffer sizes, not correctness.
    const int w  = (config.width  > 0) ? config.width  : lastWidth_;
    const int h  = (config.height > 0) ? config.height : lastHeight_;
    const int ch = config.channels;
    slot->frameWidth  = w;
    slot->frameHeight = h;
    slot->frameStride = w * ch;

    // Pre-allocate ring buffer slots.
    const int ringSize = std::max(1, config.ringSize);
    slot->ring.resize(ringSize);
    const size_t slotBytes = static_cast<size_t>(w) * h * ch;
    for (auto& buf : slot->ring) {
        buf.resize(slotBytes);
    }

    int sinkId;
    SinkSlot* raw;  // non-owning pointer for the dispatch thread lambda
    {
        std::lock_guard<std::mutex> lock(sinksMu_);
        sinkId   = nextSinkId_++;
        slot->id = sinkId;
        raw      = slot.get();
        sinks_.push_back(std::move(slot));
    }

    // Start a dedicated dispatch thread for this sink.
    raw->dispatchThread = std::thread([raw]() {
        while (true) {
            std::unique_lock<std::mutex> lk(raw->mu);
            raw->cv.wait(lk, [raw]() {
                return raw->count > 0 || !raw->running.load();
            });
            if (!raw->running.load() && raw->count == 0) break;

            // Dequeue the oldest frame.
            auto& frameBuf = raw->ring[raw->readIdx];
            SinkFrame frame;
            frame.data     = frameBuf.data();
            frame.width    = raw->frameWidth;
            frame.height   = raw->frameHeight;
            frame.stride   = raw->frameStride;
            frame.channels = raw->config.channels;
            frame.meta     = {};  // metadata plumbing is a future step

            lk.unlock();          // don't hold the lock during the callback
            raw->callback(frame);
            lk.lock();

            raw->readIdx = (raw->readIdx + 1) % static_cast<int>(raw->ring.size());
            raw->count--;
        }
    });

    LOGD("addSink: id=%d name=%s ring=%d dims=%dx%dx%d",
         sinkId, config.name.c_str(), ringSize, w, h, ch);
    return sinkId;
}

void ImagePipeline::removeSink(int sinkId) {
    std::unique_lock<std::mutex> lock(sinksMu_);
    auto it = std::find_if(sinks_.begin(), sinks_.end(),
                           [sinkId](const std::unique_ptr<SinkSlot>& s) {
                               return s->id == sinkId;
                           });
    if (it == sinks_.end()) {
        LOGE("removeSink: unknown sink id %d", sinkId);
        return;
    }

    // Take ownership so we can release the lock before joining the thread.
    auto slot = std::move(*it);
    sinks_.erase(it);
    lock.unlock();

    slot->running = false;
    slot->cv.notify_all();
    if (slot->dispatchThread.joinable()) {
        slot->dispatchThread.join();
    }
    LOGD("removeSink: id=%d name=%s removed", sinkId, slot->config.name.c_str());
}

void ImagePipeline::dispatchToSinks(const uint8_t* rgbaData,
                                     int width, int height, int stride) {
    std::lock_guard<std::mutex> lock(sinksMu_);
    if (sinks_.empty()) return;

    for (auto& slot : sinks_) {
        std::lock_guard<std::mutex> slotLock(slot->mu);

        // Ring full — drop or skip depending on config.
        if (slot->count >= static_cast<int>(slot->ring.size())) {
            if (slot->config.dropOnFull) continue;
            // Block policy: also skip for now (blocking would stall the preview).
            continue;
        }

        auto& dst = slot->ring[slot->writeIdx];
        const int copyW = std::min(width,  slot->frameWidth);
        const int copyH = std::min(height, slot->frameHeight);
        const int rowBytes = copyW * slot->config.channels;

        for (int row = 0; row < copyH; ++row) {
            memcpy(dst.data() + row * slot->frameStride,
                   rgbaData  + row * stride,
                   rowBytes);
        }

        slot->writeIdx = (slot->writeIdx + 1) % static_cast<int>(slot->ring.size());
        slot->count++;
        slot->cv.notify_one();
    }
}

void ImagePipeline::shutdownSinks() {
    std::lock_guard<std::mutex> lock(sinksMu_);
    for (auto& slot : sinks_) {
        slot->running = false;
        slot->cv.notify_all();
    }
    for (auto& slot : sinks_) {
        if (slot->dispatchThread.joinable()) {
            slot->dispatchThread.join();
        }
    }
    sinks_.clear();
    LOGD("shutdownSinks: all sinks removed");
}

} // namespace cam
