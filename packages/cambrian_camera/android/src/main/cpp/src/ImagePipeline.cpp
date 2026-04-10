// Image pipeline: receives RGBA frames from the GPU pipeline, routes them through
// an optional per-role ProcessingStage (dedicated hook thread), and distributes
// shared frames to registered consumer sinks via per-consumer mailbox dispatch.
// See ImagePipeline.h for the class structure and lock ordering.

// stb_image_write: single-header JPEG/PNG encoder (public domain).
// Implementation is compiled once here; all other TUs just #include the header.
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../include/stb_image_write.h"

#include "ImagePipeline.h"

#include <android/log.h>
#include <algorithm>  // std::find_if
#include <cassert>
#include <cctype>     // std::tolower
#include <cstring>    // memcpy
#include <unistd.h>   // write() for captureToFd

#define TAG  "CambrianCamera"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

namespace cam {

// ---------------------------------------------------------------------------
// Construction / destruction
// ---------------------------------------------------------------------------

ImagePipeline::ImagePipeline() {
    LOGD("ImagePipeline created (GPU dispatch mode)");
}

ImagePipeline::~ImagePipeline() {
    shutdownProcessingStage(fullResStage_);
    shutdownProcessingStage(trackerStage_);
    shutdownProcessingStage(rawStage_);
    shutdownConsumers();
    LOGD("ImagePipeline destroyed");
}

// ---------------------------------------------------------------------------
// GPU frame delivery (GL thread → processing stage or consumer mailboxes)
// ---------------------------------------------------------------------------

void ImagePipeline::deliverFullResRgba(const uint8_t* rgba, int w, int h,
                                        int stride, uint64_t frameId,
                                        const FrameMetadata& meta) {
    // Read capture flag before taking the consumer mutex so we can include it
    // in the fast-path decision without a second lock acquisition.
    const bool captureNeeded = captureRequested_.load(std::memory_order_acquire);

    // Fast-path: skip if no consumers AND no hook AND no capture pending.
    // Use hookActive (atomic) instead of reading hook (std::function) to avoid
    // a data race with setFrameHook writing hook on another thread.
    {
        std::lock_guard<std::mutex> lk(fullResConsumersMu_);
        if (fullResConsumers_.empty() &&
            !fullResStage_.hookActive.load(std::memory_order_acquire) &&
            !captureNeeded) return;
    }

    auto frame    = std::make_shared<Frame>();
    frame->id     = frameId;
    frame->meta   = meta;
    frame->width  = w;
    frame->height = h;
    frame->stride = stride;
    frame->format = PixelFormat::RGBA;
    // NOTE: PBO stride is currently always w*4; assert to catch future padding changes.
    assert(stride == w * 4 && "PBO stride has padding — verify consumers handle it");
    const size_t size = static_cast<size_t>(h) * stride;
    frame->data.resize(size);
    memcpy(frame->data.data(), rgba, size);

    // Satisfy a pending captureToFile() request with this frame.
    // exchange(false) atomically clears the flag and returns whether it was set,
    // preventing a second frame from overwriting capturedFrame_ before captureToFile()
    // has consumed the first one.
    if (captureNeeded && captureRequested_.exchange(false, std::memory_order_acq_rel)) {
        std::lock_guard<std::mutex> lk(captureResultMu_);
        capturedFrame_ = frame;   // shared_ptr copy; no pixel data copy
        captureCV_.notify_one();
    }

    routeFrame(fullResStage_, std::move(frame),
               &ImagePipeline::publishToFullResConsumers);
}

void ImagePipeline::deliverTrackerRgba(const uint8_t* rgba, int w, int h,
                                        int stride, uint64_t frameId,
                                        const FrameMetadata& meta) {
    {
        std::lock_guard<std::mutex> lk(trackerConsumersMu_);
        if (trackerConsumers_.empty() &&
            !trackerStage_.hookActive.load(std::memory_order_acquire)) return;
    }

    auto frame    = std::make_shared<Frame>();
    frame->id     = frameId;
    frame->meta   = meta;
    frame->width  = w;
    frame->height = h;
    frame->stride = stride;
    frame->format = PixelFormat::RGBA;
    assert(stride == w * 4 && "PBO stride has padding — verify consumers handle it");
    const size_t size = static_cast<size_t>(h) * stride;
    frame->data.resize(size);
    memcpy(frame->data.data(), rgba, size);

    routeFrame(trackerStage_, std::move(frame),
               &ImagePipeline::publishToTrackerConsumers);
}

void ImagePipeline::deliverRawRgba(const uint8_t* rgba, int w, int h,
                                    int stride, uint64_t frameId,
                                    const FrameMetadata& meta) {
    {
        std::lock_guard<std::mutex> lk(rawConsumersMu_);
        if (rawConsumers_.empty() &&
            !rawStage_.hookActive.load(std::memory_order_acquire)) return;
    }

    auto frame    = std::make_shared<Frame>();
    frame->id     = frameId;
    frame->meta   = meta;
    frame->width  = w;
    frame->height = h;
    frame->stride = stride;
    frame->format = PixelFormat::RGBA;
    assert(stride == w * 4 && "PBO stride has padding — verify consumers handle it");
    const size_t size = static_cast<size_t>(h) * stride;
    frame->data.resize(size);
    memcpy(frame->data.data(), rgba, size);

    routeFrame(rawStage_, std::move(frame),
               &ImagePipeline::publishToRawConsumers);
}

// ---------------------------------------------------------------------------
// ProcessingStage routing
// ---------------------------------------------------------------------------

void ImagePipeline::routeFrame(ProcessingStage& stage, SharedFrame frame,
                               void (ImagePipeline::*publishFn)(SharedFrame)) {
    if (stage.running.load(std::memory_order_acquire)) {
        // Route through processing stage
        std::lock_guard<std::mutex> lk(stage.mu);
        stage.pending = std::move(frame);
        stage.cv.notify_one();
    } else {
        // Fast path: direct dispatch
        (this->*publishFn)(std::move(frame));
    }
}

void ImagePipeline::startProcessingStage(
        ProcessingStage& stage,
        void (ImagePipeline::*publishFn)(SharedFrame)) {
    if (stage.running.load()) return;  // already running
    stage.running.store(true, std::memory_order_release);
    stage.thread = std::thread([this, &stage, publishFn]() {
        while (true) {
            SharedFrame frame;
            {
                std::unique_lock<std::mutex> lk(stage.mu);
                stage.cv.wait(lk, [&] {
                    return static_cast<bool>(stage.pending) ||
                           !stage.running.load(std::memory_order_relaxed);
                });
                if (!stage.running.load(std::memory_order_relaxed) && !stage.pending) break;
                frame = std::move(stage.pending);
            }
            if (frame && stage.hook) {
                try {
                    stage.hook(frame->data.data(), frame->width,
                               frame->height, frame->stride);
                } catch (const std::exception& e) {
                    LOGE("ProcessingStage hook threw: %s — frame passed unmodified", e.what());
                } catch (...) {
                    LOGE("ProcessingStage hook threw unknown exception — frame passed unmodified");
                }
            }
            if (frame) {
                (this->*publishFn)(std::move(frame));
            }
        }
    });
}

void ImagePipeline::shutdownProcessingStage(ProcessingStage& stage) {
    if (!stage.running.load()) return;
    stage.running.store(false, std::memory_order_release);
    stage.cv.notify_all();
    if (stage.thread.joinable()) stage.thread.join();
    stage.pending.reset();  // Release any held frame immediately (can be ~48MB at 4K)
}

// NOTE: Not thread-safe against concurrent calls for the same role.
// Must be called from a single thread (Kotlin main thread in practice).
void ImagePipeline::setFrameHook(SinkRole role, FrameHookFn fn) {
    ProcessingStage* stage = nullptr;
    void (ImagePipeline::*publishFn)(SharedFrame) = nullptr;
    switch (role) {
        case SinkRole::FULL_RES:
            stage = &fullResStage_;
            publishFn = &ImagePipeline::publishToFullResConsumers;
            break;
        case SinkRole::TRACKER:
            stage = &trackerStage_;
            publishFn = &ImagePipeline::publishToTrackerConsumers;
            break;
        case SinkRole::RAW:
            stage = &rawStage_;
            publishFn = &ImagePipeline::publishToRawConsumers;
            break;
        default:
            LOGE("setFrameHook: unknown SinkRole %d", static_cast<int>(role));
            return;
    }
    shutdownProcessingStage(*stage);
    stage->hook = std::move(fn);
    stage->hookActive.store(static_cast<bool>(stage->hook), std::memory_order_release);
    if (stage->hook) {
        startProcessingStage(*stage, publishFn);
    }
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
            sf.data    = frame->data.data();
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
        if (c->dispatchThread.get_id() == std::this_thread::get_id()) {
            // Called from within the consumer's own callback — joining would deadlock.
            // Detach so the thread can exit on its own after the callback returns.
            c->dispatchThread.detach();
        } else {
            c->dispatchThread.join();
        }
    }
}

