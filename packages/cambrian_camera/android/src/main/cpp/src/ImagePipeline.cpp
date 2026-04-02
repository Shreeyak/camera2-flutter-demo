// Image pipeline: YUV input ring → async processing thread → shared BGR frames
// → per-consumer mailbox dispatch.
// See ImagePipeline.h for the class structure and lock ordering.

#include "ImagePipeline.h"

#include <android/log.h>
#include <android/native_window.h>
#include <algorithm>  // std::min
#include <chrono>     // profiling
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
// Processing helpers
// ---------------------------------------------------------------------------

/// Luminance-preserving saturation: dst = gray + sat * (src - gray).
/// BT.601 weights.  Splits work across kThreads to saturate big cores.
static void applySaturation(const cv::Mat& src, cv::Mat& dst, float sat) {
    dst.create(src.size(), src.type());

    constexpr int kThreads = 4;
    std::thread workers[kThreads];
    const int rowsPer = src.rows / kThreads;

    for (int t = 0; t < kThreads; ++t) {
        const int r0 = t * rowsPer;
        const int r1 = (t == kThreads - 1) ? src.rows : r0 + rowsPer;
        workers[t] = std::thread([&src, &dst, sat, r0, r1]() {
            for (int r = r0; r < r1; ++r) {
                const auto* s = src.ptr<uint8_t>(r);
                auto*       d = dst.ptr<uint8_t>(r);
                for (int c = 0, n = src.cols * 3; c < n; c += 3) {
                    float B = s[c], G = s[c + 1], R = s[c + 2];
                    float gray = 0.114f * B + 0.587f * G + 0.299f * R;
                    d[c]     = cv::saturate_cast<uint8_t>(gray + sat * (B - gray));
                    d[c + 1] = cv::saturate_cast<uint8_t>(gray + sat * (G - gray));
                    d[c + 2] = cv::saturate_cast<uint8_t>(gray + sat * (R - gray));
                }
            }
        });
    }
    for (auto& w : workers) w.join();
}

// ---------------------------------------------------------------------------
// Processing thread
// ---------------------------------------------------------------------------

void ImagePipeline::processingLoop() {
    LOGD("processingLoop: started");
    using Clock = std::chrono::steady_clock;

    // Rolling averages (microseconds), reported every kLogInterval frames.
    constexpr int kLogInterval = 60;
    int64_t frameCount   = 0;
    double  accumPop     = 0;   // time blocked in inputRing_.pop()
    double  accumYuv     = 0;   // YUV → BGR conversion
    double  accumSat     = 0;   // saturation (+ future processing steps)
    double  accumPublish = 0;   // consumer dispatch
    double  accumTotal   = 0;   // wall-clock including pop wait
    auto    intervalStart = Clock::now();

    YuvSlot slot;

    while (true) {
        const auto tPop0 = Clock::now();
        if (!inputRing_.pop(slot)) break;  // shutdown signaled
        const auto tPop1 = Clock::now();

        // Snapshot params so the inner loop does not hold paramsMu_.
        ProcessingParams p;
        {
            std::lock_guard<std::mutex> plk(paramsMu_);
            p = params_;
        }

        // -- YUV → BGR via OpenCV --------------------------------------------
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
            // uv_mat: (height/2) rows × (width/2) cols × CV_8UC2 (VU or UV pair per element).
            cv::Mat uv_mat(slot.height / 2, slot.width / 2, CV_8UC2,
                           slot.uvData.data());
            const int code = (slot.yuvFormat == YUV_FORMAT_NV21)
                             ? cv::COLOR_YUV2BGR_NV21
                             : cv::COLOR_YUV2BGR_NV12;
            cv::cvtColorTwoPlane(y_mat, uv_mat, bgr, code);
        }
        const auto tYuv = Clock::now();

        // -- Build raw frame (zero-copy move of the YUV→BGR output) -----------
        auto rawFrame    = std::make_shared<Frame>();
        rawFrame->id     = slot.frameId;
        rawFrame->meta   = slot.meta;
        rawFrame->bgr    = std::move(bgr);
        rawFrame->width  = slot.width;
        rawFrame->height = slot.height;
        rawFrame->stride = static_cast<int>(rawFrame->bgr.step);
        rawFrame->format = PixelFormat::BGR;

        // -- Processing chain (lazy-copy: first step copies, rest in-place) --
        // Each step reads from rawFrame->bgr (untouched) or `processed`
        // (accumulated result).  When no step fires, processedFrame aliases
        // rawFrame — zero-copy shared_ptr.
        cv::Mat processed;
        bool modified = false;

        // Step: saturation (luminance-preserving, parallel across cores)
        if (std::abs(p.saturation - 1.0f) > 1e-4f) {
            applySaturation(rawFrame->bgr, processed, p.saturation);
            modified = true;
        }
        // Future steps: black level, gamma, brightness, auto-stretch.
        // Each would check `modified` and operate on `processed` in-place,
        // or copy from rawFrame->bgr on first use.
        const auto tSat = Clock::now();

        // -- Dispatch to consumers -------------------------------------------
        // Raw consumer gets the pre-processing BGR frame (non-blocking mailbox).
        {
            bool hasRawWindow;
            {
                std::lock_guard<std::mutex> wlk(windowMu_);
                hasRawWindow = rawPreviewWindow_ != nullptr;
            }
            if (hasRawWindow) {
                publishToRawConsumer(rawFrame);
            }
        }

        // Processed consumers get the post-processing frame, or alias the raw
        // frame when all processing steps are identity (zero-copy).
        if (modified) {
            auto pFrame    = std::make_shared<Frame>();
            pFrame->id     = slot.frameId;
            pFrame->meta   = slot.meta;
            pFrame->bgr    = std::move(processed);
            pFrame->width  = slot.width;
            pFrame->height = slot.height;
            pFrame->stride = static_cast<int>(pFrame->bgr.step);
            pFrame->format = PixelFormat::BGR;
            publishToConsumers(std::move(pFrame));
        } else {
            publishToConsumers(rawFrame);
        }
        const auto tEnd = Clock::now();

        // -- Profiling -------------------------------------------------------
        auto us = [](auto a, auto b) {
            return std::chrono::duration<double, std::micro>(b - a).count();
        };
        accumPop     += us(tPop0, tPop1);
        accumYuv     += us(tPop1, tYuv);
        accumSat     += us(tYuv, tSat);
        accumPublish += us(tSat, tEnd);
        accumTotal   += us(tPop0, tEnd);

        if (++frameCount % kLogInterval == 0) {
            double wallMs = std::chrono::duration<double, std::milli>(
                    tEnd - intervalStart).count();
            double fps = kLogInterval / (wallMs / 1000.0);
            LOGD("perf [%lld] fps=%.1f  total=%.1fms  pop=%.1fms  yuv=%.1fms  sat=%.1fms  pub=%.1fms",
                 static_cast<long long>(frameCount),
                 fps,
                 accumTotal   / kLogInterval / 1000.0,
                 accumPop     / kLogInterval / 1000.0,
                 accumYuv     / kLogInterval / 1000.0,
                 accumSat     / kLogInterval / 1000.0,
                 accumPublish / kLogInterval / 1000.0);
            accumTotal = accumPop = accumYuv = accumSat = accumPublish = 0;
            intervalStart = tEnd;
        }
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
