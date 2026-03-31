// JNI glue between Kotlin (CameraController) and the native ImagePipeline.
//
// Five entry points: nativeInit, nativeRelease, nativeSetPreviewWindow,
// nativeDeliverYuv, and nativeSetProcessingParams.  Each is a thin wrapper
// that validates inputs, converts JNI types to C++, and delegates to
// ImagePipeline.  No image logic lives here.
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
// ---------------------------------------------------------------------------
static cam::ImagePipeline* pipelineFromHandle(jlong handle) {
    return reinterpret_cast<cam::ImagePipeline*>(static_cast<uintptr_t>(handle));
}

extern "C" {

// ---------------------------------------------------------------------------
// nativeInit
//
// Called once when the Camera2 capture session is configured.  Creates the
// pipeline, pre-allocates the InputRing for the given stream dimensions, and
// returns an opaque pointer (as jlong) that Kotlin stores for all subsequent
// JNI calls.
//
// @param previewSurface  Android Surface backing the Flutter preview widget.
// @param width           Stream width in pixels.
// @param height          Stream height in pixels.
// @return  Non-zero handle on success; 0 on failure.
// ---------------------------------------------------------------------------
JNIEXPORT jlong JNICALL
Java_com_cambrian_camera_CameraController_nativeInit(
        JNIEnv* env, jclass /*clazz*/,
        jobject previewSurface,
        jint width, jint height) {
    if (!previewSurface) {
        LOGE("nativeInit: previewSurface is null");
        return 0;
    }

    ANativeWindow* window = ANativeWindow_fromSurface(env, previewSurface);
    if (!window) {
        LOGE("nativeInit: ANativeWindow_fromSurface returned null");
        return 0;
    }

    auto* pipeline = new cam::ImagePipeline(window,
                                            static_cast<int>(width),
                                            static_cast<int>(height));

    // ImagePipeline acquires its own reference; release the one from fromSurface.
    ANativeWindow_release(window);

    LOGD("nativeInit: pipeline created at %p dims=%dx%d", pipeline,
         static_cast<int>(width), static_cast<int>(height));
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(pipeline));
}

// ---------------------------------------------------------------------------
// nativeRelease
//
// Called when CameraController is disposed.  Deletes the pipeline and frees
// all resources it holds.
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

// ---------------------------------------------------------------------------
// nativeSetRawPreviewWindow
//
// Called once after nativeInit to attach the raw (pre-processing) preview surface.
// May also be called on surface recreation events.
//
// @param pipelinePtr      Handle returned by nativeInit.
// @param previewSurface   Android Surface for the raw preview, or null to stop rendering.
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_CameraController_nativeSetRawPreviewWindow(
        JNIEnv* env, jclass /*clazz*/,
        jlong pipelinePtr, jobject previewSurface) {
    if (!pipelinePtr) {
        LOGE("nativeSetRawPreviewWindow: null pipeline handle");
        return;
    }

    ANativeWindow* window = nullptr;
    if (previewSurface) {
        window = ANativeWindow_fromSurface(env, previewSurface);
        if (!window) {
            LOGE("nativeSetRawPreviewWindow: ANativeWindow_fromSurface returned null");
            return;
        }
    }

    pipelineFromHandle(pipelinePtr)->setRawPreviewWindow(window);

    if (window) {
        ANativeWindow_release(window);
    }
}

