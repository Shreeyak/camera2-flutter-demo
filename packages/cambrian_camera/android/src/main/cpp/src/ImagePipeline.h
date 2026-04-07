#pragma once
// Image pipeline: receives YUV frames into an input ring buffer, converts them
// to BGR asynchronously via OpenCV, applies post-processing, and distributes
// shared BGR frames to registered consumer sinks via per-consumer mailboxes.
//
// Thread safety — lock ordering (always acquire in this order):
//   1. windowMu_           — ANativeWindow access (setPreviewWindow, blitToWindow)
//   2. consumersMu_        — CPU path consumers_ vector (addSink ctor path, removeSink, publishToConsumers)
//      fullResConsumersMu_ — GPU full-res consumers vector (addSink FULL_RES, removeSink, publishToFullResConsumers)
//      trackerConsumersMu_ — GPU tracker consumers vector (addSink TRACKER, removeSink, publishToTrackerConsumers)
//      rawConsumersMu_     — GPU raw consumers vector (addSink RAW, removeSink, publishToRawConsumers)
//      (consumersMu_, fullResConsumersMu_, trackerConsumersMu_, rawConsumersMu_ are independent of each other)
//   3. Consumer::mu        — per-consumer mailbox (publish*, dispatch thread)
//   paramsMu_ is independent: only held momentarily for a snapshot copy.
//   rawConsumer_ is managed like consumers_ entries but outside the vector so
//   it receives pre-saturation frames independent of publishToConsumers.

#include "cambrian_camera_native.h"
#include "InputRing.h"

#include <android/native_window.h>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include <opencv2/core.hpp>

namespace cam {

/// User-adjustable processing parameters. All fields have identity defaults.
/// setParams() is thread-safe; the processing loop reads a snapshot under paramsMu_.
struct ProcessingParams {
    float blackR = 0.f, blackG = 0.f, blackB = 0.f;  ///< [0, 0.5] per-channel black level
    float gamma      = 1.f;                            ///< [0.1, 4.0]; 1.0 = identity
    float brightness = 0.f;                            ///< [-1, 1]; 0.0 = identity
    float saturation = 1.f;                            ///< [0, 3]; 1.0 = identity
};

/// Internal shared frame distributed to all consumers. cv::Mat is kept out of
/// the public API; SinkFrame exposes raw pointers into this struct's bgr data.
struct Frame {
    uint64_t id        = 0;
    FrameMetadata meta = {};
    cv::Mat bgr;           ///< CV_8UC3, BGR — internal only, not in public header
    int width  = 0;
    int height = 0;
    int stride = 0;        ///< bytes per row (bgr.step)
    PixelFormat format = PixelFormat::BGR;
};
using SharedFrame = std::shared_ptr<Frame>;

class ImagePipeline : public IImagePipeline {
public:
    /// Construct with a preview window and stream dimensions for InputRing pre-allocation.
    /// @param debugLevel  0=errors only, 1=lifecycle, 2=periodic/perf
    ImagePipeline(ANativeWindow* window, int width, int height, int debugLevel = 0);

    /// Shuts down processing thread and all consumer threads, releases the window.
    ~ImagePipeline() override;

    // Non-copyable, non-movable.
    ImagePipeline(const ImagePipeline&) = delete;
    ImagePipeline& operator=(const ImagePipeline&) = delete;

    /// Replace the processed-preview surface (e.g. after Flutter surface recreation).
    void setPreviewWindow(ANativeWindow* window);

    /// Replace the raw-preview surface — receives BGR frames before any processing.
    void setRawPreviewWindow(ANativeWindow* window);

    /// Push a YUV frame into the input ring. Returns immediately — the caller may
    /// close the camera Image right after this call returns.
    void deliverYuv(const uint8_t* y,  int yRowStride,
                    const uint8_t* u,  const uint8_t* v,
                    int uvRowStride,
                    int width, int height,
                    int yuvFormat,
                    uint64_t frameId, const FrameMetadata& meta);

    /// Atomically update processing parameters. Takes effect on the next frame.
    void setParams(const ProcessingParams& p);

    /// GPU entry point: called from GL thread after mapping fullResPbo[readIdx].
    /// Copies RGBA data into a SharedFrame and dispatches to fullResConsumers_.
    void deliverFullResRgba(const uint8_t* rgba, int w, int h, int stride,
                            uint64_t frameId, const FrameMetadata& meta);