void ImagePipeline::publishToFullResConsumers(SharedFrame frame) {
    std::lock_guard<std::mutex> lock(fullResConsumersMu_);
    for (auto& c : fullResConsumers_) {
        std::lock_guard<std::mutex> cl(c->mu);
        c->pending = frame;
        c->cv.notify_one();
    }
}

void ImagePipeline::publishToTrackerConsumers(SharedFrame frame) {
    std::lock_guard<std::mutex> lock(trackerConsumersMu_);
    for (auto& c : trackerConsumers_) {
        std::lock_guard<std::mutex> cl(c->mu);
        c->pending = frame;
        c->cv.notify_one();
    }
}

void ImagePipeline::publishToRawConsumers(SharedFrame frame) {
    std::lock_guard<std::mutex> lock(rawConsumersMu_);
    for (auto& c : rawConsumers_) {
        std::lock_guard<std::mutex> cl(c->mu);
        c->pending = frame;
        c->cv.notify_one();
    }
}

void ImagePipeline::addSink(const SinkConfig& config, SinkCallback callback) {
    auto consumer      = std::make_unique<Consumer>();
    consumer->name     = config.name;
    consumer->callback = std::move(callback);

    Consumer* raw;
    if (config.role == SinkRole::TRACKER) {
        std::lock_guard<std::mutex> lock(trackerConsumersMu_);
        raw = consumer.get();
        trackerConsumers_.push_back(std::move(consumer));
    } else if (config.role == SinkRole::RAW) {
        std::lock_guard<std::mutex> lock(rawConsumersMu_);
        raw = consumer.get();
        rawConsumers_.push_back(std::move(consumer));
    } else {
        // SinkRole::FULL_RES (default) — GPU full-res path
        std::lock_guard<std::mutex> lock(fullResConsumersMu_);
        raw = consumer.get();
        fullResConsumers_.push_back(std::move(consumer));
    }

    startConsumerThread(raw);
    const char* roleStr = config.role == SinkRole::TRACKER ? "TRACKER"
                        : config.role == SinkRole::RAW     ? "RAW"
                                                           : "FULL_RES";
    LOGD("addSink: name=%s role=%s", config.name.c_str(), roleStr);
}