// ---------------------------------------------------------------------------
// nativeDeliverYuv
//
// Copies one YUV_420_888 frame into the C++ input ring and returns immediately.
// The camera Image may be closed right after this call returns.
//
// @param pipelinePtr      Handle returned by nativeInit.
// @param yBuffer          Direct ByteBuffer for the Y plane.
// @param yRowStride       Row stride of the Y plane in bytes.
// @param uBuffer          Direct ByteBuffer for the U (Cb) plane.
// @param uvRowStride      Row stride of the U/V planes in bytes.
// @param uvPixelStride    Pixel stride of U/V planes (1=I420, 2=NV12/NV21).
//                         Not used by C++; format is determined by yuvFormat.
// @param vBuffer          Direct ByteBuffer for the V (Cr) plane.
// @param width            Frame width in pixels.
// @param height           Frame height in pixels.
// @param frameId          Monotonic frame counter (from streamFrameCount).
// @param iso              Sensor sensitivity from latest capture result (0 if unknown).
// @param exposureTimeNs   Exposure duration in nanoseconds (0 if unknown).
// @param sensorTimestamp  Sensor capture timestamp from Image.getTimestamp().
// @param yuvFormat        YUV layout constant (YUV_FORMAT_NV21/NV12/I420).
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_CameraController_nativeDeliverYuv(
        JNIEnv* env, jclass /*clazz*/,
        jlong pipelinePtr,
        jobject yBuffer, jint yRowStride,
        jobject uBuffer, jint uvRowStride, jint /*uvPixelStride*/,
        jobject vBuffer,
        jint width, jint height,
        jlong frameId,
        jint iso, jlong exposureTimeNs, jlong sensorTimestamp,
        jint yuvFormat) {
    if (!pipelinePtr) {
        LOGE("nativeDeliverYuv: null pipeline handle");
        return;
    }
    if (!yBuffer || !uBuffer || !vBuffer) {
        LOGE("nativeDeliverYuv: one or more plane buffers are null");
        return;
    }

    const auto* yData = reinterpret_cast<const uint8_t*>(env->GetDirectBufferAddress(yBuffer));
    const auto* uData = reinterpret_cast<const uint8_t*>(env->GetDirectBufferAddress(uBuffer));
    const auto* vData = reinterpret_cast<const uint8_t*>(env->GetDirectBufferAddress(vBuffer));

    if (!yData || !uData || !vData) {
        LOGE("nativeDeliverYuv: GetDirectBufferAddress returned null — "
             "ensure all plane buffers are direct ByteBuffers");
        return;
    }

    cam::FrameMetadata meta;
    meta.frameNumber       = static_cast<int64_t>(frameId);
    meta.sensorTimestampNs = static_cast<int64_t>(sensorTimestamp);
    meta.exposureTimeNs    = static_cast<int64_t>(exposureTimeNs);
    meta.iso               = static_cast<int32_t>(iso);

    pipelineFromHandle(pipelinePtr)->deliverYuv(
            yData, static_cast<int>(yRowStride),
            uData, vData,
            static_cast<int>(uvRowStride),
            static_cast<int>(width), static_cast<int>(height),
            static_cast<int>(yuvFormat),
            static_cast<uint64_t>(frameId),
            meta);
}

// ---------------------------------------------------------------------------
// nativeSetProcessingParams
//
// Updates the C++ pipeline's processing parameters fire-and-forget.
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_CameraController_nativeSetProcessingParams(
        JNIEnv* /*env*/, jclass /*clazz*/,
        jlong pipelinePtr,
        jdouble blackR,  jdouble blackG,  jdouble blackB,
        jdouble gamma,
        jdouble histBlackPoint, jdouble histWhitePoint,
        jboolean autoStretch,
        jdouble autoStretchLow, jdouble autoStretchHigh,
        jdouble brightness,
        jdouble saturation) {
    if (!pipelinePtr) {
        LOGE("nativeSetProcessingParams: null pipeline handle");
        return;
    }

    cam::ProcessingParams p;
    p.blackR          = static_cast<float>(blackR);
    p.blackG          = static_cast<float>(blackG);
    p.blackB          = static_cast<float>(blackB);
    p.gamma           = static_cast<float>(gamma);
    p.histBlackPoint  = static_cast<float>(histBlackPoint);
    p.histWhitePoint  = static_cast<float>(histWhitePoint);
    p.autoStretch     = static_cast<bool>(autoStretch);
    p.autoStretchLow  = static_cast<float>(autoStretchLow);
    p.autoStretchHigh = static_cast<float>(autoStretchHigh);
    p.brightness      = static_cast<float>(brightness);
    p.saturation      = static_cast<float>(saturation);

    pipelineFromHandle(pipelinePtr)->setParams(p);
}

} // extern "C"
