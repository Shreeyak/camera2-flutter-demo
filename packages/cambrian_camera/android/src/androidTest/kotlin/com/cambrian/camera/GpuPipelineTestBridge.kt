package com.cambrian.camera

/**
 * Thin JNI bridge exposing test-only helpers from CameraBridge.cpp.
 *
 * These entry points are not shipped in the production library — they are only
 * compiled into the native .so that backs instrumented test APKs.  The same
 * shared library is used for both app and androidTest (AGP packages it into the
 * test APK), so the symbols are always present at test runtime.
 */
object GpuPipelineTestBridge {

    init {
        // The test also calls CameraController.nativeInit / GpuPipeline.nativeGpuInit,
        // both of which load the library.  This redundant load is a no-op once the
        // library is already present, but keeps the bridge self-contained.
        try {
            System.loadLibrary("cambrian_camera")
        } catch (_: UnsatisfiedLinkError) {
            // Not available in JVM unit tests.
        }
    }

    /**
     * Register a FULL_RES delivery-count sink named [sinkName] on the pipeline
     * identified by [pipelineHandle].  Each frame delivered to the sink
     * increments an internal counter readable via [nativeGetDeliveryCount].
     *
     * @param pipelineHandle Handle returned by [CameraController.nativeInit].
     * @param sinkName       Unique name for this test sink.
     */
    @JvmStatic
    external fun nativeAddDeliveryCountSink(pipelineHandle: Long, sinkName: String)

    /**
     * Return the number of full-res frames delivered to the named sink, or -1
     * if [nativeAddDeliveryCountSink] was never called with that name.
     *
     * @param pipelineHandle Handle returned by [CameraController.nativeInit].
     * @param sinkName       Name passed to [nativeAddDeliveryCountSink].
     */
    @JvmStatic
    external fun nativeGetDeliveryCount(pipelineHandle: Long, sinkName: String): Int
}
