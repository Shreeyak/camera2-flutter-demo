#pragma once
// Public consumer API for the Cambrian Camera native library.
// Phase 3: defines data types only.
// Phase 4 will add IImagePipeline::addSink() / removeSink() and a full sink
// dispatch loop (black balance → WB → LUT → saturation).

#include <cstdint>
#include <functional>
#include <string>

namespace cam {

/// Per-frame sensor metadata passed through the pipeline alongside pixel data.
/// Populated from Camera2 CaptureResult on the Kotlin side and transferred via
/// flat long[]/int[] arrays (see MetadataLayout.h / MetadataLayout.kt).
struct FrameMetadata {
    int64_t frameNumber;       ///< Monotonically increasing frame counter
    int64_t sensorTimestampNs; ///< Sensor capture start time, nanoseconds
    int64_t exposureTimeNs;    ///< Actual exposure duration, nanoseconds
    int32_t iso;               ///< Sensor sensitivity (ISO equivalent)
    // Phase 4 will add: focus distance, WB gains, lens intrinsics, etc.
};

/// A single frame delivered to a registered sink.
/// The pixel buffer is valid only for the duration of the SinkCallback
/// invocation; call release() if you need to retain it beyond that scope.
struct SinkFrame {
    const uint8_t* data; ///< Pixel data pointer (row-major, tightly packed per channel)
    int width;           ///< Frame width in pixels
    int height;          ///< Frame height in pixels
    int stride;          ///< Row stride in bytes (may be > width * channels)
    int channels;        ///< Bytes per pixel (4 = RGBA)
    FrameMetadata meta;
    /// Call this to extend the lifetime of `data` past the callback return.
    /// No-op in Phase 3 (buffer is owned by the JNI direct ByteBuffer).
    std::function<void()> release = [](){};
};

/// Configuration passed when registering a new processing sink (Phase 4).
struct SinkConfig {
    std::string name;          ///< Unique human-readable identifier
    int width  = 0;            ///< Desired output width; 0 = passthrough
    int height = 0;            ///< Desired output height; 0 = passthrough
    int channels     = 4;      ///< Output channel count (default RGBA)
    int channelIndex = -1;     ///< If >= 0, extract single channel at this index
    int ringSize     = 4;      ///< Ring-buffer depth before drop/block
    bool dropOnFull  = true;   ///< Drop newest frame when ring is full (vs. block)
};

/// Callback type invoked for each frame delivered to a sink.
using SinkCallback = std::function<void(SinkFrame&)>;

/// Abstract pipeline interface.  Phase 3: stub only.
/// Phase 4 will make this the central dispatch hub for all processing sinks.
class IImagePipeline {
public:
    virtual ~IImagePipeline() = default;
    // Phase 4: virtual int  addSink(const SinkConfig&, SinkCallback) = 0;
    // Phase 4: virtual void removeSink(int sinkId) = 0;
};

} // namespace cam