void ImagePipeline::removeSink(const std::string& name) {
    // Search full-res GPU consumers first.
    {
        std::unique_lock<std::mutex> lock(fullResConsumersMu_);
        auto it = std::find_if(fullResConsumers_.begin(), fullResConsumers_.end(),
                               [&name](const std::unique_ptr<Consumer>& c) {
                                   return c->name == name;
                               });
        if (it != fullResConsumers_.end()) {
            auto consumer = std::move(*it);
            fullResConsumers_.erase(it);
            lock.unlock();
            shutdownConsumer(consumer.get());
            LOGD("removeSink: '%s' removed from fullResConsumers", name.c_str());
            return;
        }
    }
    // Search tracker GPU consumers.
    {
        std::unique_lock<std::mutex> lock(trackerConsumersMu_);
        auto it = std::find_if(trackerConsumers_.begin(), trackerConsumers_.end(),
                               [&name](const std::unique_ptr<Consumer>& c) {
                                   return c->name == name;
                               });
        if (it != trackerConsumers_.end()) {
            auto consumer = std::move(*it);
            trackerConsumers_.erase(it);
            lock.unlock();
            shutdownConsumer(consumer.get());
            LOGD("removeSink: '%s' removed from trackerConsumers", name.c_str());
            return;
        }
    }
    // Search raw GPU consumers.
    {
        std::unique_lock<std::mutex> lock(rawConsumersMu_);
        auto it = std::find_if(rawConsumers_.begin(), rawConsumers_.end(),
                               [&name](const std::unique_ptr<Consumer>& c) {
                                   return c->name == name;
                               });
        if (it != rawConsumers_.end()) {
            auto consumer = std::move(*it);
            rawConsumers_.erase(it);
            lock.unlock();
            shutdownConsumer(consumer.get());
            LOGD("removeSink: '%s' removed from rawConsumers", name.c_str());
            return;
        }
    }
    LOGE("removeSink: unknown sink '%s'", name.c_str());
}

