package com.cambrian.camera

import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.util.concurrent.CountDownLatch

/**
 * Manages the OpenGL ES render thread for the GPU camera pipeline.
 *
 * Owns a [HandlerThread] with a [SurfaceTexture] (OES texture source from Camera2).
 * Each [SurfaceTexture.OnFrameAvailableListener] callback triggers a render + PBO
 * readback via [nativeGpuDrawAndReadback], which delivers RGBA frames to the
 * C++ ImagePipeline sinks.
 *
 * Lifecycle: call [start] after construction, [stop] when done.
 * The preview [Surface] (from Flutter SurfaceProducer) may be null for headless use.
 */
open class GpuPipeline(
    private val width: Int,
    private val height: Int,
    private val previewSurface: Surface?,
    private val pipelineHandle: Long   // ImagePipeline* handle from nativeInit
) {
    private val glThread = HandlerThread("GpuPipeline-GL").also { it.start() }
    private val glHandler = Handler(glThread.looper)

    @Volatile private var gpuHandle: Long = 0L
    private var surfaceTexture: SurfaceTexture? = null
    private var oesTexName: Int = 0
    private val texMatrix = FloatArray(16)

    /** The [Surface] wrapping our [SurfaceTexture] — set as camera capture target. */
    var cameraSurface: Surface? = null
        private set

    /** Tracker output height (fixed at 480p). */
    val trackerHeight: Int get() = 480

    /** Tracker output width that preserves the camera aspect ratio (even pixels). */
    val trackerWidth: Int get() = ((width.toLong() * 480 / height).toInt() + 1) and 1.inv()

    /**
     * Initialize GL resources and create the SurfaceTexture on the GL thread.
     * Blocks until initialization is complete.
     */
    fun start() {
        val latch = CountDownLatch(1)
        glHandler.post {
            // 1. Initialize GpuRenderer (creates EGL context, FBOs, PBOs, shader).
            gpuHandle = nativeGpuInit(previewSurface, width, height)
            if (gpuHandle == 0L) {
                Log.e(TAG, "nativeGpuInit failed")
                latch.countDown()
                return@post
            }

            // 2. Generate an OES texture name in the now-active GL context.
            val texNames = IntArray(1)
            GLES30.glGenTextures(1, texNames, 0)
            oesTexName = texNames[0]
            GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexName)
            GLES30.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES30.GL_TEXTURE_MIN_FILTER,
                GLES30.GL_LINEAR
            )
            GLES30.glTexParameteri(
                GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                GLES30.GL_TEXTURE_MAG_FILTER,
                GLES30.GL_LINEAR
            )
            GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, 0)

            // 3. Create SurfaceTexture on the GL thread with the generated texture name.
            surfaceTexture = SurfaceTexture(oesTexName).also { st ->
                st.setDefaultBufferSize(width, height)
                st.setOnFrameAvailableListener({ onFrameAvailable(it) }, glHandler)
                cameraSurface = Surface(st)
            }
            latch.countDown()
        }
        latch.await()
    }

    /**
     * Release all GL resources and stop the render thread.
     */
    open fun stop() {
        glHandler.post {
            cameraSurface?.release()
            cameraSurface = null
            surfaceTexture?.release()
            surfaceTexture = null
            if (gpuHandle != 0L) {
                nativeGpuRelease(gpuHandle)
                gpuHandle = 0L
            }
        }
        glThread.quitSafely()
        glThread.join()
    }

    /**
     * Update shader adjustment uniforms. Thread-safe; takes effect on next frame.
     */
    open fun setAdjustments(
        brightness: Double,
        contrast: Double,
        saturation: Double,
        blackR: Double,
        blackG: Double,
        blackB: Double
    ) {
        if (gpuHandle != 0L) {
            nativeGpuSetAdjustments(
                gpuHandle, brightness, contrast, saturation,
                blackR, blackG, blackB
            )
        }
    }

    // Called on glHandler thread when SurfaceTexture has a new frame.
    private fun onFrameAvailable(st: SurfaceTexture) {
        val handle = gpuHandle
        if (handle == 0L) return

        st.updateTexImage()
        st.getTransformMatrix(texMatrix)

        // SurfaceTexture.getTimestamp() returns the frame's sensor timestamp in ns.
        val sensorTimestampNs = st.timestamp

        nativeGpuDrawAndReadback(
            handle, pipelineHandle,
            oesTexName,
            texMatrix,
            /* frameId = */ sensorTimestampNs,   // monotonic; used as frame ID
            sensorTimestampNs,
            /* exposureTimeNs = */ 0L,
            /* iso = */ 0
        )
    }

    companion object {
        private const val TAG = "GpuPipeline"

        init {
            try {
                System.loadLibrary("cambrian_camera")
            } catch (_: UnsatisfiedLinkError) {
                // Library not available in JVM unit tests; JNI calls will throw at runtime
                // if invoked without the native library loaded.
            }
        }

        @JvmStatic
        external fun nativeGpuInit(previewSurface: Surface?, width: Int, height: Int): Long

        @JvmStatic
        external fun nativeGpuRelease(gpuHandle: Long)

        @JvmStatic
        external fun nativeGpuSetAdjustments(
            gpuHandle: Long,
            brightness: Double,
            contrast: Double,
            saturation: Double,
            blackR: Double,
            blackG: Double,
            blackB: Double
        )

        @JvmStatic
        external fun nativeGpuDrawAndReadback(
            gpuHandle: Long,
            pipelineHandle: Long,
            oesTexture: Int,
            texMatrix: FloatArray,
            frameId: Long,
            sensorTimestampNs: Long,
            exposureTimeNs: Long,
            iso: Int
        )
    }
}
