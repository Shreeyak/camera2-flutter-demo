// JNI glue between Kotlin (CameraController) and the native ImagePipeline
// and GpuRenderer.
//
// CPU pipeline entry points: nativeInit, nativeRelease, nativeSetPreviewWindow,
// nativeDeliverYuv, nativeSetProcessingParams.
// GPU pipeline entry points: nativeGpuInit, nativeGpuRelease,
// nativeGpuSetAdjustments, nativeGpuDrawAndReadback.
// Test helper entry points (GpuPipelineTestBridge):
//   nativeAddDeliveryCountSink, nativeGetDeliveryCount.
//
// Each function is a thin wrapper that validates inputs, converts JNI types to
// C++, and delegates to ImagePipeline or GpuRenderer.  No image logic lives here.
//
// JNI naming convention: each function name encodes the fully-qualified Kotlin
// class path: Java_<package_underscored>_<ClassName>_<methodName>.

#include "GpuRenderer.h"
#include "ImagePipeline.h"

#include <GLES3/gl3.h>
#include <android/log.h>
#include <android/native_window_jni.h> // ANativeWindow_fromSurface
#include <jni.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#define TAG  "CambrianCamera"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// ---------------------------------------------------------------------------
// Helper to cast the opaque jlong handle back to an ImagePipeline pointer.
// ---------------------------------------------------------------------------
static cam::ImagePipeline* pipelineFromHandle(jlong handle) {
    return reinterpret_cast<cam::ImagePipeline*>(static_cast<uintptr_t>(handle));
}

// ---------------------------------------------------------------------------
// Helper to cast the opaque jlong handle back to a GpuRenderer pointer.
// ---------------------------------------------------------------------------
static cam::GpuRenderer* rendererFromHandle(jlong handle) {
    return reinterpret_cast<cam::GpuRenderer*>(static_cast<uintptr_t>(handle));
}

// ---------------------------------------------------------------------------
// Test-helper state: delivery-count sinks
//
// Process-wide map keyed by (ImagePipeline*, sinkName) → shared counter.
// Used by nativeAddDeliveryCountSink / nativeGetDeliveryCount (GpuPipelineTestBridge).
// ---------------------------------------------------------------------------

namespace {

struct TestSinkKey {
    cam::ImagePipeline* pipeline;
    std::string         name;

    bool operator==(const TestSinkKey& o) const {
        return pipeline == o.pipeline && name == o.name;
    }
};

struct TestSinkKeyHash {
    std::size_t operator()(const TestSinkKey& k) const noexcept {
        std::size_t h1 = std::hash<void*>{}(k.pipeline);
        std::size_t h2 = std::hash<std::string>{}(k.name);
        return h1 ^ (h2 << 1);
    }
};

std::mutex                                                     gTestSinkMu;
std::unordered_map<TestSinkKey,
                   std::shared_ptr<std::atomic<int>>,
                   TestSinkKeyHash>                            gTestSinkCounters;

} // namespace

