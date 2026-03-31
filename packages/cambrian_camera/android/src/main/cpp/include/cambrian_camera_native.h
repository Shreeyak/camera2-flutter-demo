#pragma once
// Public consumer API for the Cambrian Camera native library.
// Defines data types for frame metadata, sink configuration, and the
// IImagePipeline interface for registering consumer sinks.

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
    // Future: focus distance, WB gains, lens intrinsics, etc.
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
    /// Allows the sink to retain the buffer beyond the callback scope.
    std::function<void()> release = [](){};
};

/// Configuration for registering a consumer sink on the pipeline.
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

/// Abstract pipeline interface for consumer sink registration.
///
/// Obtain a pointer via CambrianCamera.getNativePipelineHandle() (Dart) or
/// CameraController.getNativePipelineHandle() (Kotlin), then cast to
/// IImagePipeline* to register sinks.
class IImagePipeline {
public:
    virtual ~IImagePipeline() = default;

    /// Register a consumer sink that receives processed RGBA frames.
    /// Returns a unique sink ID for later removal via [removeSink].
    virtual int  addSink(const SinkConfig& config, SinkCallback callback) = 0;

    /// Remove a previously registered sink. Blocks until its dispatch thread exits.
    virtual void removeSink(int sinkId) = 0;
};

} // namespace cam
