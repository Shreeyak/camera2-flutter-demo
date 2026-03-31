// JNI glue between Kotlin (CameraController) and the native ImagePipeline.
//
// All four methods are thin wrappers: they validate inputs, convert JNI types
// to C++ types, and delegate to ImagePipeline.  No image logic lives here.
//
// JNI naming convention: each function name encodes the fully-qualified Kotlin
// class path: Java_<package_underscored>_<ClassName>_<methodName>.

#include "ImagePipeline.h"

#include <android/log.h>
#include <android/native_window_jni.h> // ANativeWindow_fromSurface
#include <jni.h>

#define TAG  "CambrianCamera"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ---------------------------------------------------------------------------
// Helper to cast the opaque jlong handle back to an ImagePipeline pointer.
// Using a named helper avoids scattered reinterpret_casts in every function.
// ---------------------------------------------------------------------------
static cam::ImagePipeline* pipelineFromHandle(jlong handle) {
    return reinterpret_cast<cam::ImagePipeline*>(static_cast<uintptr_t>(handle));
}

extern "C" {

// ---------------------------------------------------------------------------
// nativeInit
//
// Called once when CameraController is constructed.  Creates the pipeline and
// returns an opaque pointer (as jlong) that Kotlin stores and passes back on
// every subsequent JNI call.
//
// @param previewSurface  The Android Surface that backs the Flutter preview widget.
// @return  Non-zero handle on success; 0 on failure.
// ---------------------------------------------------------------------------
JNIEXPORT jlong JNICALL
Java_com_cambrian_camera_CameraController_nativeInit(
        JNIEnv* env, jclass /*clazz*/, jobject previewSurface) {
    if (!previewSurface) {
        LOGE("nativeInit: previewSurface is null");
        return 0;
    }

    // Obtain a native window from the Java Surface object.
    // ANativeWindow_fromSurface acquires a reference; we transfer that
    // reference to ImagePipeline (which acquires its own in its constructor).
    ANativeWindow* window = ANativeWindow_fromSurface(env, previewSurface);
    if (!window) {
        LOGE("nativeInit: ANativeWindow_fromSurface returned null");
        return 0;
    }

    auto* pipeline = new cam::ImagePipeline(window);

    // ImagePipeline::ImagePipeline() acquires its own reference, so we release
    // the one we got from ANativeWindow_fromSurface.
    ANativeWindow_release(window);

    LOGD("nativeInit: pipeline created at %p", pipeline);
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(pipeline));
}

// ---------------------------------------------------------------------------
// nativeDeliverFrame
//
// Called by the Kotlin ImageReader.OnImageAvailableListener for every captured
// frame.  pixelBuffer is a direct ByteBuffer wrapping the ImageReader plane
// data; GetDirectBufferAddress gives us a zero-copy pointer into it.
//
// @param pipelinePtr  Handle returned by nativeInit.
// @param pixelBuffer  Direct ByteBuffer containing RGBA pixel data.
// @param width        Frame width in pixels.
// @param height       Frame height in pixels.
// @param stride       Source row stride in bytes (from ImageReader plane).
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_CameraController_nativeDeliverFrame(
        JNIEnv* env, jclass /*clazz*/,
        jlong pipelinePtr, jobject pixelBuffer,
        jint width, jint height, jint stride) {
    if (!pipelinePtr) {
        LOGE("nativeDeliverFrame: null pipeline handle");
        return;
    }
    if (!pixelBuffer) {
        LOGE("nativeDeliverFrame: null pixelBuffer");
        return;
    }

    // GetDirectBufferAddress returns a raw pointer into the direct buffer's
    // backing memory.  This is safe as long as we don't hold it past the JNI
    // call (ImageReader plane data is valid until Image.close()).
    const auto* data = reinterpret_cast<const uint8_t*>(
            env->GetDirectBufferAddress(pixelBuffer));
    if (!data) {
        LOGE("nativeDeliverFrame: GetDirectBufferAddress returned null — "
             "ensure pixelBuffer is a direct ByteBuffer");
        return;
    }

    pipelineFromHandle(pipelinePtr)->processFrame(data, width, height, stride);
}

// ---------------------------------------------------------------------------
// nativeRelease
//
// Called when CameraController is disposed.  Deletes the pipeline and frees
// the ANativeWindow reference it holds.
//
// @param pipelinePtr  Handle returned by nativeInit.
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_CameraController_nativeRelease(
        JNIEnv* /*env*/, jclass /*clazz*/, jlong pipelinePtr) {
    if (!pipelinePtr) {
        LOGE("nativeRelease: null pipeline handle — already released?");
        return;
    }

    LOGD("nativeRelease: deleting pipeline at handle %lld",
         static_cast<long long>(pipelinePtr));
    delete pipelineFromHandle(pipelinePtr);
}

// ---------------------------------------------------------------------------
// nativeSetPreviewWindow
//
// Called when the Flutter Surface is recreated (e.g. after app resume or
// hot-restart).  Swaps the ANativeWindow without tearing down the pipeline.
//
// @param pipelinePtr     Handle returned by nativeInit.
// @param previewSurface  New Android Surface, or null to pause rendering.
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_CameraController_nativeSetPreviewWindow(
        JNIEnv* env, jclass /*clazz*/,
        jlong pipelinePtr, jobject previewSurface) {
    if (!pipelinePtr) {
        LOGE("nativeSetPreviewWindow: null pipeline handle");
        return;
    }

    // previewSurface may legitimately be null (surface destroyed).
    ANativeWindow* window = nullptr;
    if (previewSurface) {
        window = ANativeWindow_fromSurface(env, previewSurface);
        if (!window) {
            LOGE("nativeSetPreviewWindow: ANativeWindow_fromSurface returned null");
            return;
        }
    }

    pipelineFromHandle(pipelinePtr)->setPreviewWindow(window);

    // setPreviewWindow acquires its own reference; release the one we obtained.
    if (window) {
        ANativeWindow_release(window);
    }
}

} // extern "C"
