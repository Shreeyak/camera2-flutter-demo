// Image pipeline: YUV input ring → async processing thread → shared BGR frames
// → per-consumer mailbox dispatch.
// See ImagePipeline.h for the class structure and lock ordering.

#include "ImagePipeline.h"

#include <android/log.h>
#include <android/native_window.h>
#include <algorithm>  // std::min
#include <cmath>      // std::abs
#include <cstring>    // memcpy

#include <opencv2/imgproc.hpp>

#define TAG  "CambrianCamera"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace cam {

// ---------------------------------------------------------------------------
// Construction / destruction
// ---------------------------------------------------------------------------

ImagePipeline::ImagePipeline(ANativeWindow* window, int width, int height)
        : previewWindow_(window),
          inputRing_(width, height) {
    if (previewWindow_) {
        ANativeWindow_acquire(previewWindow_);
        LOGD("ImagePipeline created, window=%p dims=%dx%d", previewWindow_, width, height);
    }

    // Start the processing thread before registering sinks so it is ready to
    // receive frames as soon as the first addSink() call completes.
    processingThread_ = std::thread(&ImagePipeline::processingLoop, this);

    // Built-in processed-preview consumer (post-saturation BGR → preview window).
    addSink({"__preview"}, [this](const SinkFrame& f) {
        cv::Mat bgr(f.height, f.width, CV_8UC3,
                    const_cast<uint8_t*>(f.data), f.stride);
        cv::cvtColor(bgr, previewRgba_, cv::COLOR_BGR2RGBA);
        blitToWindow(previewWindow_, lastWidth_, lastHeight_, previewRgba_);
    });

    // Built-in raw-preview consumer (pre-saturation BGR → raw preview window).
    rawConsumer_ = std::make_unique<Consumer>();
    rawConsumer_->name     = "__raw_preview";
    rawConsumer_->callback = [this](const SinkFrame& f) {
        cv::Mat bgr(f.height, f.width, CV_8UC3,
                    const_cast<uint8_t*>(f.data), f.stride);
        cv::cvtColor(bgr, rawPreviewRgba_, cv::COLOR_BGR2RGBA);
        blitToWindow(rawPreviewWindow_, rawLastWidth_, rawLastHeight_, rawPreviewRgba_);
    };
    startConsumerThread(rawConsumer_.get());
}

ImagePipeline::~ImagePipeline() {
    // Shutdown order:
    // 1. Stop processing thread (signal input ring, join).
    // 2. Stop all consumer dispatch threads (processed + raw).
    // 3. Release preview windows.
    inputRing_.shutdown();
    if (processingThread_.joinable()) {
        processingThread_.join();
    }

    shutdownConsumers();
    shutdownConsumer(rawConsumer_.get());

    std::lock_guard<std::mutex> lock(windowMu_);
    if (previewWindow_) {
        ANativeWindow_release(previewWindow_);
        previewWindow_ = nullptr;
    }
    if (rawPreviewWindow_) {
        ANativeWindow_release(rawPreviewWindow_);
        rawPreviewWindow_ = nullptr;
    }
    LOGD("ImagePipeline destroyed");
}

// ---------------------------------------------------------------------------
// Preview window
// ---------------------------------------------------------------------------

void ImagePipeline::setPreviewWindow(ANativeWindow* window) {
    std::lock_guard<std::mutex> lock(windowMu_);
    if (previewWindow_) {
        ANativeWindow_release(previewWindow_);
        previewWindow_ = nullptr;
    }
    previewWindow_ = window;
    lastWidth_  = 0;
    lastHeight_ = 0;
    if (previewWindow_) {
        ANativeWindow_acquire(previewWindow_);
        LOGD("ImagePipeline: preview window updated, window=%p", previewWindow_);
    } else {
        LOGD("ImagePipeline: preview window cleared");
    }
}

void ImagePipeline::setRawPreviewWindow(ANativeWindow* window) {
    std::lock_guard<std::mutex> lock(windowMu_);
    if (rawPreviewWindow_) {
        ANativeWindow_release(rawPreviewWindow_);
        rawPreviewWindow_ = nullptr;
    }
    rawPreviewWindow_ = window;
    rawLastWidth_  = 0;
    rawLastHeight_ = 0;
    if (rawPreviewWindow_) {
        ANativeWindow_acquire(rawPreviewWindow_);
        LOGD("ImagePipeline: raw preview window updated, window=%p", rawPreviewWindow_);
    } else {
        LOGD("ImagePipeline: raw preview window cleared");
    }
}

