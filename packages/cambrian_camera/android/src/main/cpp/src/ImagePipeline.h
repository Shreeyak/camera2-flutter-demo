#pragma once
// Internal header for the Phase 3 identity image pipeline.
// Not part of the public consumer API (see cambrian_camera_native.h).

#include <android/native_window.h>
#include <cstdint>
#include <mutex>

namespace cam {

/// Phase 3 identity pipeline: receives raw RGBA frames from Kotlin (via a
/// direct ByteBuffer backed by ImageReader) and copies them pixel-row by
/// pixel-row into an ANativeWindow for display.
///
/// Thread safety: setPreviewWindow() may be called from the UI thread while
/// processFrame() runs on the camera background thread. Both methods hold
/// mutex_ for the duration of their access to previewWindow_.
///
/// Phase 4 will extend this class to:
///   - Apply black balance, white balance, LUT, and saturation corrections
///   - Dispatch processed frames to registered IImagePipeline sinks
class ImagePipeline {
public:
    /// Construct the pipeline with an optional preview window.
    /// @param window  ANativeWindow obtained from ANativeWindow_fromSurface(),
    ///                or nullptr to start with no preview (same as calling
    ///                setPreviewWindow(nullptr) after construction).  When
    ///                non-null the pipeline calls ANativeWindow_acquire()
    ///                internally, so the caller may release their reference.
    explicit ImagePipeline(ANativeWindow* window);

    /// Releases the ANativeWindow reference held by this pipeline.
    ~ImagePipeline();

    // Non-copyable, non-movable — owns a raw pointer resource.
    ImagePipeline(const ImagePipeline&) = delete;
    ImagePipeline& operator=(const ImagePipeline&) = delete;

    /// Replace the preview surface, e.g. when the Flutter PlatformView is
    /// recreated after an app resume.  The old ANativeWindow reference is
    /// released before the new one is stored.
    /// @param window  New ANativeWindow, or nullptr to pause rendering.
    void setPreviewWindow(ANativeWindow* window);

    /// Copy one RGBA frame into the preview ANativeWindow (identity pipeline).
    ///
    /// @param data    Pointer to the first byte of the frame (top-left pixel).
    ///                Obtained via JNIEnv::GetDirectBufferAddress().
    /// @param width   Frame width in pixels.
    /// @param height  Frame height in pixels.
    /// @param stride  Source row stride in **bytes**  (>= width * 4).
    ///                May differ from width * 4 due to ImageReader alignment.
    ///
    /// The destination stride is taken from ANativeWindow_Buffer::stride which
    /// is expressed in **pixels**; we multiply by 4 to get bytes per row.
    void processFrame(const uint8_t* data, int width, int height, int stride);

private:
    std::mutex mutex_;
    ANativeWindow* previewWindow_ = nullptr;
    /// Cached frame dimensions — ANativeWindow_setBuffersGeometry is only
    /// called when these change, keeping it out of the per-frame hot path.
    int lastWidth_  = 0;
    int lastHeight_ = 0;
};

} // namespace cam