    /// GPU entry point: called from GL thread after mapping trackerPbo[readIdx].
    /// Copies RGBA data into a SharedFrame and dispatches to trackerConsumers_.
    void deliverTrackerRgba(const uint8_t* rgba, int w, int h, int stride,
                            uint64_t frameId, const FrameMetadata& meta);

    /// GPU entry point: called from GL thread after mapping rawPbo[readIdx].
    /// Copies RGBA data into a SharedFrame and dispatches to rawConsumers_.
    void deliverRawRgba(const uint8_t* rgba, int w, int h, int stride,
                        uint64_t frameId, const FrameMetadata& meta);

    // -- IImagePipeline ----------------------------------------------------------
    void addSink(const SinkConfig& config, SinkCallback callback) override;
    void removeSink(const std::string& name) override;

    /// Returns the cumulative number of frames dropped by InputRing due to dimension mismatch.
    int getDimensionMismatchCount() const { return inputRing_.dimensionMismatchCount_.load(); }

private:
    int debugLevel_ = 0;  ///< 0=errors only, 1=lifecycle, 2=periodic/perf

    // -- Preview windows ---------------------------------------------------------
    std::mutex windowMu_;
    ANativeWindow* previewWindow_    = nullptr;  ///< processed output (post-saturation)
    ANativeWindow* rawPreviewWindow_ = nullptr;  ///< raw output (pre-processing)
    int lastWidth_     = 0;
    int lastHeight_    = 0;
    int rawLastWidth_  = 0;
    int rawLastHeight_ = 0;
    cv::Mat previewRgba_;     ///< RGBA scratch buffer for processed preview; reused each frame
    cv::Mat rawPreviewRgba_;  ///< RGBA scratch buffer for raw preview; reused each frame

    // -- Processing params -------------------------------------------------------
    std::mutex paramsMu_;
    ProcessingParams params_;

    // -- Input ring + processing thread ------------------------------------------
    InputRing inputRing_;
    std::thread processingThread_;
    void processingLoop();

    // -- Consumer mailboxes ------------------------------------------------------
    struct Consumer {
        std::string name;
        SinkCallback callback;

        SharedFrame pending;         ///< 1-slot mailbox; null when empty
        std::mutex mu;
        std::condition_variable cv;
        std::thread dispatchThread;
        std::atomic<bool> running{true};
    };

    // -- CPU-path consumer mailboxes (built-in __preview, publishToConsumers) ----
    std::mutex consumersMu_;
    std::vector<std::unique_ptr<Consumer>> consumers_;

    /// Dedicated consumer for raw (pre-saturation) preview; not in consumers_.
    std::unique_ptr<Consumer> rawConsumer_;

    // -- Full-res consumer mailboxes (SinkRole::FULL_RES) ------------------------
    std::mutex fullResConsumersMu_;
    std::vector<std::unique_ptr<Consumer>> fullResConsumers_;

    // -- Tracker consumer mailboxes (SinkRole::TRACKER) --------------------------
    std::mutex trackerConsumersMu_;
    std::vector<std::unique_ptr<Consumer>> trackerConsumers_;

    // -- Raw consumer mailboxes (SinkRole::RAW) ----------------------------------
    std::mutex rawConsumersMu_;
    std::vector<std::unique_ptr<Consumer>> rawConsumers_;

    void publishToConsumers(SharedFrame frame);
    void publishToRawConsumer(SharedFrame frame);
    void publishToFullResConsumers(SharedFrame frame);
    void publishToTrackerConsumers(SharedFrame frame);
    void publishToRawConsumers(SharedFrame frame);
    void startConsumerThread(Consumer* c);
    void shutdownConsumer(Consumer* c);
    void shutdownConsumers();

    // -- Helpers -----------------------------------------------------------------
    /// Blit an RGBA mat to an ANativeWindow. Acquires windowMu_ internally;
    /// must NOT be called with windowMu_ already held (deadlock).
    /// window/lastW/lastH are the pipeline members for that window slot.
    void blitToWindow(ANativeWindow*& window, int& lastW, int& lastH, const cv::Mat& rgba);
};

} // namespace cam
