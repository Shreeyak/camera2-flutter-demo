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
/// flat JNI parameters in nativeGpuDrawAndReadback.
struct FrameMetadata {
    int64_t frameNumber;       ///< Monotonically increasing frame counter
    int64_t sensorTimestampNs; ///< Sensor capture start time, nanoseconds
    int64_t exposureTimeNs;    ///< Actual exposure duration, nanoseconds
    int32_t iso;               ///< Sensor sensitivity (ISO equivalent)
    // Future: focus distance, WB gains, lens intrinsics, etc.
};

/// Pixel layout of the data buffer delivered to a sink.
enum class PixelFormat {
    RGBA,  ///< 8-bit RGBA, 4 bytes per pixel. All pipeline outputs.
};

/// A single frame delivered to a registered sink.
/// The pixel buffer is valid only for the duration of the SinkCallback invocation.
/// Copy the data if you need it beyond that scope.
struct SinkFrame {
    const uint8_t* data;    ///< Pixel data pointer (row-major)
    int width;              ///< Frame width in pixels
    int height;             ///< Frame height in pixels
    int stride;             ///< Row stride in bytes; may exceed width * channels
                            ///< for ROI submats or aligned allocations — always check
    PixelFormat format;     ///< Pixel layout of data
    uint64_t frameId;       ///< Monotonic frame counter
    FrameMetadata meta;     ///< Per-frame sensor metadata
};

/// Routing role for a registered sink.
/// Controls which frame stream the sink receives.
enum class SinkRole {
    FULL_RES,  ///< receives full-resolution RGBA (stitcher, any full-res sink)
    TRACKER,   ///< receives 480p-height downscaled RGBA
    RAW,       ///< receives passthrough (pre-color-processing) RGBA at rawStreamHeight
};

/// Configuration for registering a consumer sink on the pipeline.
struct SinkConfig {
    std::string name;                    ///< Unique identifier; passed to removeSink() to deregister
    SinkRole    role = SinkRole::FULL_RES;  ///< Routing role; default FULL_RES is backward compatible
};

/// Callback type invoked for each frame delivered to a sink.
using SinkCallback = std::function<void(const SinkFrame&)>;

/// Hook called on a dedicated processing thread before consumer dispatch.
/// Modify rgba data in-place. The buffer is valid for the duration of the call.
using FrameHookFn = std::function<void(uint8_t* rgba, int w, int h, int stride)>;

/// Abstract pipeline interface for consumer sink registration.
///
/// Obtain a pointer via CambrianCamera.getNativePipelineHandle() (Dart) or
/// CameraController.getNativePipelineHandle() (Kotlin), then cast to
/// IImagePipeline* to register sinks.
class IImagePipeline {
public:
    virtual ~IImagePipeline() = default;

    /// Register an optional CPU processing hook for frames of the given role.
    /// The hook runs on a dedicated thread; pass nullptr to clear.
    virtual void setFrameHook(SinkRole role, FrameHookFn fn) = 0;

    /// Register a consumer sink on the pipeline.
    /// The sink is identified by config.name; use that name with removeSink().
    ///
    /// Routing is determined by config.role:
    ///   - SinkRole::FULL_RES — receives full-resolution RGBA via deliverFullResRgba().
    ///   - SinkRole::TRACKER  — receives 480p-height downscaled RGBA via deliverTrackerRgba().
    ///   - SinkRole::RAW      — receives passthrough RGBA at rawStreamHeight via deliverRawRgba().
    virtual void addSink(const SinkConfig& config, SinkCallback callback) = 0;

    /// Remove a previously registered sink by name. Blocks until its dispatch thread exits.
    virtual void removeSink(const std::string& name) = 0;
};

} // namespace cam
