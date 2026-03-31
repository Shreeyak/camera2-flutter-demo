#pragma once
// Internal header for the image pipeline.
// Converts YUV_420_888 frames to RGBA with per-frame processing (saturation,
// and in future: black balance, gamma, histogram stretch, brightness).
// Writes processed output to an ANativeWindow (Flutter SurfaceProducer).

#include "cambrian_camera_native.h"

#include <android/native_window.h>
#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace cam {

/// User-adjustable processing parameters. All fields have identity defaults.
/// setParams() is thread-safe; the per-frame loop reads a snapshot under paramsMu_.
/// Currently only saturation is applied; remaining fields will be wired incrementally.
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
/// outputs processed RGBA frames to an ANativeWindow (Flutter SurfaceProducer),
/// and dispatches copies to registered consumer sinks via per-sink ring buffers.
///
/// Thread safety — lock ordering (always acquire in this order to prevent deadlock):
///   1. mutex_    — protects ANativeWindow access (setPreviewWindow, processFrameYuv)
///   2. sinksMu_  — protects the sinks_ vector (addSink, removeSink, dispatchToSinks)
///   3. SinkSlot::mu — per-sink ring buffer (producer in dispatchToSinks, consumer in
///                     the sink's dispatch thread)
///   paramsMu_ is independent: only held momentarily for a snapshot copy, never
///   held while acquiring any other lock.
class ImagePipeline : public IImagePipeline {
public:
    /// Construct with an optional preview window (acquires its own ANativeWindow reference).
    explicit ImagePipeline(ANativeWindow* window);

    /// Stops all sink dispatch threads and releases the ANativeWindow reference.
    ~ImagePipeline() override;

    // Non-copyable, non-movable — owns raw pointer resources and threads.
    ImagePipeline(const ImagePipeline&) = delete;
    ImagePipeline& operator=(const ImagePipeline&) = delete;

    /// Replace the preview surface (e.g. after Flutter PlatformView recreation).
    void setPreviewWindow(ANativeWindow* window);

    /// Convert YUV_420_888 planes to RGBA, apply processing, write to preview,
    /// and dispatch to registered sinks.
    void processFrameYuv(const uint8_t* yData, int yRowStride,
                         const uint8_t* uData, const uint8_t* vData,
                         int uvRowStride, int uvPixelStride,
                         int width, int height);

    /// Atomically update processing parameters. Takes effect on the next frame.
    void setParams(const ProcessingParams& p);

    // -- IImagePipeline -----------------------------------------------------------
    int  addSink(const SinkConfig& config, SinkCallback callback) override;
    void removeSink(int sinkId) override;

private:
    // -- Preview window -----------------------------------------------------------
    std::mutex mutex_;
    ANativeWindow* previewWindow_ = nullptr;
    int lastWidth_  = 0;
    int lastHeight_ = 0;

    // -- Processing params --------------------------------------------------------
    std::mutex paramsMu_;
    ProcessingParams params_;  // protected by paramsMu_

    // -- Consumer sinks -----------------------------------------------------------

    /// Per-sink state: ring buffer, dispatch thread, and synchronisation.
    struct SinkSlot {
        SinkConfig config;
        SinkCallback callback;
        int id = 0;

        // Ring buffer: `ringSize` pre-allocated byte vectors.
        std::vector<std::vector<uint8_t>> ring;
        int writeIdx = 0;
        int readIdx  = 0;
        int count    = 0;
        int frameWidth  = 0;   // actual dimensions written into ring slots
        int frameHeight = 0;
        int frameStride = 0;

        std::mutex mu;
        std::condition_variable cv;
        std::thread dispatchThread;
        std::atomic<bool> running{true};
    };

    std::mutex sinksMu_;
    std::vector<std::unique_ptr<SinkSlot>> sinks_;  // protected by sinksMu_
    int nextSinkId_ = 1;

    /// Copy the processed RGBA frame into each registered sink's ring buffer.
    /// Called from processFrameYuv while mutex_ is held (ANativeWindow still locked).
    void dispatchToSinks(const uint8_t* rgbaData, int width, int height, int stride);

    /// Tear down all sink dispatch threads. Called from the destructor.
    void shutdownSinks();
};

} // namespace cam
