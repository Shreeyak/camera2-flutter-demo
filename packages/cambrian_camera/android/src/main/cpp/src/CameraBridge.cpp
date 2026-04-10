// JNI glue between Kotlin (CameraController) and the native ImagePipeline
// and GpuRenderer.
//
// Pipeline entry points: nativeInit, nativeRelease.
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
#include <android/native_window_jni.h>
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

struct TestSinkState {
    std::shared_ptr<std::atomic<int>>     counter;
    std::shared_ptr<std::vector<uint8_t>> lastPixels;
    std::shared_ptr<int>                  lastW;
    std::shared_ptr<int>                  lastH;
};

std::mutex                                                     gTestSinkMu;
std::unordered_map<TestSinkKey,
                   TestSinkState,
                   TestSinkKeyHash>                            gTestSinkCounters;

} // namespace

extern "C" {

// ---------------------------------------------------------------------------
// nativeInit
//
// Called once when the Camera2 capture session is configured.  Creates the
// ImagePipeline and returns an opaque pointer (as jlong) that Kotlin stores
// for all subsequent JNI calls.
//
// @return  Non-zero handle on success; 0 on failure.
// ---------------------------------------------------------------------------
JNIEXPORT jlong JNICALL
Java_com_cambrian_camera_CameraController_nativeInit(
        JNIEnv* /*env*/, jclass /*clazz*/) {
    cam::ImagePipeline* pipeline = nullptr;
    try {
        pipeline = new cam::ImagePipeline();
    } catch (...) {
        LOGE("nativeInit: failed to create ImagePipeline");
        return 0;
    }
    LOGD("nativeInit: pipeline created at %p", pipeline);
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
        jint rawW, jint rawH,
        jint debugLevel) {
    auto* renderer = new cam::GpuRenderer(static_cast<int>(width),
                                          static_cast<int>(height),
                                          static_cast<int>(debugLevel));

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
// nativeGpuResize
//
// Resizes GL resources (FBOs, PBOs, textures) to new dimensions while keeping
// the EGL display, context, and surfaces alive. Must be called on the GL thread.
//
// @param gpuHandle  Handle returned by nativeGpuInit.
// @param newW / newH     New stream dimensions.
// @param newRawW / newRawH  New raw stream dimensions; 0 to disable.
// @return JNI_TRUE on success; JNI_FALSE if GL re-init fails.
// ---------------------------------------------------------------------------
JNIEXPORT jboolean JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuResize(
        JNIEnv* /*env*/, jclass /*clazz*/,
        jlong gpuHandle,
        jint newW, jint newH,
        jint newRawW, jint newRawH) {
    if (!gpuHandle) {
        LOGE("nativeGpuResize: null renderer handle");
        return JNI_FALSE;
    }
    cam::GpuRenderer* renderer = rendererFromHandle(gpuHandle);
    const bool ok = renderer->resize(
        static_cast<int>(newW), static_cast<int>(newH),
        static_cast<int>(newRawW), static_cast<int>(newRawH));
    if (!ok) LOGE("nativeGpuResize: resize failed for %dx%d", (int)newW, (int)newH);
    return ok ? JNI_TRUE : JNI_FALSE;
}

// ---------------------------------------------------------------------------
// nativeGpuRebindRawSurface
//
// Replaces the raw preview EGL window surface with one created from newRawSurface.
// Must be called on the GL thread (post to glHandler) after Flutter recreates the
// raw SurfaceProducer surface.
//
// @param gpuHandle      Handle returned by nativeGpuInit.
// @param newRawSurface  New Android Surface for raw preview; may be null to detach.
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuRebindRawSurface(
        JNIEnv* env, jclass /*clazz*/,
        jlong gpuHandle,
        jobject newRawSurface) {
    if (!gpuHandle) {
        LOGE("nativeGpuRebindRawSurface: null renderer handle");
        return;
    }
    cam::GpuRenderer* renderer = rendererFromHandle(gpuHandle);

    ANativeWindow* window = nullptr;
    if (newRawSurface) {
        window = ANativeWindow_fromSurface(env, newRawSurface);
        if (!window) {
            LOGE("nativeGpuRebindRawSurface: ANativeWindow_fromSurface returned null");
            return;
        }
    }
    renderer->rebindRawSurface(window);
    if (window) ANativeWindow_release(window);
}

// ---------------------------------------------------------------------------
// nativeGpuSetEncoderSurface
//
// Attaches or detaches the MediaCodec encoder EGL window surface.
// Must be called on the GL thread (post to glHandler) so that EGL surface
// creation/destruction is serialised with drawAndReadback().
//
// @param gpuHandle     Handle returned by nativeGpuInit.
// @param encoderSurface  New Android Surface wrapping the MediaCodec input; null to detach.
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuSetEncoderSurface(
        JNIEnv* env, jclass /*clazz*/,
        jlong gpuHandle,
        jobject encoderSurface) {
    if (!gpuHandle) {
        LOGE("nativeGpuSetEncoderSurface: null renderer handle");
        return;
    }
    cam::GpuRenderer* renderer = rendererFromHandle(gpuHandle);

    ANativeWindow* window = nullptr;
    if (encoderSurface) {
        window = ANativeWindow_fromSurface(env, encoderSurface);
        if (!window) {
            LOGE("nativeGpuSetEncoderSurface: ANativeWindow_fromSurface returned null");
            return;
        }
    }
    renderer->setEncoderSurface(window);
    if (window) ANativeWindow_release(window);
}

// ---------------------------------------------------------------------------
// nativeGpuRebindPreviewSurface
//
// Replaces the processed preview EGL window surface with one created from
// newPreviewSurface.  Must be called on the GL thread (post to glHandler)
// after Flutter recreates the SurfaceProducer surface.
//
// @param gpuHandle          Handle returned by nativeGpuInit.
// @param newPreviewSurface  New Android Surface for preview; may be null to detach.
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuRebindPreviewSurface(
        JNIEnv* env, jclass /*clazz*/,
        jlong gpuHandle,
        jobject newPreviewSurface) {
    if (!gpuHandle) {
        LOGE("nativeGpuRebindPreviewSurface: null renderer handle");
        return;
    }
    cam::GpuRenderer* renderer = rendererFromHandle(gpuHandle);

    ANativeWindow* window = nullptr;
    if (newPreviewSurface) {
        window = ANativeWindow_fromSurface(env, newPreviewSurface);
        if (!window) {
            LOGE("nativeGpuRebindPreviewSurface: ANativeWindow_fromSurface returned null");
            return;
        }
    }
    renderer->rebindPreviewSurface(window);
    if (window) ANativeWindow_release(window);
}

// ---------------------------------------------------------------------------
// nativeGpuSetAdjustments
//
// Updates the shader uniform values used during rendering.  Thread-safe;
// changes take effect on the next nativeGpuDrawAndReadback() call.
//
// @param gpuHandle   Handle returned by nativeGpuInit.
// @param brightness  Additive brightness offset [-1, 1]; 0 = identity.
// @param contrast    Contrast adjustment [-1, 1]; 0 = identity (shader applies uContrast + 1.0).
// @param saturation  Saturation adjustment [-1, 1]; 0 = identity (shader applies uSaturation + 1.0).
// @param blackR      Per-channel black-level subtraction for red [0, 0.5].
// @param blackG      Per-channel black-level subtraction for green [0, 0.5].
// @param blackB      Per-channel black-level subtraction for blue [0, 0.5].
// @param gamma       Gamma correction exponent [0.1, 4.0]; 1.0 = identity (shader applies 1/gamma).
// ---------------------------------------------------------------------------
JNIEXPORT void JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuSetAdjustments(
        JNIEnv* /*env*/, jclass /*clazz*/,
        jlong gpuHandle,
        jdouble brightness, jdouble contrast, jdouble saturation,
        jdouble blackR, jdouble blackG, jdouble blackB, jdouble gamma) {
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
            static_cast<float>(blackB),
            static_cast<float>(gamma));
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
        jint iso,
        jint displayRotation) {
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
    meta.displayRotation   = static_cast<int32_t>(displayRotation);

    jfloat* texMatrixPtr = env->GetFloatArrayElements(texMatrix, nullptr);
    if (!texMatrixPtr) {
        LOGE("nativeGpuDrawAndReadback: GetFloatArrayElements returned NULL");
        return;
    }

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
// GpuPipelineTestBridge.nativeAddDeliveryCountSink / nativeGetDeliveryCount /
// nativeGetLastDeliveredRgba
//
// Registers a sink on an ImagePipeline that increments a counter and copies
// the last delivered frame bytes each time a frame is delivered.  State is
// stored in a process-wide map keyed by (pipelinePtr, sinkName) so that the
// Kotlin test can retrieve it after one or more drawAndReadback calls.
//
// These helpers exist solely to support instrumented tests and add no
// overhead to the production code paths.
// ---------------------------------------------------------------------------

// nativeAddDeliveryCountSink
//
// Registers a sink named `sinkName` with the given `role` on the pipeline at
// `pipelinePtr`.  Each frame delivery copies the pixel data and increments the
// counter retrievable by nativeGetDeliveryCount.
//
// @param pipelinePtr  Handle returned by nativeInit.
// @param sinkName     Unique name for the test sink.
// @param role         SinkRole integer value (0=FULL_RES, 1=TRACKER, 2=RAW).
JNIEXPORT void JNICALL
Java_com_cambrian_camera_GpuPipelineTestBridge_nativeAddDeliveryCountSink(
        JNIEnv* env, jclass /*clazz*/,
        jlong pipelinePtr, jstring sinkName, jint role) {
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

    // Create state and store it in the global map.
    auto state = TestSinkState{
        std::make_shared<std::atomic<int>>(0),
        std::make_shared<std::vector<uint8_t>>(),
        std::make_shared<int>(0),
        std::make_shared<int>(0)
    };
    {
        std::lock_guard<std::mutex> lk(gTestSinkMu);
        gTestSinkCounters[{pipeline, name}] = state;
    }

    // Register sink — lambda captures state by value so it outlives the
    // callback registration.  Counter is incremented last so that a reader
    // observing counter > 0 is guaranteed to see consistent pixel data.
    // (Test helper: delivery and read are ordered by the polling loop.)
    cam::SinkConfig cfg;
    cfg.name = name;
    cfg.role = static_cast<cam::SinkRole>(role);
    pipeline->addSink(cfg, [state](const cam::SinkFrame& f) {
        const size_t bytes = static_cast<size_t>(f.stride) * f.height;
        {
            std::lock_guard<std::mutex> lk(gTestSinkMu);
            *state.lastPixels = std::vector<uint8_t>(f.data, f.data + bytes);
            *state.lastW = f.width;
            *state.lastH = f.height;
        }
        // Release ordering so readers that acquire-load counter > 0 are
        // guaranteed to see the pixel data written above.
        state.counter->fetch_add(1, std::memory_order_release);
    });

    LOGD("nativeAddDeliveryCountSink: registered sink '%s' role=%d on pipeline %p",
         name.c_str(), static_cast<int>(role), pipeline);
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
    return static_cast<jint>(it->second.counter->load(std::memory_order_acquire));
}

// nativeGetLastDeliveredRgba
//
// Returns the RGBA pixel bytes from the last frame delivered to the named test
// sink, or null if the sink was never registered or has not yet received a frame.
//
// @param pipelinePtr  Handle returned by nativeInit.
// @param sinkName     Name passed to nativeAddDeliveryCountSink.
JNIEXPORT jbyteArray JNICALL
Java_com_cambrian_camera_GpuPipelineTestBridge_nativeGetLastDeliveredRgba(
        JNIEnv* env, jclass /*clazz*/,
        jlong pipelinePtr, jstring sinkName) {
    if (!pipelinePtr) {
        LOGE("nativeGetLastDeliveredRgba: null pipeline handle");
        return nullptr;
    }
    const char* nameChars = env->GetStringUTFChars(sinkName, nullptr);
    if (!nameChars) {
        LOGE("nativeGetLastDeliveredRgba: failed to get sink name string");
        return nullptr;
    }
    std::string name(nameChars);
    env->ReleaseStringUTFChars(sinkName, nameChars);

    cam::ImagePipeline* pipeline = pipelineFromHandle(pipelinePtr);

    // Deep-copy pixel data under the mutex so we don't race with the sink
    // lambda that writes *lastPixels while also holding gTestSinkMu.
    std::vector<uint8_t> pixelsCopy;
    {
        std::lock_guard<std::mutex> lk(gTestSinkMu);
        auto it = gTestSinkCounters.find({pipeline, name});
        if (it == gTestSinkCounters.end()) {
            LOGE("nativeGetLastDeliveredRgba: no state for sink '%s' on pipeline %p",
                 name.c_str(), pipeline);
            return nullptr;
        }
        const auto& px = it->second.lastPixels;
        if (!px || px->empty()) {
            return nullptr;
        }
        pixelsCopy = *px;
    }

    jbyteArray result = env->NewByteArray(static_cast<jsize>(pixelsCopy.size()));
    if (!result) {
        LOGE("nativeGetLastDeliveredRgba: NewByteArray failed");
        return nullptr;
    }
    env->SetByteArrayRegion(result, 0, static_cast<jsize>(pixelsCopy.size()),
                            reinterpret_cast<const jbyte*>(pixelsCopy.data()));
    return result;
}

// ---------------------------------------------------------------------------
// nativeGpuNeedsPreviewRebind / nativeGpuClearRebindFlag
//
// Polled by GpuPipeline.kt after each frame to detect stale EGL preview surfaces.
// ---------------------------------------------------------------------------

JNIEXPORT jboolean JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuNeedsPreviewRebind(
    JNIEnv*, jclass, jlong gpuHandle
) {
    auto* renderer = reinterpret_cast<cam::GpuRenderer*>(gpuHandle);
    if (!renderer) return JNI_FALSE;
    return renderer->needsPreviewRebind() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGpuClearRebindFlag(
    JNIEnv*, jclass, jlong gpuHandle
) {
    auto* renderer = reinterpret_cast<cam::GpuRenderer*>(gpuHandle);
    if (renderer) renderer->clearRebindFlag();
}

// ---------------------------------------------------------------------------
// nativeGetDimensionMismatchCount
//
// Previously returned the InputRing dimension mismatch counter.
// InputRing has been removed; always returns 0.
// ---------------------------------------------------------------------------

JNIEXPORT jint JNICALL
Java_com_cambrian_camera_GpuPipeline_nativeGetDimensionMismatchCount(
    JNIEnv*, jclass, jlong /*pipelineHandle*/
) {
    return 0;
}

} // extern "C"