extern "C" {

// ---------------------------------------------------------------------------
// nativeInit
//
// Called once when the Camera2 capture session is configured.  Creates the
// pipeline, pre-allocates the InputRing for the given stream dimensions, and
// returns an opaque pointer (as jlong) that Kotlin stores for all subsequent
// JNI calls.
//
// @param previewSurface  Android Surface backing the Flutter preview widget,
//                        or null when the GPU pipeline owns its own preview
//                        surface via EGL (GpuRenderer).
// @param width           Stream width in pixels.
// @param height          Stream height in pixels.
// @return  Non-zero handle on success; 0 on failure.
// ---------------------------------------------------------------------------
JNIEXPORT jlong JNICALL
Java_com_cambrian_camera_CameraController_nativeInit(
        JNIEnv* env, jclass /*clazz*/,
        jobject previewSurface,
        jint width, jint height) {
    ANativeWindow* window = nullptr;
    if (previewSurface) {
        window = ANativeWindow_fromSurface(env, previewSurface);
        if (!window) {
            LOGE("nativeInit: ANativeWindow_fromSurface returned null");
            return 0;
        }
    }

    cam::ImagePipeline* pipeline;
    try {
        pipeline = new cam::ImagePipeline(window,
                                          static_cast<int>(width),
                                          static_cast<int>(height));
    } catch (const std::exception& e) {
        LOGE("nativeInit: ImagePipeline construction failed: %s", e.what());
        if (window) ANativeWindow_release(window);
        return 0;
    } catch (...) {
        LOGE("nativeInit: ImagePipeline construction failed with unknown exception");
        if (window) ANativeWindow_release(window);
        return 0;
    }

    // ImagePipeline acquires its own reference; release the one from fromSurface.
    if (window) ANativeWindow_release(window);

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
    cam::ImagePipeline* pipeline = pipelineFromHandle(pipelinePtr);
    {
        std::lock_guard<std::mutex> lk(gTestSinkMu);
        auto it = gTestSinkCounters.begin();
        while (it != gTestSinkCounters.end()) {
            if (it->first.pipeline == pipeline) {
                it = gTestSinkCounters.erase(it);
            } else {
                ++it;
            }
        }
    }
    delete pipeline;
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

// ---------------------------------------------------------------------------
// nativeGpuInit
//
// Creates a GpuRenderer for the GPU pipeline and initializes its EGL context,
// shaders, FBOs, and PBOs.  Must be called on the GL thread before any other
// GPU JNI functions.
//
// @param previewSurface      Android Surface for processed preview output; may be null.
// @param width               Stream width in pixels.
// @param height              Stream height in pixels.
// @param rawPreviewSurface   Android Surface for raw preview output; may be null.
// @param rawW                Raw stream width; 0 to disable raw path.
// @param rawH                Raw stream height; 0 to disable raw path.
// @return  Non-zero GpuRenderer handle on success; 0 on failure.
// ---------------------------------------------------------------------------
JNIEXPORT jlong JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuInit(
        JNIEnv* env, jclass /*clazz*/,
        jobject previewSurface,
        jint width, jint height,
        jobject rawPreviewSurface,
        jint rawW, jint rawH) {
    auto* renderer = new cam::GpuRenderer(static_cast<int>(width),
                                          static_cast<int>(height));

    ANativeWindow* nativeWindow = nullptr;
    if (previewSurface) {
        nativeWindow = ANativeWindow_fromSurface(env, previewSurface);
        if (!nativeWindow) {
            LOGE("nativeGpuInit: ANativeWindow_fromSurface returned null");
            delete renderer;
            return 0;
        }
    }

    ANativeWindow* rawNativeWindow = nullptr;
    if (rawPreviewSurface) {
        rawNativeWindow = ANativeWindow_fromSurface(env, rawPreviewSurface);
        if (!rawNativeWindow) {
            LOGE("nativeGpuInit: ANativeWindow_fromSurface for raw preview returned null — "
                 "continuing without raw preview window");
            // Non-fatal: raw path continues without preview blit
        }
    }

    const bool ok = renderer->init(nativeWindow,
                                   rawNativeWindow,
                                   static_cast<int>(rawW),
                                   static_cast<int>(rawH));

    // GpuRenderer acquires its own EGL references; release the JNI-owned refs.
    if (nativeWindow)    ANativeWindow_release(nativeWindow);
    if (rawNativeWindow) ANativeWindow_release(rawNativeWindow);

    if (!ok) {
        LOGE("nativeGpuInit: GpuRenderer::init failed");
        delete renderer;
        return 0;
    }

    LOGD("nativeGpuInit: renderer created at %p dims=%dx%d raw=%dx%d", renderer,
         static_cast<int>(width), static_cast<int>(height),
         static_cast<int>(rawW),  static_cast<int>(rawH));
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(renderer));
}

// ---------------------------------------------------------------------------
// nativeGpuRelease
//
// Releases all GL/EGL resources held by the GpuRenderer and deletes it.
// Must be called on the GL thread.
//
// @param gpuHandle  Handle returned by nativeGpuInit.
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuRelease(
        JNIEnv* /*env*/, jclass /*clazz*/,
        jlong gpuHandle) {
    if (!gpuHandle) {
        LOGE("nativeGpuRelease: null renderer handle — already released?");
        return;
    }

    LOGD("nativeGpuRelease: deleting renderer at handle %lld",
         static_cast<long long>(gpuHandle));
    cam::GpuRenderer* renderer = rendererFromHandle(gpuHandle);
    renderer->release();
    delete renderer;
}

// ---------------------------------------------------------------------------
// nativeGpuSetAdjustments
//
// Updates the shader uniform values used during rendering.  Thread-safe;
// changes take effect on the next nativeGpuDrawAndReadback() call.
//
// @param gpuHandle   Handle returned by nativeGpuInit.
// @param brightness  Additive brightness offset [-1, 1]; 0 = identity.
// @param contrast    Contrast multiplier [0, ∞]; 1 = identity.
// @param saturation  Saturation multiplier [0, 3]; 1 = identity.
// @param blackR      Per-channel black-level subtraction for red [0, 0.5].
// @param blackG      Per-channel black-level subtraction for green [0, 0.5].
// @param blackB      Per-channel black-level subtraction for blue [0, 0.5].
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuSetAdjustments(
        JNIEnv* /*env*/, jclass /*clazz*/,
        jlong gpuHandle,
        jdouble brightness, jdouble contrast, jdouble saturation,
        jdouble blackR, jdouble blackG, jdouble blackB) {
    if (!gpuHandle) {
        LOGE("nativeGpuSetAdjustments: null renderer handle");
        return;
    }

    rendererFromHandle(gpuHandle)->setAdjustments(
            static_cast<float>(brightness),
            static_cast<float>(contrast),
            static_cast<float>(saturation),
            static_cast<float>(blackR),
            static_cast<float>(blackG),
            static_cast<float>(blackB));
}

// ---------------------------------------------------------------------------
// nativeGpuDrawAndReadback
//
// Called every frame on the GL thread.  Renders one frame from the OES texture
// through the shader, blits to the preview surface, and delivers RGBA readback
// data to the ImagePipeline sinks (full-res, tracker, and raw).
//
// @param gpuHandle          Handle returned by nativeGpuInit.
// @param pipelinePtr        Handle returned by nativeInit (ImagePipeline).
// @param oesTexture         GL_TEXTURE_EXTERNAL_OES name from SurfaceTexture.
// @param texMatrix          16-element float array from
//                           SurfaceTexture.getTransformMatrix().
// @param frameId            Monotonic frame counter.
// @param sensorTimestampNs  Sensor capture timestamp in nanoseconds.
// @param exposureTimeNs     Exposure duration in nanoseconds.
// @param iso                Sensor sensitivity (ISO value).
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuDrawAndReadback(
        JNIEnv* env, jclass /*clazz*/,
        jlong gpuHandle,
        jlong pipelinePtr,
        jint oesTexture,
        jfloatArray texMatrix,
        jlong frameId,
        jlong sensorTimestampNs,
        jlong exposureTimeNs,
        jint iso) {
    if (!gpuHandle) {
        LOGE("nativeGpuDrawAndReadback: null renderer handle");
        return;
    }
    if (!pipelinePtr) {
        LOGE("nativeGpuDrawAndReadback: null pipeline handle");
        return;
    }
    if (!texMatrix) {
        LOGE("nativeGpuDrawAndReadback: texMatrix is null");
        return;
    }

    cam::GpuRenderer*   renderer = rendererFromHandle(gpuHandle);
    cam::ImagePipeline* pipeline = pipelineFromHandle(pipelinePtr);

    cam::FrameMetadata meta;
    meta.frameNumber       = static_cast<int64_t>(frameId);
    meta.sensorTimestampNs = static_cast<int64_t>(sensorTimestampNs);
    meta.exposureTimeNs    = static_cast<int64_t>(exposureTimeNs);
    meta.iso               = static_cast<int32_t>(iso);

    jfloat* texMatrixPtr = env->GetFloatArrayElements(texMatrix, nullptr);

    renderer->drawAndReadback(
            static_cast<GLuint>(oesTexture),
            texMatrixPtr,
            static_cast<uint64_t>(frameId),
            meta,
            [pipeline](const uint8_t* d, int w, int h, int s,
                       uint64_t fId, const cam::FrameMetadata& m) {
                pipeline->deliverFullResRgba(d, w, h, s, fId, m);
            },
            [pipeline](const uint8_t* d, int w, int h, int s,
                       uint64_t fId, const cam::FrameMetadata& m) {
                pipeline->deliverTrackerRgba(d, w, h, s, fId, m);
            },
            [pipeline](const uint8_t* d, int w, int h, int s,
                       uint64_t fId, const cam::FrameMetadata& m) {
                pipeline->deliverRawRgba(d, w, h, s, fId, m);
            });

    env->ReleaseFloatArrayElements(texMatrix, texMatrixPtr, JNI_ABORT);
}

// ---------------------------------------------------------------------------
// Test helper: delivery-count sink
//
// GpuPipelineTestBridge.nativeAddDeliveryCountSink / nativeGetDeliveryCount
//
// Registers a lightweight FULL_RES sink on an ImagePipeline that simply
// increments a counter each time a frame is delivered.  The counter is stored
// in a process-wide map keyed by (pipelinePtr, sinkName) so that the Kotlin
// test can retrieve it after one or more drawAndReadback calls.
//
// These helpers exist solely to support instrumented tests and add no
// overhead to the production code paths.
// ---------------------------------------------------------------------------

// nativeAddDeliveryCountSink
//
// Registers a FULL_RES sink named `sinkName` on the pipeline at `pipelinePtr`.
// Each frame delivery increments the counter retrievable by nativeGetDeliveryCount.
//
// @param pipelinePtr  Handle returned by nativeInit.
// @param sinkName     Unique name for the test sink.
JNIEXPORT void JNICALL
Java_com_cambrian_camera_GpuPipelineTestBridge_nativeAddDeliveryCountSink(
        JNIEnv* env, jclass /*clazz*/,
        jlong pipelinePtr, jstring sinkName) {
    if (!pipelinePtr) {
        LOGE("nativeAddDeliveryCountSink: null pipeline handle");
        return;
    }
    const char* nameChars = env->GetStringUTFChars(sinkName, nullptr);
    if (!nameChars) {
        LOGE("nativeAddDeliveryCountSink: failed to get sink name string");
        return;
    }
    std::string name(nameChars);
    env->ReleaseStringUTFChars(sinkName, nameChars);

    cam::ImagePipeline* pipeline = pipelineFromHandle(pipelinePtr);

    // Create the counter and store it in the global map.
    auto counter = std::make_shared<std::atomic<int>>(0);
    {
        std::lock_guard<std::mutex> lk(gTestSinkMu);
        gTestSinkCounters[{pipeline, name}] = counter;
    }

    // Register sink — lambda captures the shared_ptr by value so the counter
    // outlives the callback registration.
    cam::SinkConfig cfg;
    cfg.name = name;
    cfg.role = cam::SinkRole::FULL_RES;
    pipeline->addSink(cfg, [counter](const cam::SinkFrame& /*frame*/) {
        counter->fetch_add(1, std::memory_order_relaxed);
    });

    LOGD("nativeAddDeliveryCountSink: registered sink '%s' on pipeline %p",
         name.c_str(), pipeline);
}

// nativeGetDeliveryCount
//
// Returns the number of frames delivered to the named test sink, or -1 if the
// sink was never registered.
//
// @param pipelinePtr  Handle returned by nativeInit.
// @param sinkName     Name passed to nativeAddDeliveryCountSink.
JNIEXPORT jint JNICALL
Java_com_cambrian_camera_GpuPipelineTestBridge_nativeGetDeliveryCount(
        JNIEnv* env, jclass /*clazz*/,
        jlong pipelinePtr, jstring sinkName) {
    if (!pipelinePtr) {
        LOGE("nativeGetDeliveryCount: null pipeline handle");
        return -1;
    }
    const char* nameChars = env->GetStringUTFChars(sinkName, nullptr);
    if (!nameChars) {
        LOGE("nativeGetDeliveryCount: failed to get sink name string");
        return -1;
    }
    std::string name(nameChars);
    env->ReleaseStringUTFChars(sinkName, nameChars);

    cam::ImagePipeline* pipeline = pipelineFromHandle(pipelinePtr);

    std::lock_guard<std::mutex> lk(gTestSinkMu);
    auto it = gTestSinkCounters.find({pipeline, name});
    if (it == gTestSinkCounters.end()) {
        LOGE("nativeGetDeliveryCount: no counter for sink '%s' on pipeline %p",
             name.c_str(), pipeline);
        return -1;
    }
    return static_cast<jint>(it->second->load(std::memory_order_relaxed));
}

} // extern "C"
