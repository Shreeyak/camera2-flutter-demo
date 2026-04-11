#pragma once
// Image pipeline: receives RGBA frames from the GPU (via GL thread callbacks),
// routes them through an optional per-role ProcessingStage (dedicated hook thread),
// and distributes shared frames to registered consumer sinks via per-consumer mailboxes.
//
// Thread safety — lock ordering (always acquire in this order):
//   1. fullResConsumersMu_ — GPU full-res consumers vector (addSink FULL_RES, removeSink, publishToFullResConsumers)
//      trackerConsumersMu_ — GPU tracker consumers vector (addSink TRACKER, removeSink, publishToTrackerConsumers)
//      rawConsumersMu_     — GPU raw consumers vector (addSink RAW, removeSink, publishToRawConsumers)
//      (fullResConsumersMu_, trackerConsumersMu_, rawConsumersMu_ are independent of each other)
//   2. ProcessingStage::mu — never nested with consumer vector mutexes
//   3. Consumer::mu        — per-consumer mailbox (publish*, dispatch thread)

#include "cambrian_camera_native.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace cam {

/// Internal shared frame distributed to all consumers.
/// SinkFrame exposes raw pointers into this struct's data vector.
struct Frame {
    uint64_t id        = 0;
    FrameMetadata meta = {};
    std::vector<uint8_t> data;  ///< RGBA pixel bytes (row-major)
    int width  = 0;
    int height = 0;
    int stride = 0;             ///< bytes per row
    PixelFormat format = PixelFormat::RGBA;
};
using SharedFrame = std::shared_ptr<Frame>;

/// Processing stage: optional dedicated thread with 1-slot mailbox.
/// When a hook is registered, frames are routed through here before consumers.
struct ProcessingStage {
    ProcessingStage() = default;
    ProcessingStage(const ProcessingStage&) = delete;
    ProcessingStage& operator=(const ProcessingStage&) = delete;

    FrameHookFn hook;                     // null = disabled
    std::atomic<bool> hookActive{false};  // atomic mirror of (hook != nullptr), safe to read from GL thread
    SharedFrame pending;                  // 1-slot mailbox
    std::mutex mu;
    std::condition_variable cv;
    std::thread thread;
    std::atomic<bool> running{false};
};

class ImagePipeline : public IImagePipeline {
public:
    /// Construct pipeline. No ANativeWindow or input ring needed; GPU path only.
    ImagePipeline();

    /// Shuts down processing stages and all consumer threads.
    ~ImagePipeline() override;

    // Non-copyable, non-movable.
    ImagePipeline(const ImagePipeline&) = delete;
    ImagePipeline& operator=(const ImagePipeline&) = delete;

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

    /// Capture the next delivered full-res RGBA frame and encode it to disk.
    ///
    /// Sets an atomic flag so the next deliverFullResRgba call stores its frame,
    /// then blocks until that frame arrives (up to timeoutMs) before encoding.
    /// Format is inferred from outputPath extension (.jpg/.jpeg → JPEG, else PNG).
    ///
    /// @param outputPath  Absolute path including filename and extension.
    /// @param jpegQuality JPEG encode quality [1-100]; ignored for PNG.
    /// @param timeoutMs   Maximum wait for next frame in milliseconds.
    /// @return true on success; false on timeout or encode failure.
    bool captureToFile(const std::string& outputPath, int jpegQuality = 90,
                       int timeoutMs = 500);

    /// Like captureToFile but writes encoded bytes to an open file descriptor.
    ///
    /// Used by the Kotlin layer when saving via MediaStore (Android 10+ scoped
    /// storage): Kotlin inserts the MediaStore entry, opens a writable fd from
    /// the resulting content URI, and passes it here.  The caller retains
    /// ownership of fd and must close it after this call returns.
    ///
    /// @param fd          Writable POSIX file descriptor.
    /// @param asJpeg      true → JPEG encode; false → PNG encode.
    /// @param jpegQuality JPEG encode quality [1-100]; ignored for PNG.
    /// @param timeoutMs   Maximum wait for next frame in milliseconds.
    /// @return true on success; false on timeout or encode failure.
    bool captureToFd(int fd, bool asJpeg, int jpegQuality = 90,
                     int timeoutMs = 500);

    // -- IImagePipeline ----------------------------------------------------------
    void setFrameHook(SinkRole role, FrameHookFn fn) override;
    void addSink(const SinkConfig& config, SinkCallback callback) override;
    void removeSink(const std::string& name) override;

private:
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

    // -- Full-res consumer mailboxes (SinkRole::FULL_RES) ------------------------
    std::mutex fullResConsumersMu_;
    std::vector<std::unique_ptr<Consumer>> fullResConsumers_;

    // -- Tracker consumer mailboxes (SinkRole::TRACKER) --------------------------
    std::mutex trackerConsumersMu_;
    std::vector<std::unique_ptr<Consumer>> trackerConsumers_;

    // -- Raw consumer mailboxes (SinkRole::RAW) ----------------------------------
    std::mutex rawConsumersMu_;
    std::vector<std::unique_ptr<Consumer>> rawConsumers_;

    // -- Processing stages (one per role) ----------------------------------------
    ProcessingStage fullResStage_;
    ProcessingStage trackerStage_;
    ProcessingStage rawStage_;

    // -- On-request frame capture -------------------------------------------------
    // captureRequested_ is set by captureToFile() and cleared by deliverFullResRgba()
    // when it stores the captured frame. Zero steady-state overhead: when the flag is
    // false, the fast-path early-return in deliverFullResRgba is unaffected.
    std::atomic<bool>       captureRequested_{false};
    std::mutex              captureResultMu_;
    std::condition_variable captureCV_;
    SharedFrame             capturedFrame_;  ///< populated by deliverFullResRgba when captureRequested_

    void publishToFullResConsumers(SharedFrame frame);
    void publishToTrackerConsumers(SharedFrame frame);
    void publishToRawConsumers(SharedFrame frame);
    void startConsumerThread(Consumer* c);
    void shutdownConsumer(Consumer* c);
    void shutdownConsumers();

    void startProcessingStage(ProcessingStage& stage,
                              void (ImagePipeline::*publishFn)(SharedFrame));
    void shutdownProcessingStage(ProcessingStage& stage);
    void routeFrame(ProcessingStage& stage, SharedFrame frame,
                    void (ImagePipeline::*publishFn)(SharedFrame));
};

} // namespace cam