void ImagePipeline::shutdownConsumers() {
    // Helper: move a vector out under its lock, then join all consumers outside.
    auto drainVector = [&](auto& mu, auto& vec) {
        std::vector<std::unique_ptr<Consumer>> local;
        {
            std::lock_guard<std::mutex> lock(mu);
            local = std::move(vec);
        }
        for (auto& c : local) {
            shutdownConsumer(c.get());
        }
    };

    drainVector(fullResConsumersMu_, fullResConsumers_);
    drainVector(trackerConsumersMu_, trackerConsumers_);
    drainVector(rawConsumersMu_, rawConsumers_);
    LOGD("shutdownConsumers: all consumers removed");
}

// ---------------------------------------------------------------------------
// On-request still capture
// ---------------------------------------------------------------------------

bool ImagePipeline::captureToFile(const std::string& outputPath,
                                   int jpegQuality, int timeoutMs) {
    // Reset any leftover captured frame from a previous (possibly timed-out) call.
    {
        std::lock_guard<std::mutex> lk(captureResultMu_);
        capturedFrame_ = nullptr;
    }

    // Signal deliverFullResRgba to store the next frame it receives.
    captureRequested_.store(true, std::memory_order_release);

    // Block until deliverFullResRgba delivers a frame or we time out.
    SharedFrame frame;
    {
        std::unique_lock<std::mutex> lk(captureResultMu_);
        const bool arrived = captureCV_.wait_for(
            lk,
            std::chrono::milliseconds(timeoutMs),
            [this] { return capturedFrame_ != nullptr; });

        if (!arrived) {
            // Clear flag so a late-arriving frame doesn't corrupt the next call.
            captureRequested_.store(false, std::memory_order_release);
            LOGE("captureToFile: timed out waiting for frame after %d ms", timeoutMs);
            return false;
        }
        frame = capturedFrame_;
        capturedFrame_ = nullptr;
    }

    // Infer format from extension: .jpg / .jpeg → JPEG; anything else → PNG.
    // Compare the last 4-5 characters lowercase to avoid a full string-lower pass.
    const bool asJpeg = [&outputPath]() -> bool {
        const size_t n = outputPath.size();
        if (n >= 4) {
            char e4[5]{};
            for (size_t i = 0; i < 4; ++i)
                e4[i] = static_cast<char>(std::tolower(
                    static_cast<unsigned char>(outputPath[n - 4 + i])));
            if (std::string(e4) == ".jpg") return true;
        }
        if (n >= 5) {
            char e5[6]{};
            for (size_t i = 0; i < 5; ++i)
                e5[i] = static_cast<char>(std::tolower(
                    static_cast<unsigned char>(outputPath[n - 5 + i])));
            if (std::string(e5) == ".jpeg") return true;
        }
        return false;
    }();

    const int w      = frame->width;
    const int h      = frame->height;
    const int stride = frame->stride;
    const uint8_t* data = frame->data.data();

    int ok = 0;
    if (asJpeg) {
        // stbi_write_jpg: comp=4 (RGBA). The encoder ignores the alpha channel
        // and encodes the RGB triplets; the result is a standard RGB JPEG.
        ok = stbi_write_jpg(outputPath.c_str(), w, h, 4, data, jpegQuality);
    } else {
        // stbi_write_png: stride_in_bytes controls row pitch for non-contiguous data.
        ok = stbi_write_png(outputPath.c_str(), w, h, 4, data, stride);
    }

    if (!ok) {
        LOGE("captureToFile: stbi_write_%s failed for path '%s'",
             asJpeg ? "jpg" : "png", outputPath.c_str());
        return false;
    }
    LOGD("captureToFile: wrote %dx%d %s → '%s'",
         w, h, asJpeg ? "JPEG" : "PNG", outputPath.c_str());
    return true;
}

