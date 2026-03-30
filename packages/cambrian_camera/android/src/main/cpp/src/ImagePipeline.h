#pragma once
// Internal header for the Phase 3 identity image pipeline.
// Not part of the public consumer API (see cambrian_camera_native.h).

#include <android/native_window.h>
#include <cstdint>

namespace cam {

/// Phase 3 identity pipeline: receives raw RGBA frames from Kotlin (via a
/// direct ByteBuffer backed by ImageReader) and copies them pixel-row by
/// pixel-row into an ANativeWindow for display.
///
/// Phase 4 will extend this class to:
///   - Apply black balance, white balance, LUT, and saturation corrections
///   - Dispatch processed frames to registered IImagePipeline sinks
class ImagePipeline {
public:
    /// Construct the pipeline and take ownership of the given ANativeWindow.
    /// @param window  ANativeWindow obtained from ANativeWindow_fromSurface().
    ///                Must not be null. The pipeline calls ANativeWindow_acquire()
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
    ANativeWindow* previewWindow_ = nullptr;
};

} // namespace cam
