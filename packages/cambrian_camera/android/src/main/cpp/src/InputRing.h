#pragma once
// YUV input ring buffer.
// Receives YUV_420_888 frames from the camera JNI thread, copies them into
// pre-allocated slots (stripping Camera2 row-stride padding), and notifies a
// single processing thread. Drop-on-full — the camera thread never blocks.

#include "cambrian_camera_native.h"

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <vector>

namespace cam {

// YUV format constants — kept in sync with CameraController.kt companion object.
constexpr int YUV_FORMAT_UNKNOWN = 0;
constexpr int YUV_FORMAT_NV21    = 1;  ///< VU interleaved (Android default)
constexpr int YUV_FORMAT_NV12    = 2;  ///< UV interleaved
constexpr int YUV_FORMAT_I420    = 3;  ///< Planar: U plane then V plane

/// One pre-allocated slot in the input ring.
struct YuvSlot {
    std::vector<uint8_t> yData;   ///< Packed Y plane: width × height bytes (no stride)
    std::vector<uint8_t> uvData;  ///< Packed chroma: width × height/2 bytes (no stride)
                                   ///< NV21: VU interleaved | NV12: UV interleaved
                                   ///< I420: U plane followed immediately by V plane
    int width     = 0;
    int height    = 0;
    int yuvFormat = YUV_FORMAT_UNKNOWN;
    uint64_t frameId = 0;
    FrameMetadata meta{};
};

class InputRing {
public:
    /// Pre-allocate `ringSize` slots sized for `width × height` frames.
    InputRing(int width, int height, int ringSize = 4);

    /// Called from the JNI/camera thread. Copies YUV planes, strips row-stride padding.
    /// Drops the frame silently if the ring is full (camera thread never blocks).
    void push(const uint8_t* y,  int yRowStride,
              const uint8_t* u,  const uint8_t* v,
              int uvRowStride,
              int width, int height,
              int yuvFormat,
              uint64_t frameId, const FrameMetadata& meta);

    /// Called from the processing thread. Blocks until a slot is ready.
    /// Moves slot data into `out` via swap (O(1)). Returns false on shutdown.
    bool pop(YuvSlot& out);

    /// Signal the processing thread to exit. Wakes any blocked pop() call.
    void shutdown();

    /// Cumulative count of frames dropped due to dimension mismatch.
    /// Atomic so it can be read from any thread without holding mu_.
    std::atomic<int> dimensionMismatchCount_{0};

private:
    int width_;
    int height_;
    std::vector<YuvSlot> slots_;
    int writeIdx_  = 0;
    int readIdx_   = 0;
    int count_     = 0;
    bool shutdown_ = false;
    std::mutex mu_;
    std::condition_variable cv_;
};

} // namespace cam