// ---------------------------------------------------------------------------
// captureToFd — encode and write to an open file descriptor
// ---------------------------------------------------------------------------

// stb_image_write callback: writes a chunk to the POSIX fd stored in context.
// stb calls this one or more times per image; we loop to handle short writes.
static void stbiWriteFdCallback(void* ctx, void* data, int size) {
    int fd = *static_cast<int*>(ctx);
    const uint8_t* p = static_cast<const uint8_t*>(data);
    int rem = size;
    while (rem > 0) {
        ssize_t n = ::write(fd, p, static_cast<size_t>(rem));
        if (n <= 0) return;  // I/O error — stb will treat the output as failed
        p   += n;
        rem -= static_cast<int>(n);
    }
}

bool ImagePipeline::captureToFd(int fd, bool asJpeg, int jpegQuality,
                                 int timeoutMs) {
    // Reset any leftover captured frame from a previous (possibly timed-out) call.
    {
        std::lock_guard<std::mutex> lk(captureResultMu_);
        capturedFrame_ = nullptr;
    }

    captureRequested_.store(true, std::memory_order_release);

    SharedFrame frame;
    {
        std::unique_lock<std::mutex> lk(captureResultMu_);
        const bool arrived = captureCV_.wait_for(
            lk,
            std::chrono::milliseconds(timeoutMs),
            [this] { return capturedFrame_ != nullptr; });

        if (!arrived) {
            captureRequested_.store(false, std::memory_order_release);
            LOGE("captureToFd: timed out waiting for frame after %d ms", timeoutMs);
            return false;
        }
        frame = capturedFrame_;
        capturedFrame_ = nullptr;
    }

    const int w      = frame->width;
    const int h      = frame->height;
    const int stride = frame->stride;
    const uint8_t* data = frame->data.data();

    int ok = 0;
    if (asJpeg) {
        // comp=4 (RGBA); the encoder ignores alpha and produces a standard RGB JPEG.
        ok = stbi_write_jpg_to_func(stbiWriteFdCallback, &fd, w, h, 4, data, jpegQuality);
    } else {
        ok = stbi_write_png_to_func(stbiWriteFdCallback, &fd, w, h, 4, data, stride);
    }

    if (!ok) {
        LOGE("captureToFd: stbi_write_%s_to_func failed (fd=%d)",
             asJpeg ? "jpg" : "png", fd);
        return false;
    }
    LOGD("captureToFd: wrote %dx%d %s to fd=%d", w, h, asJpeg ? "JPEG" : "PNG", fd);
    return true;
}

} // namespace cam