void ImagePipeline::blitToWindow(ANativeWindow*& window, int& lastW, int& lastH,
                                  const cv::Mat& rgba) {
    std::lock_guard<std::mutex> lock(windowMu_);
    if (!window) return;

    const int width  = rgba.cols;
    const int height = rgba.rows;

    if (width != lastW || height != lastH) {
        if (ANativeWindow_setBuffersGeometry(
                window, width, height, WINDOW_FORMAT_RGBA_8888) != 0) {
            LOGE("blitToWindow: setBuffersGeometry failed");
            return;
        }
        lastW = width;
        lastH = height;
        LOGD("blitToWindow: geometry set to %dx%d for window %p", width, height, window);
    }

    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(window, &buf, nullptr) != 0) {
        LOGE("blitToWindow: ANativeWindow_lock failed");
        return;
    }

    const int dstStride = buf.stride * 4;
    const int safeH = std::min(height, static_cast<int>(buf.height));
    const int safeW = std::min(width,  static_cast<int>(buf.width));
    auto* dst = reinterpret_cast<uint8_t*>(buf.bits);

    for (int row = 0; row < safeH; ++row) {
        memcpy(dst + row * dstStride,
               rgba.data + row * rgba.step,
               static_cast<size_t>(safeW) * 4);
    }

    ANativeWindow_unlockAndPost(window);
}

// ---------------------------------------------------------------------------
// Processing params
// ---------------------------------------------------------------------------

void ImagePipeline::setParams(const ProcessingParams& p) {
    std::lock_guard<std::mutex> lock(paramsMu_);
    params_ = p;
}

// ---------------------------------------------------------------------------
// Frame delivery (JNI thread → InputRing)
// ---------------------------------------------------------------------------

void ImagePipeline::deliverYuv(
        const uint8_t* y,  int yRowStride,
        const uint8_t* u,  const uint8_t* v,
        int uvRowStride,
        int width, int height,
        int yuvFormat,
        uint64_t frameId, const FrameMetadata& meta) {
    inputRing_.push(y, yRowStride, u, v, uvRowStride,
                    width, height, yuvFormat, frameId, meta);
}

// ---------------------------------------------------------------------------
// Processing thread
// ---------------------------------------------------------------------------

void ImagePipeline::processingLoop() {
    LOGD("processingLoop: started");
    YuvSlot slot;

    while (true) {
        if (!inputRing_.pop(slot)) break;  // shutdown signaled

        // Snapshot params so the inner loop does not hold paramsMu_.
        ProcessingParams p;
        {
            std::lock_guard<std::mutex> plk(paramsMu_);
            p = params_;
        }

        // YUV → BGR via OpenCV.
        cv::Mat y_mat(slot.height, slot.width, CV_8UC1, slot.yData.data());
        cv::Mat bgr;

        if (slot.yuvFormat == YUV_FORMAT_I420) {
            // Planar I420: assemble a contiguous (height*3/2, width) mat.
            // uvData contains U plane then V plane consecutively (both packed).
            cv::Mat i420(slot.height * 3 / 2, slot.width, CV_8UC1);
            memcpy(i420.data,
                   slot.yData.data(),
                   slot.yData.size());
            memcpy(i420.data + slot.yData.size(),
                   slot.uvData.data(),
                   slot.uvData.size());
            cv::cvtColor(i420, bgr, cv::COLOR_YUV2BGR_I420);
        } else {
            // NV21 / NV12: two-plane conversion — wraps existing buffers, no extra copy.
            // uv_mat shape: (height/2) rows × (width/2) cols × CV_8UC2 (each element = VU or UV pair).
            cv::Mat uv_mat(slot.height / 2, slot.width / 2, CV_8UC2,
                           slot.uvData.data());
            const int code = (slot.yuvFormat == YUV_FORMAT_NV21)
                             ? cv::COLOR_YUV2BGR_NV21
                             : cv::COLOR_YUV2BGR_NV12;
            cv::cvtColorTwoPlane(y_mat, uv_mat, bgr, code);
        }

        // Publish raw (pre-saturation) frame to the raw preview dispatch thread.
        // Non-blocking: just drops into the mailbox, dispatch thread does the blit.
        // Skip the clone entirely when no raw window is configured.
        {
            bool hasRawWindow;
            {
                std::lock_guard<std::mutex> wlk(windowMu_);
                hasRawWindow = rawPreviewWindow_ != nullptr;
            }
            if (hasRawWindow) {
                auto rawFrame    = std::make_shared<Frame>();
                rawFrame->bgr    = bgr.clone();
                rawFrame->id     = slot.frameId;
                rawFrame->meta   = slot.meta;
                rawFrame->width  = slot.width;
                rawFrame->height = slot.height;
                rawFrame->stride = static_cast<int>(rawFrame->bgr.step);
                rawFrame->format = PixelFormat::BGR;
                publishToRawConsumer(std::move(rawFrame));
            }
        }

        // Apply saturation (HSV S-channel scaling; identity when saturation ≈ 1).
        if (std::abs(p.saturation - 1.0f) > 1e-4f) {
            cv::Mat hsv;
            cv::cvtColor(bgr, hsv, cv::COLOR_BGR2HSV);
            std::vector<cv::Mat> ch;
            cv::split(hsv, ch);
            // ch[1] is S channel, CV_8U in [0, 255].
            cv::Mat sFlt;
            ch[1].convertTo(sFlt, CV_32F);
            sFlt *= p.saturation;
            cv::min(sFlt, 255.0f, sFlt);
            sFlt.convertTo(ch[1], CV_8U);
            cv::merge(ch, hsv);
            cv::cvtColor(hsv, bgr, cv::COLOR_HSV2BGR);
        }

        auto frame     = std::make_shared<Frame>();
        frame->id      = slot.frameId;
        frame->meta    = slot.meta;
        frame->bgr     = std::move(bgr);
        frame->width   = slot.width;
        frame->height  = slot.height;
        frame->stride  = static_cast<int>(frame->bgr.step);
        frame->format  = PixelFormat::BGR;

        publishToConsumers(std::move(frame));
    }
    LOGD("processingLoop: exiting");
}

