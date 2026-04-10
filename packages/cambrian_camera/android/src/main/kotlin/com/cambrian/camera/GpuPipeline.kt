package com.cambrian.camera

import android.content.Context
import android.graphics.SurfaceTexture
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.opengl.Matrix
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import android.view.WindowManager
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
    private var width: Int,
    private var height: Int,
    private val previewSurface: Surface?,
    private val rawPreviewSurface: Surface?,
    private val rawW: Int,
    private val rawH: Int,
    private val context: Context,
    private val pipelineHandle: Long   // ImagePipeline* handle from nativeInit
) {
    private val glThread = HandlerThread("GpuPipeline-GL").also { it.start() }
    private val glHandler = Handler(glThread.looper)

    @Volatile private var gpuHandle: Long = 0L
    private var surfaceTexture: SurfaceTexture? = null
    private var oesTexName: Int = 0
    private val texMatrix      = FloatArray(16)
    private val combinedMatrix = FloatArray(16)

    // Fixed 90° CW UV rotation applied every frame to normalise output to landscape-right.
    //
    // Camera2 JPEG formula: (sensorOrientation + targetDeviceOrientation + 360) % 360
    // For PRIVATE/SurfaceTexture surfaces the camera HAL auto-applies sensorOrientation,
    // so getTransformMatrix() already delivers portrait-correct pixels. The remaining
    // correction is always portrait→landscape-right = 90° CW, independent of device.
    //
    // UV 90° CW: u' = v,  v' = 1 - u
    // Column-major homogeneous form (OpenGL convention).
    private val rotMatrix90CW = floatArrayOf(
         0f, -1f, 0f, 0f,   // col 0
         1f,  0f, 0f, 0f,   // col 1
         0f,  0f, 1f, 0f,   // col 2
         0f,  1f, 0f, 1f    // col 3
    )

    private var lastFrameTimeMs = 0L
    private var frameCount = 0L
    private var stalled = false
    var onStallDetected: ((elapsedMs: Long) -> Unit)? = null

    /** Invoked on the GL thread when consecutive eglSwapBuffers failures indicate a stale surface. */
    var onPreviewRebindNeeded: (() -> Unit)? = null

    /** The [Surface] wrapping our [SurfaceTexture] — set as camera capture target. */
    var cameraSurface: Surface? = null
        private set

    /** True if the GPU renderer is initialized and ready to process frames. */
    val isRunning: Boolean get() = gpuHandle != 0L

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
            Log.i(TAG, "Initializing GpuPipeline: ${width}x${height}, raw: ${rawW}x${rawH}")
            gpuHandle = nativeGpuInit(previewSurface, width, height, rawPreviewSurface, rawW, rawH, computeDebugLevel())
            if (gpuHandle == 0L) {
                Log.e(TAG, "nativeGpuInit failed")
                latch.countDown()
                return@post
            }
            Log.i(TAG, "GpuPipeline initialized successfully")

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
        scheduleStallCheck()
    }

    /**
     * Release all GL resources and stop the render thread.
     */
    open fun stop() {
        Log.i(TAG, "stop (frame #$frameCount)")
        glHandler.removeCallbacksAndMessages(null)
        glHandler.post {
            cameraSurface?.release()
            cameraSurface = null
            surfaceTexture?.release()
            surfaceTexture = null
            if (oesTexName != 0) {
                GLES30.glDeleteTextures(1, intArrayOf(oesTexName), 0)
                oesTexName = 0
            }
            if (gpuHandle != 0L) {
                nativeGpuRelease(gpuHandle)
                gpuHandle = 0L
            }
        }
        glThread.quitSafely()
        glThread.join()
    }

    /**
     * Resize GL resources (FBOs, PBOs, textures) to new dimensions while keeping
     * the EGL context, SurfaceTexture, and cameraSurface alive.
     *
     * Posts to the GL thread and blocks until complete.
     * Must NOT be called while the pipeline is stopped.
     *
     * @return true if the native resize succeeded; false if GL re-init failed.
     */
    fun resize(newW: Int, newH: Int, newRawW: Int, newRawH: Int): Boolean {
        val handle = gpuHandle
        if (handle == 0L) {
            Log.e(TAG, "resize: no active gpuHandle")
            return false
        }
        var ok = false
        val latch = CountDownLatch(1)
        glHandler.post {
            try {
                // Update SurfaceTexture buffer dimensions before GL resources so the buffer
                // queue starts allocating new-sized buffers immediately.
                surfaceTexture?.setDefaultBufferSize(newW, newH)
                ok = nativeGpuResize(handle, newW, newH, newRawW, newRawH)
                if (!ok) Log.e(TAG, "nativeGpuResize failed for ${newW}x${newH}")
            } finally {
                latch.countDown()
            }
        }
        // Timeout guards against indefinite hang if stop() clears the GL handler mid-resize.
        if (!latch.await(5, java.util.concurrent.TimeUnit.SECONDS)) {
            Log.e(TAG, "resize: timed out waiting for GL thread")
            return false
        }
        if (ok) {
            width = newW
            height = newH
        }
        return ok
    }

    /**
     * Attach or detach the MediaCodec encoder surface.
     * Posts to the GL thread so EGL surface creation is serialised with drawAndReadback().
     * Pass null to detach (called when recording stops or the pipeline is torn down).
     */
    fun setEncoderSurface(surface: Surface?) {
        val handle = gpuHandle
        if (handle == 0L) return
        glHandler.post {
            nativeGpuSetEncoderSurface(handle, surface)
        }
    }

    /**
     * Rebind the raw preview EGL surface to a new [Surface] after Flutter recreates it.
     * Posts the native call to the GL thread so EGL state is updated safely.
     */
    fun rebindRawSurface(surface: Surface?) {
        val handle = gpuHandle
        if (handle == 0L) return
        glHandler.post {
            nativeGpuRebindRawSurface(handle, surface)
        }
    }

    /**
     * Rebind the processed preview EGL surface to a new [Surface] after Flutter recreates it.
     * Posts the native call to the GL thread so EGL state is updated safely.
     */
    fun rebindPreviewSurface(surface: Surface?) {
        val handle = gpuHandle
        if (handle == 0L) return
        glHandler.post {
            nativeGpuRebindPreviewSurface(handle, surface)
        }
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
        blackB: Double,
        gamma: Double
    ) {
        val handle = gpuHandle
        if (handle != 0L) {
            nativeGpuSetAdjustments(
                handle, brightness, contrast, saturation,
                blackR, blackG, blackB, gamma
            )
        }
    }

    private fun scheduleStallCheck() {
        glHandler.postDelayed({
            if (gpuHandle == 0L) return@postDelayed
            val elapsed = SystemClock.elapsedRealtime() - lastFrameTimeMs
            if (lastFrameTimeMs > 0 && elapsed >= STALL_THRESHOLD_MS && !stalled) {
                stalled = true
                Log.w(TAG, "frame stall: ${elapsed}ms since last frame (frame #$frameCount)")
                onStallDetected?.invoke(elapsed)
            }
            scheduleStallCheck()
        }, STALL_CHECK_INTERVAL_MS)
    }

    // Called on glHandler thread when SurfaceTexture has a new frame.
    private fun onFrameAvailable(st: SurfaceTexture) {
        val handle = gpuHandle
        if (handle == 0L) return

        val now = SystemClock.elapsedRealtime()
        frameCount++
        if (CambrianCameraConfig.debugDataFlow && frameCount % 100 == 0L) {
            Log.d(TAG, "frame #$frameCount")
        }
        lastFrameTimeMs = now
        stalled = false

        st.updateTexImage()
        st.getTransformMatrix(texMatrix)

        // Compose fixed 90° CW UV rotation so output is always landscape-right,
        // independent of device orientation. combinedMatrix = texMatrix * rotMatrix90CW
        // (rotMatrix90CW is applied first to the UV coords, then texMatrix).
        Matrix.multiplyMM(combinedMatrix, 0, texMatrix, 0, rotMatrix90CW, 0)

        // SurfaceTexture.getTimestamp() returns the frame's sensor timestamp in ns.
        val sensorTimestampNs = st.timestamp

        // Read display rotation for metadata — cheap cached value, does not change per frame.
        @Suppress("DEPRECATION")
        val displayRotDeg = when (
            (context.getSystemService(Context.WINDOW_SERVICE) as WindowManager)
                .defaultDisplay.rotation
        ) {
            Surface.ROTATION_90  ->  90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else                 ->   0
        }

        nativeGpuDrawAndReadback(
            handle, pipelineHandle,
            oesTexName,
            combinedMatrix,
            /* frameId = */ sensorTimestampNs,   // monotonic; used as frame ID
            sensorTimestampNs,
            /* exposureTimeNs = */ 0L,
            /* iso = */ 0,
            displayRotDeg
        )

        // Poll for stale preview surface after each frame (Step 2: auto-rebind).
        if (nativeGpuNeedsPreviewRebind(handle)) {
            Log.w(TAG, "preview surface stale — requesting rebind")
            nativeGpuClearRebindFlag(handle)
            onPreviewRebindNeeded?.invoke()
        }
    }

    companion object {
        private const val TAG = "CC/Gpu"
        private const val STALL_THRESHOLD_MS = 3000L
        private const val STALL_CHECK_INTERVAL_MS = 1000L

        init {
            try {
                System.loadLibrary("cambrian_camera")
            } catch (e: UnsatisfiedLinkError) {
                Log.w("CC/Gpu", "Native library not loaded (expected in JVM unit tests): ${e.message}")
            }
        }

        @JvmStatic
        external fun nativeGpuInit(
            previewSurface: Surface?, width: Int, height: Int,
            rawPreviewSurface: Surface?, rawW: Int, rawH: Int,
            debugLevel: Int
        ): Long

        /**
         * Backward-compatible overload used by instrumentation tests.
         * Delegates to the 7-argument form with [debugLevel] defaulting to 0.
         */
        @JvmStatic
        fun nativeGpuInit(
            previewSurface: Surface?, width: Int, height: Int,
            rawPreviewSurface: Surface?, rawW: Int, rawH: Int
        ): Long = nativeGpuInit(previewSurface, width, height, rawPreviewSurface, rawW, rawH, 0)

        fun computeDebugLevel(): Int = when {
            CambrianCameraConfig.verboseFullResult -> 2
            CambrianCameraConfig.debugDataFlow -> 2
            CambrianCameraConfig.verboseDiagnostics -> 1
            else -> 0
        }

        @JvmStatic
        external fun nativeGpuRelease(gpuHandle: Long)

        @JvmStatic
        external fun nativeGpuResize(gpuHandle: Long, newW: Int, newH: Int, newRawW: Int, newRawH: Int): Boolean

        @JvmStatic
        external fun nativeGpuSetEncoderSurface(gpuHandle: Long, encoderSurface: Surface?)

        @JvmStatic
        external fun nativeGpuRebindRawSurface(gpuHandle: Long, newRawSurface: Surface?)

        @JvmStatic
        external fun nativeGpuRebindPreviewSurface(gpuHandle: Long, newPreviewSurface: Surface?)

        @JvmStatic
        external fun nativeGpuNeedsPreviewRebind(gpuHandle: Long): Boolean

        @JvmStatic
        external fun nativeGpuClearRebindFlag(gpuHandle: Long)

        @JvmStatic
        external fun nativeGetDimensionMismatchCount(pipelineHandle: Long): Int

        @JvmStatic
        external fun nativeGpuSetAdjustments(
            gpuHandle: Long,
            brightness: Double,
            contrast: Double,
            saturation: Double,
            blackR: Double,
            blackG: Double,
            blackB: Double,
            gamma: Double
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
            iso: Int,
            displayRotation: Int
        )
    }
}