// ---------------------------------------------------------------------------
// Consumer dispatch
// ---------------------------------------------------------------------------

void ImagePipeline::startConsumerThread(Consumer* c) {
    c->dispatchThread = std::thread([c]() {
        while (true) {
            SharedFrame frame;
            {
                std::unique_lock<std::mutex> lk(c->mu);
                c->cv.wait(lk, [c] {
                    return static_cast<bool>(c->pending) || !c->running.load();
                });
                if (!c->running.load() && !c->pending) break;
                frame = std::move(c->pending);
            }
            SinkFrame sf;
            sf.data    = frame->bgr.data;
            sf.width   = frame->width;
            sf.height  = frame->height;
            sf.stride  = frame->stride;
            sf.format  = frame->format;
            sf.frameId = frame->id;
            sf.meta    = frame->meta;
            c->callback(sf);
        }
    });
}

void ImagePipeline::shutdownConsumer(Consumer* c) {
    if (!c) return;
    c->running = false;
    c->cv.notify_all();
    if (c->dispatchThread.joinable()) {
        c->dispatchThread.join();
    }
}

void ImagePipeline::publishToRawConsumer(SharedFrame frame) {
    std::lock_guard<std::mutex> lk(rawConsumer_->mu);
    rawConsumer_->pending = std::move(frame);
    rawConsumer_->cv.notify_one();
}

void ImagePipeline::publishToConsumers(SharedFrame frame) {
    std::lock_guard<std::mutex> lock(consumersMu_);
    for (auto& c : consumers_) {
        std::lock_guard<std::mutex> cl(c->mu);
        c->pending = frame;   // replace previous (drops old shared_ptr refcount)
        c->cv.notify_one();
    }
}

void ImagePipeline::addSink(const SinkConfig& config, SinkCallback callback) {
    auto consumer      = std::make_unique<Consumer>();
    consumer->name     = config.name;
    consumer->callback = std::move(callback);

    Consumer* raw;
    {
        std::lock_guard<std::mutex> lock(consumersMu_);
        raw = consumer.get();
        consumers_.push_back(std::move(consumer));
    }

    startConsumerThread(raw);
    LOGD("addSink: name=%s", config.name.c_str());
}

void ImagePipeline::removeSink(const std::string& name) {
    std::unique_lock<std::mutex> lock(consumersMu_);
    auto it = std::find_if(consumers_.begin(), consumers_.end(),
                           [&name](const std::unique_ptr<Consumer>& c) {
                               return c->name == name;
                           });
    if (it == consumers_.end()) {
        LOGE("removeSink: unknown sink '%s'", name.c_str());
        return;
    }

    // Move out before releasing the lock so we can join without holding consumersMu_.
    auto consumer = std::move(*it);
    consumers_.erase(it);
    lock.unlock();

    shutdownConsumer(consumer.get());
    LOGD("removeSink: '%s' removed", name.c_str());
}

void ImagePipeline::shutdownConsumers() {
    std::vector<std::unique_ptr<Consumer>> local;
    {
        std::lock_guard<std::mutex> lock(consumersMu_);
        local = std::move(consumers_);
    }
    for (auto& c : local) {
        shutdownConsumer(c.get());
    }
    LOGD("shutdownConsumers: all consumers removed");
}

} // namespace cam
