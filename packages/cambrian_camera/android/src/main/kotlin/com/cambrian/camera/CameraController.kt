// Copyright (c) 2025 Cambrian. All rights reserved.
package com.cambrian.camera

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraAccessException
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureResult
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.hardware.camera2.params.StreamConfigurationMap
import android.media.Image
import android.media.ImageReader
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Range
import android.util.Rational
import android.util.Size
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit

/**
 * Camera2 lifecycle manager for the cambrian_camera plugin.
 *
 * Responsibilities:
 * - Opens a Camera2 device and configures a [CaptureSession] with a YUV_420_888 [ImageReader]
 *   and a JPEG [ImageReader] for still capture.
 * - Streams YUV frames via the SurfaceProducer for display; JNI delivery to C++ is a future step.
 * - Implements an auto-recovery state machine with exponential backoff.
 * - Applies per-request ISP settings via [updateSettings].
 * - Provides [takePicture] to capture a single JPEG frame to the app's cache directory.
 *
 * @param context     Application or activity context (used for camera manager and cache dir).
 * @param surfaceProducer  Flutter texture backing the camera preview.
 * @param flutterApi  Pigeon-generated Flutter API for state/error callbacks to Dart.
 * @param handle      The camera handle (= [TextureRegistry.SurfaceProducer.id]) returned to Dart.
 */
class CameraController(
    private val context: Context,
    private val surfaceProducer: TextureRegistry.SurfaceProducer,
    private val flutterApi: CameraFlutterApi,
    val handle: Long,
) {
    // -------------------------------------------------------------------------
    // JNI bridge
    // -------------------------------------------------------------------------

    companion object {
        init {
            System.loadLibrary("cambrian_camera")
        }

        /**
         * Set to true to log every [updateSettings] call (ISO, exposure, focus, zoom, etc.).
         * Disable before shipping to avoid log spam at 30fps slider rates.
         */
        const val VERBOSE_SETTINGS = true

        /** Set to true for frame-flow and capture-result diagnostics. */
        const val VERBOSE_DIAGNOSTICS = true

        /** Initialises the native pipeline. Returns an opaque pointer used in subsequent calls. */
        @JvmStatic external fun nativeInit(previewSurface: Surface): Long

        /**
         * Delivers one RGBA frame to the native pipeline.
         *
         * @param pipelinePtr Pointer returned by [nativeInit].
         * @param data        Direct [ByteBuffer] containing pixel data.
         * @param width       Frame width in pixels.
         * @param height      Frame height in pixels.
         * @param stride      Row stride in bytes (may be > width * 4 due to padding).
         */
        @JvmStatic external fun nativeDeliverFrame(
            pipelinePtr: Long,
            data: ByteBuffer,
            width: Int,
            height: Int,
            stride: Int,
        )

        /** Releases all resources held by the native pipeline. */
        @JvmStatic external fun nativeRelease(pipelinePtr: Long)

        /**
         * Notifies the native pipeline of a new preview [Surface] (e.g. after a surface
         * recreation event from [TextureRegistry.SurfaceProducer.Callback]).
         */
        @JvmStatic external fun nativeSetPreviewWindow(
            pipelinePtr: Long,
            previewSurface: Surface?,
        )
    }

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------

    /** Internal camera lifecycle state. */
    private enum class State { CLOSED, OPENING, STREAMING, RECOVERING, ERROR }

    @Volatile private var state: State = State.CLOSED

    // -------------------------------------------------------------------------
    // Camera2 resources
    // -------------------------------------------------------------------------

    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    /** Serialises concurrent open/close calls so we never open the device twice. */
    private val openLock = Semaphore(1)

    @Volatile private var cameraDevice: CameraDevice? = null

    @Volatile private var captureSession: CameraCaptureSession? = null

    @Volatile private var imageReader: ImageReader? = null

    @Volatile private var jpegImageReader: ImageReader? = null

    /** Repeating request rebuilt whenever settings change. */
    @Volatile private var repeatingRequest: CaptureRequest? = null

    /** The surface currently targeted by the repeating request. */
    @Volatile private var repeatingTargetSurface: Surface? = null

    /** Opaque pointer to the native pipeline, set after [nativeInit]. */
    @Volatile private var nativePipelinePtr: Long = 0L

    /** Latest preview dimensions configured on [surfaceProducer]. */
    @Volatile private var previewWidth: Int = 0

    @Volatile private var previewHeight: Int = 0

    /** Camera ID resolved in [open]; stored for reconnect retries. */
    @Volatile private var resolvedCameraId: String? = null

    /** Settings to apply at session start; updated by [updateSettings]. */
    @Volatile private var pendingSettings: CamSettings? = null

    /** Frame counter used for periodic diagnostics. */
    @Volatile private var streamFrameCount: Long = 0L

    /** Capture-result counter used for periodic diagnostics. */
    @Volatile private var captureResultCount: Long = 0L

    // -------------------------------------------------------------------------
    // Auto-recovery
    // -------------------------------------------------------------------------

    private var retryCount = 0
    private val maxRetries = 5

    /** Exponential backoff delays indexed by retry count (capped at index 4). */
    private val backoffDelaysMs = longArrayOf(500, 1_000, 2_000, 4_000, 8_000)

    // -------------------------------------------------------------------------
    // Background thread
    // -------------------------------------------------------------------------

    private val backgroundThread = HandlerThread("CameraBackground").also { it.start() }
    private val backgroundHandler = Handler(backgroundThread.looper)

    /** Handler for dispatching Pigeon callbacks and Dart API calls to the main thread. */
    private val mainHandler = Handler(Looper.getMainLooper())

    // -------------------------------------------------------------------------
    // Preview surface lifecycle
    // -------------------------------------------------------------------------

    init {
        // Listen for surface availability/cleanup events (e.g. app moves to background).
        surfaceProducer.setCallback(
            object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    // Surface was recreated — resize and reconnect native rendering.
                    val ptr = nativePipelinePtr
                    if (ptr == 0L) return
                    val width = previewWidth
                    val height = previewHeight
                    if (width > 0 && height > 0) {
                        surfaceProducer.setSize(width, height)
                    }
                    val surface = surfaceProducer.getSurface()
                    nativeSetPreviewWindow(ptr, surface)
                    if (state == State.STREAMING) {
                        // Camera2 writes directly to SurfaceProducer for YUV preview.
                        // If SurfaceProducer recreated the surface, recreate session targets.
                        backgroundHandler.post { rebindYuvPreviewSurface(surface) }
                    }
                }

                override fun onSurfaceCleanup() {
                    // Surface is going away; pause native rendering until recreated.
                    val ptr = nativePipelinePtr
                    if (ptr != 0L) {
                        nativeSetPreviewWindow(ptr, null)
                    }
                }
            },
        )
    }

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    /**
     * Opens the specified camera and starts a preview streaming session.
     *
     * If [cameraId] is null the first back-facing camera is selected, falling back to the
     * first available camera if none is back-facing.
     *
     * Initial [settings] are applied to the first repeating [CaptureRequest].
     *
     * Emits `"opening"` then (on success) `"streaming"` state events to Dart. On failure,
     * begins the auto-recovery loop unless the error is fatal.
     *
     * @param cameraId  Optional Camera2 device ID. Pass null to auto-select.
     * @param settings  Optional initial ISP settings.
     * @param callback  Invoked with the camera handle on success, or a [FlutterError] on failure.
     */
    fun open(
        cameraId: String?,
        settings: CamSettings?,
        callback: (Result<Long>) -> Unit,
    ) {
        // Check camera permission before touching Camera2.
        if (context.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            callback(Result.failure(FlutterError("permission_denied", "Camera permission not granted", null)))
            return
        }

        pendingSettings = settings
        resolvedCameraId = cameraId ?: selectDefaultCameraId()

        val id = resolvedCameraId
        if (id == null) {
            callback(Result.failure(FlutterError("no_camera", "No camera device found on this device", null)))
            return
        }

        emitState("opening")
        setState(State.OPENING)

        // Guard against Camera2 firing both onDisconnected and onError for the same
        // open attempt — Pigeon reply channels accept exactly one reply per call.
        var replied = false
        val safeCallback: (Result<Long>) -> Unit = { result ->
            if (!replied) {
                replied = true
                callback(result)
            }
        }

        try {
            openLock.acquire()
        } catch (e: InterruptedException) {
            safeCallback(Result.failure(FlutterError("interrupted", "Open interrupted", null)))
            return
        }

        try {
            cameraManager.openCamera(
                id,
                { command -> backgroundHandler.post(command) },
                object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        openLock.release()
                        cameraDevice = camera
                        retryCount = 0 // Reset backoff counter on successful open.
                        startCaptureSession(safeCallback)
                    }

                    override fun onDisconnected(camera: CameraDevice) {
                        openLock.release()
                        camera.close()
                        cameraDevice = null
                        // Non-fatal — attempt recovery.
                        handleNonFatalError("camera_disconnected", "Camera disconnected unexpectedly")
                        mainHandler.post { safeCallback(Result.failure(FlutterError("camera_disconnected", "Camera disconnected", null))) }
                    }

                    override fun onError(
                        camera: CameraDevice,
                        error: Int,
                    ) {
                        openLock.release()
                        camera.close()
                        cameraDevice = null

                        val (code, message) = errorCodeToMessage(error)
                        val fatal = isFatalDeviceError(error)
                        if (fatal) {
                            handleFatalError(code, message)
                        } else {
                            handleNonFatalError(code, message)
                        }
                        mainHandler.post { safeCallback(Result.failure(FlutterError(code, message, null))) }
                    }
                },
            )
        } catch (e: CameraAccessException) {
            openLock.release()
            val fatal = isFatalAccessException(e)
            val code = "camera_access_error"
            val message = e.message ?: "CameraAccessException"
            if (fatal) {
                handleFatalError(code, message)
            } else {
                handleNonFatalError(code, message)
            }
            safeCallback(Result.failure(FlutterError(code, message, null)))
        } catch (e: SecurityException) {
            openLock.release()
            handleFatalError("permission_denied", e.message ?: "SecurityException")
            safeCallback(Result.failure(FlutterError("permission_denied", e.message, null)))
        }
    }

    /**
     * Closes the camera session and releases all Camera2 resources.
     *
     * Emits a `"closed"` state event to Dart after teardown completes.
     *
     * @param callback Invoked with [Result.success] after resources are released.
     */
    fun close(callback: (Result<Unit>) -> Unit) {
        teardown()
        emitState("closed")
        setState(State.CLOSED)
        callback(Result.success(Unit))
    }

    /**
     * Queries [CameraCharacteristics] and returns real hardware capabilities.
     *
     * Reports the three largest JPEG output sizes, sensor sensitivity and exposure ranges,
     * focus distance range, zoom range, EV compensation range, and an estimate of the
     * memory used by the 4-slot ring buffer.
     *
     * @param callback Invoked with the populated [CamCapabilities] or a [FlutterError].
     */
    fun getCapabilities(callback: (Result<CamCapabilities>) -> Unit) {
        val id = resolvedCameraId ?: selectDefaultCameraId()
        if (id == null) {
            callback(Result.failure(FlutterError("no_camera", "No camera device found", null)))
            return
        }

        try {
            val chars = cameraManager.getCameraCharacteristics(id)
            val configMap = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)

            // Largest 3 JPEG output sizes, sorted descending by area.
            val jpegSizes: List<CamSize> =
                configMap
                    ?.getOutputSizes(ImageFormat.JPEG)
                    ?.sortedByDescending { it.width.toLong() * it.height }
                    ?.take(3)
                    ?.map { CamSize(it.width.toLong(), it.height.toLong()) }
                    ?: emptyList()

            val isoRange: Range<Int>? = chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
            val expRange: Range<Long>? = chars.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)

            // focusMin = 0.0 means infinity focus. focusMax = closest focus in diopters.
            val minFocusDist: Float = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f

            val maxDigitalZoom: Float = chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f

            val evRange: Range<Int>? = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
            val evStep: Rational? = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)

            // Estimate 4 ring-buffer slots of YUV at the largest supported size.
            val largestSize = jpegSizes.firstOrNull()
            val estimatedBytes: Long =
                if (largestSize != null) {
                    largestSize.width * largestSize.height * 4L * 4L
                } else {
                    0L
                }

            val caps =
                CamCapabilities(
                    supportedSizes = jpegSizes,
                    isoMin = isoRange?.lower?.toLong() ?: 100L,
                    isoMax = isoRange?.upper?.toLong() ?: 3200L,
                    exposureTimeMinNs = expRange?.lower ?: 100_000L,
                    exposureTimeMaxNs = expRange?.upper ?: 1_000_000_000L,
                    focusMin = 0.0, // 0.0 = infinity
                    focusMax = minFocusDist.toDouble(), // closest focus in diopters
                    zoomMin = 1.0,
                    zoomMax = maxDigitalZoom.toDouble(),
                    evCompMin = evRange?.lower?.toLong() ?: -6L,
                    evCompMax = evRange?.upper?.toLong() ?: 6L,
                    evCompensationStep = evStep?.toDouble() ?: 0.5,
                    supportsRgba8888 = false,
                    estimatedMemoryBytes = estimatedBytes,
                )
            callback(Result.success(caps))
        } catch (e: CameraAccessException) {
            callback(Result.failure(FlutterError("camera_access_error", e.message, null)))
        }
    }

    /**
     * Updates per-frame ISP settings by rebuilding the repeating [CaptureRequest].
     *
     * If no session is active the settings are stored as [pendingSettings] and applied
     * when the next session starts.
     *
     * @param settings The new capture settings to apply immediately.
     */
    fun updateSettings(settings: CamSettings) {
        pendingSettings = settings
        val session = captureSession ?: return
        val device = cameraDevice ?: return
        val targetSurface = repeatingTargetSurface ?: imageReader?.surface ?: return

        try {
            val request = buildCaptureRequest(device, targetSurface, settings)
            repeatingRequest = request
            if (VERBOSE_DIAGNOSTICS) {
                android.util.Log.d(
                    "CambrianCamera",
                    "updateSettings request target=${describeTargetSurface(targetSurface)} " +
                        "iso=${settings.iso ?: "auto"} exposureNs=${settings.exposureTimeNs ?: "auto"}",
                )
            }
            session.setRepeatingRequest(request, repeatingCaptureCallback, backgroundHandler)
            if (VERBOSE_SETTINGS) {
                android.util.Log.d("CambrianCamera", buildSettingsLog(settings))
            }
        } catch (e: CameraAccessException) {
            // Non-fatal; the session may be closing. Log and ignore.
            android.util.Log.w("CameraController", "updateSettings failed: ${e.message}")
        } catch (e: IllegalStateException) {
            android.util.Log.w("CameraController", "updateSettings: session already closed")
        }
    }

    /** Formats [settings] fields into a single log line, omitting null fields. */
    private fun buildSettingsLog(settings: CamSettings): String {
        val parts = mutableListOf<String>()
        settings.iso?.let { parts += "iso=$it" }
        settings.exposureTimeNs?.let { parts += "exposureNs=$it" }
        settings.focusDistanceDiopters?.let { parts += "focus=${String.format("%.3f", it)}dpt" }
        settings.zoomRatio?.let { parts += "zoom=${String.format("%.2f", it)}x" }
        settings.afEnabled?.let { parts += "af=$it" }
        settings.awbLocked?.let { parts += "awbLocked=$it" }
        settings.evCompensation?.let { parts += "ev=$it" }
        return "updateSettings: ${parts.joinToString(" ")}"
    }

    /**
     * No-op in Phase 3.
     *
     * Phase 4 will forward these parameters to the C++ image pipeline via JNI.
     *
     * @param params Image processing parameters (tone-mapping, auto-stretch, etc.).
     */
    fun setProcessingParams(params: CamProcessingParams) {
        // Phase 4: forward params to nativeSetProcessingParams(nativePipelinePtr, params)
    }

    /**
     * Captures a single JPEG frame and writes it to the app's cache directory.
     *
     * Captures via the pre-allocated JPEG [ImageReader], acquires the next image on a
     * background thread, and writes the bytes to `<cacheDir>/capture_<timestamp>.jpg`.
     *
     * @param callback Invoked with the absolute file path on success, or a [FlutterError].
     */
    fun takePicture(callback: (Result<String>) -> Unit) {
        val session = captureSession
        val device = cameraDevice
        val jpegReader = jpegImageReader

        if (session == null || device == null || jpegReader == null) {
            callback(Result.failure(FlutterError("not_streaming", "Camera is not streaming", null)))
            return
        }

        try {
            val jpegRequest =
                device
                    .createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
                    .apply {
                        addTarget(jpegReader.surface)
                    }.build()

            session.capture(
                jpegRequest,
                object : CameraCaptureSession.CaptureCallback() {
                    // Callback is intentionally empty; we wait on the ImageReader below.
                },
                backgroundHandler,
            )

            // Acquire the JPEG on the background thread to avoid blocking the main thread.
            backgroundHandler.post {
                val image: Image? =
                    try {
                        jpegReader.acquireNextImage()
                    } catch (e: Exception) {
                        null
                    }

                if (image == null) {
                    mainHandler.post { callback(Result.failure(FlutterError("capture_failed", "Failed to acquire JPEG image", null))) }
                    return@post
                }

                try {
                    val buffer = image.planes[0].buffer
                    val bytes = ByteArray(buffer.remaining())
                    buffer.get(bytes)

                    val timestamp = System.currentTimeMillis()
                    val file = File(context.cacheDir, "capture_$timestamp.jpg")
                    FileOutputStream(file).use { it.write(bytes) }

                    mainHandler.post { callback(Result.success(file.absolutePath)) }
                } catch (e: Exception) {
                    mainHandler.post { callback(Result.failure(FlutterError("capture_failed", e.message, null))) }
                } finally {
                    image.close()
                }
            }
        } catch (e: CameraAccessException) {
            callback(Result.failure(FlutterError("camera_access_error", e.message, null)))
        }
    }

    /**
     * Returns the opaque native pipeline pointer for direct JNI interop.
     *
     * Returns 0 if the native pipeline has not yet been initialised (i.e. before [open]
     * completes successfully).
     *
     * @param callback Invoked with the native pointer (may be 0).
     */
    fun getNativePipelineHandle(callback: (Result<Long>) -> Unit) {
        callback(Result.success(nativePipelinePtr))
    }

    /**
     * Tears down all resources without emitting state events.
     *
     * Called by the plugin on engine detach. Use [close] for orderly user-initiated shutdown.
     */
    fun release() {
        teardown()
        backgroundThread.quitSafely()
    }

    // -------------------------------------------------------------------------
    // Internal: session setup
    // -------------------------------------------------------------------------

    /**
     * Starts a Camera2 [CaptureSession] on the already-opened [cameraDevice].
     *
     * Streams YUV_420_888 at 4160×3120. A separate JPEG [ImageReader] is pre-allocated for
     * still capture. Preview is routed via [surfaceProducer] added directly to the session.
     *
     * Frame path: Camera2 → SurfaceProducer (display) + ImageReader (drained, reserved for JNI)
     */
    private fun startCaptureSession(openCallback: (Result<Long>) -> Unit) {
        val device =
            cameraDevice ?: run {
                mainHandler.post {
                    openCallback(
                        Result.failure(FlutterError("no_device", "Camera device lost before session start", null)),
                    )
                }
                return
            }

        val (streamFormat, streamWidth, streamHeight) = resolveStreamFormat(device)
        streamFrameCount = 0L
        captureResultCount = 0L

        previewWidth = streamWidth
        previewHeight = streamHeight
        surfaceProducer.setSize(streamWidth, streamHeight)
        if (VERBOSE_DIAGNOSTICS) {
            android.util.Log.d(
                "CambrianCamera",
                "startCaptureSession format=YUV_420_888 size=${streamWidth}x$streamHeight",
            )
        }

        // Streaming ImageReader — YUV_420_888 frames are drained to prevent overflow.
        // Preview is served by Camera2 writing directly to the SurfaceProducer surface.
        val streamReader = ImageReader.newInstance(streamWidth, streamHeight, streamFormat, 2)
        imageReader = streamReader

        // JPEG ImageReader — pre-allocated for still capture (use streaming resolution).
        val jpegReader = ImageReader.newInstance(streamWidth, streamHeight, ImageFormat.JPEG, 1)
        jpegImageReader = jpegReader

        // Initialise native pipeline with the current SurfaceProducer surface.
        val previewSurface = surfaceProducer.getSurface()
        nativePipelinePtr = nativeInit(previewSurface)

        // Drain YUV frames to prevent ImageReader overflow.
        streamReader.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            try {
                streamFrameCount++
                if (VERBOSE_DIAGNOSTICS && (streamFrameCount == 1L || streamFrameCount % 60L == 0L)) {
                    android.util.Log.d(
                        "CambrianCamera",
                        "stream frame#$streamFrameCount YUV ${image.width}x${image.height}",
                    )
                }
            } finally {
                image.close()
            }
        }, backgroundHandler)

        // Session surfaces: streaming reader + JPEG reader + SurfaceProducer for preview.
        val surfaces = listOf(streamReader.surface, jpegReader.surface, previewSurface)

        // The repeating request targets the SurfaceProducer; Camera2 writes preview frames directly.
        val previewTarget = previewSurface
        repeatingTargetSurface = previewTarget

        val outputs = surfaces.map { OutputConfiguration(it) }
        device.createCaptureSession(
            SessionConfiguration(
                SessionConfiguration.SESSION_REGULAR,
                outputs,
                { command -> backgroundHandler.post(command) },
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        try {
                            val settings = pendingSettings
                            val request =
                                if (settings != null) {
                                    buildCaptureRequest(device, previewTarget, settings)
                                } else {
                                    buildDefaultCaptureRequest(device, previewTarget)
                                }
                            repeatingRequest = request
                            if (VERBOSE_DIAGNOSTICS) {
                                android.util.Log.d(
                                    "CambrianCamera",
                                    "setRepeatingRequest target=${describeTargetSurface(previewTarget)} " +
                                        "initialIso=${settings?.iso ?: "auto"} initialExposureNs=${settings?.exposureTimeNs ?: "auto"}",
                                )
                            }
                            session.setRepeatingRequest(request, repeatingCaptureCallback, backgroundHandler)
                            setState(State.STREAMING)
                            emitState("streaming")
                            mainHandler.post { openCallback(Result.success(handle)) }
                        } catch (e: CameraAccessException) {
                            handleNonFatalError("camera_access_error", e.message ?: "CameraAccessException")
                            mainHandler.post { openCallback(Result.failure(FlutterError("camera_access_error", e.message, null))) }
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        handleNonFatalError("configure_failed", "CaptureSession configuration failed")
                        mainHandler.post {
                            openCallback(
                                Result.failure(FlutterError("configure_failed", "Session configuration failed", null)),
                            )
                        }
                    }
                },
            ),
        )
    }

    /**
     * Returns the fixed streaming format and resolution for this device.
     *
     * The OPD2403 does not advertise [android.graphics.PixelFormat.RGBA_8888]; YUV_420_888
     * is the CPU-readable format used by the C++ ISP pipeline. Resolution 4160×3120 is the
     * largest YUV size the device supports at 30 fps (see docs/camera0-characteristics-OPD2403.txt).
     *
     * @return Triple of (format, width, height).
     */
    private fun resolveStreamFormat(device: CameraDevice): Triple<Int, Int, Int> =
        Triple(ImageFormat.YUV_420_888, 4160, 3120)

    // -------------------------------------------------------------------------
    // Internal: CaptureRequest builders
    // -------------------------------------------------------------------------

    /**
     * Builds a default repeating [CaptureRequest] (auto-everything) targeting [surface].
     */
    private fun buildDefaultCaptureRequest(
        device: CameraDevice,
        surface: Surface,
    ): CaptureRequest =
        device
            .createCaptureRequest(CameraDevice.TEMPLATE_ZERO_SHUTTER_LAG)
            .apply {
                addTarget(surface)
                set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            }.build()

    /**
     * Builds a repeating [CaptureRequest] populated from [settings], targeting [surface].
     *
     * Fields left null in [settings] default to auto/continuous control.
     */
    private fun buildCaptureRequest(
        device: CameraDevice,
        surface: Surface,
        settings: CamSettings,
    ): CaptureRequest =
        device
            .createCaptureRequest(CameraDevice.TEMPLATE_ZERO_SHUTTER_LAG)
            .apply {
                addTarget(surface)
                set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)

                // ISO
                settings.iso?.let { set(CaptureRequest.SENSOR_SENSITIVITY, it.toInt()) }

                // Exposure time
                settings.exposureTimeNs?.let { set(CaptureRequest.SENSOR_EXPOSURE_TIME, it) }

                // Focus: explicit distance disables AF; otherwise respect afEnabled flag.
                if (settings.focusDistanceDiopters != null) {
                    set(CaptureRequest.LENS_FOCUS_DISTANCE, settings.focusDistanceDiopters.toFloat())
                    set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                } else {
                    val afMode =
                        if (settings.afEnabled == false) {
                            CaptureRequest.CONTROL_AF_MODE_AUTO
                        } else {
                            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
                        }
                    set(CaptureRequest.CONTROL_AF_MODE, afMode)
                }

                // Zoom — use CONTROL_ZOOM_RATIO on API 30+, fall back to SCALER_CROP_REGION.
                settings.zoomRatio?.let { zoom ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom.toFloat())
                    } else {
                        applyZoomViaCropRegion(this, zoom)
                    }
                }

                // AWB lock
                settings.awbLocked?.let { set(CaptureRequest.CONTROL_AWB_LOCK, it) }

                // Noise reduction mode
                settings.noiseReductionMode?.let {
                    set(CaptureRequest.NOISE_REDUCTION_MODE, it.toInt())
                }

                // Edge enhancement mode
                settings.edgeMode?.let { set(CaptureRequest.EDGE_MODE, it.toInt()) }

                // EV compensation
                settings.evCompensation?.let {
                    set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, it.toInt())
                }
            }.build()

    /**
     * Applies digital zoom by computing a centred crop region.
     *
     * Used as a fallback on API < 30 where [CaptureRequest.CONTROL_ZOOM_RATIO] is unavailable.
     *
     * @param builder  The request builder to modify in place.
     * @param zoomRatio Desired zoom level (1.0 = no zoom).
     */
    private fun applyZoomViaCropRegion(
        builder: CaptureRequest.Builder,
        zoomRatio: Double,
    ) {
        val id = resolvedCameraId ?: return
        val chars =
            try {
                cameraManager.getCameraCharacteristics(id)
            } catch (e: CameraAccessException) {
                return
            }

        val sensorSize = chars.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: return
        val ratio = zoomRatio.coerceAtLeast(1.0)
        val cropW = (sensorSize.width() / ratio).toInt()
        val cropH = (sensorSize.height() / ratio).toInt()
        val offsetX = (sensorSize.width() - cropW) / 2
        val offsetY = (sensorSize.height() - cropH) / 2
        builder.set(
            CaptureRequest.SCALER_CROP_REGION,
            android.graphics.Rect(offsetX, offsetY, offsetX + cropW, offsetY + cropH),
        )
    }

    /**
     * Recreates the capture session when in YUV fallback and SurfaceProducer provides a new surface.
     *
     * In this mode Camera2 writes preview frames directly into SurfaceProducer's surface, so surface
     * recreation requires capture-session target rebinding.
     */
    private fun rebindYuvPreviewSurface(previewSurface: Surface) {
        val device = cameraDevice ?: return
        val streamReader = imageReader ?: return
        val jpegReader = jpegImageReader ?: return
        val previousSession = captureSession

        try {
            previousSession?.stopRepeating()
            previousSession?.abortCaptures()
        } catch (_: Exception) {
        }
        try {
            previousSession?.close()
        } catch (_: Exception) {
        }
        captureSession = null

        val surfaces = listOf(streamReader.surface, jpegReader.surface, previewSurface)
        if (VERBOSE_DIAGNOSTICS) {
            android.util.Log.d("CambrianCamera", "Rebinding YUV preview surface via createCaptureSession")
        }
        val outputs = surfaces.map { OutputConfiguration(it) }
        device.createCaptureSession(
            SessionConfiguration(
                SessionConfiguration.SESSION_REGULAR,
                outputs,
                { command -> backgroundHandler.post(command) },
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        try {
                            val settings = pendingSettings
                            val request =
                                if (settings != null) {
                                    buildCaptureRequest(device, previewSurface, settings)
                                } else {
                                    buildDefaultCaptureRequest(device, previewSurface)
                                }
                            repeatingTargetSurface = previewSurface
                            repeatingRequest = request
                            session.setRepeatingRequest(request, repeatingCaptureCallback, backgroundHandler)
                            if (VERBOSE_DIAGNOSTICS) {
                                android.util.Log.d(
                                    "CambrianCamera",
                                    "YUV preview rebind complete target=${describeTargetSurface(previewSurface)}",
                                )
                            }
                        } catch (e: CameraAccessException) {
                            handleNonFatalError("camera_access_error", e.message ?: "CameraAccessException")
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        handleNonFatalError("configure_failed", "CaptureSession rebind failed")
                    }
                },
            ),
        )
    }

    // -------------------------------------------------------------------------
    // Internal: resource teardown
    // -------------------------------------------------------------------------

    /**
     * Closes all Camera2 resources and resets internal references.
     *
     * Safe to call from any state. Does NOT emit state events (callers must do that).
     */
    private fun teardown() {
        // Close capture session first to stop frame delivery before closing the device.
        try {
            captureSession?.close()
        } catch (_: Exception) {
        }
        captureSession = null

        try {
            cameraDevice?.close()
        } catch (_: Exception) {
        }
        cameraDevice = null

        try {
            imageReader?.close()
        } catch (_: Exception) {
        }
        imageReader = null

        try {
            jpegImageReader?.close()
        } catch (_: Exception) {
        }
        jpegImageReader = null
        repeatingTargetSurface = null
        streamFrameCount = 0L
        captureResultCount = 0L

        // Release native pipeline.
        val ptr = nativePipelinePtr
        if (ptr != 0L) {
            nativeRelease(ptr)
            nativePipelinePtr = 0L
        }
    }

    // -------------------------------------------------------------------------
    // Internal: auto-recovery
    // -------------------------------------------------------------------------

    /**
     * Handles a non-fatal error by transitioning to RECOVERING and scheduling a retry.
     *
     * @param code    Error code forwarded to Dart.
     * @param message Human-readable description forwarded to Dart.
     */
    private fun handleNonFatalError(
        code: String,
        message: String,
    ) {
        if (state == State.ERROR) return // Already in a terminal state.

        setState(State.RECOVERING)
        emitState("recovering")
        mainHandler.post { flutterApi.onError(handle, CamError(code, message, false)) {} }

        if (retryCount >= maxRetries) {
            handleFatalError("max_retries_exceeded", "Camera failed after $maxRetries retries")
            return
        }

        val delayMs = backoffDelaysMs[minOf(retryCount, backoffDelaysMs.size - 1)]
        retryCount++

        backgroundHandler.postDelayed({
            teardown()
            val id = resolvedCameraId ?: return@postDelayed
            if (state != State.RECOVERING) return@postDelayed // Cancelled by explicit close.

            // Check permission again before retrying.
            if (context.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                handleFatalError("permission_denied", "Camera permission lost during recovery")
                return@postDelayed
            }

            try {
                openLock.acquire()
                cameraManager.openCamera(
                    id,
                    { command -> backgroundHandler.post(command) },
                    object : CameraDevice.StateCallback() {
                        override fun onOpened(camera: CameraDevice) {
                            openLock.release()
                            cameraDevice = camera
                            retryCount = 0
                            startCaptureSession { result ->
                                result.onFailure { handleNonFatalError("session_error", it.message ?: "Session error") }
                            }
                        }

                        override fun onDisconnected(camera: CameraDevice) {
                            openLock.release()
                            camera.close()
                            cameraDevice = null
                            handleNonFatalError("camera_disconnected", "Camera disconnected during recovery")
                        }

                        override fun onError(
                            camera: CameraDevice,
                            error: Int,
                        ) {
                            openLock.release()
                            camera.close()
                            cameraDevice = null
                            val (errCode, errMsg) = errorCodeToMessage(error)
                            if (isFatalDeviceError(error)) {
                                handleFatalError(errCode, errMsg)
                            } else {
                                handleNonFatalError(errCode, errMsg)
                            }
                        }
                    },
                )
            } catch (e: CameraAccessException) {
                openLock.release()
                if (isFatalAccessException(e)) {
                    handleFatalError("camera_access_error", e.message ?: "CameraAccessException")
                } else {
                    handleNonFatalError("camera_access_error", e.message ?: "CameraAccessException")
                }
            } catch (e: InterruptedException) {
                // Lock acquire interrupted; give up gracefully.
            } catch (e: SecurityException) {
                openLock.release()
                handleFatalError("permission_denied", e.message ?: "SecurityException")
            }
        }, delayMs)
    }

    /**
     * Handles a fatal error by transitioning to ERROR (no further retries).
     *
     * @param code    Error code forwarded to Dart.
     * @param message Human-readable description forwarded to Dart.
     */
    private fun handleFatalError(
        code: String,
        message: String,
    ) {
        teardown()
        setState(State.ERROR)
        emitState("error")
        mainHandler.post { flutterApi.onError(handle, CamError(code, message, true)) {} }
    }

    // -------------------------------------------------------------------------
    // Internal: helpers
    // -------------------------------------------------------------------------

    /**
     * Emits a state-change event to Dart via [flutterApi].
     *
     * Always posts to the main thread — Pigeon binary messenger requires it.
     */
    private fun emitState(stateName: String) {
        mainHandler.post {
            flutterApi.onStateChanged(handle, CamStateUpdate(stateName)) {}
        }
    }

    private val repeatingCaptureCallback =
        object : CameraCaptureSession.CaptureCallback() {
            override fun onCaptureCompleted(
                session: CameraCaptureSession,
                request: CaptureRequest,
                result: TotalCaptureResult,
            ) {
                if (!VERBOSE_DIAGNOSTICS) return
                captureResultCount++
                if (captureResultCount != 1L && captureResultCount % 60L != 0L) return
                val aeMode = result.get(CaptureResult.CONTROL_AE_MODE)
                val aeState = result.get(CaptureResult.CONTROL_AE_STATE)
                val iso = result.get(CaptureResult.SENSOR_SENSITIVITY)
                val exposure = result.get(CaptureResult.SENSOR_EXPOSURE_TIME)
                android.util.Log.d(
                    "CambrianCamera",
                    "capture result#$captureResultCount target=${describeTargetSurface(repeatingTargetSurface)} " +
                        "aeMode=$aeMode aeState=$aeState iso=$iso exposureNs=$exposure",
                )
            }
        }

    private fun describeTargetSurface(surface: Surface?): String {
        val imageSurface = imageReader?.surface
        return when {
            surface == null -> "null"
            imageSurface != null && surface === imageSurface -> "imageReader"
            else -> "surfaceProducer"
        }
    }

    /** Updates internal state field (single place to add logging if needed). */
    private fun setState(newState: State) {
        state = newState
    }

    /**
     * Selects the first back-facing camera ID, or the first camera if none is back-facing.
     *
     * @return A camera ID string, or null if no cameras exist.
     */
    private fun selectDefaultCameraId(): String? {
        val ids =
            try {
                cameraManager.cameraIdList
            } catch (e: CameraAccessException) {
                return null
            }
        return ids.firstOrNull { id ->
            try {
                cameraManager
                    .getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
            } catch (e: CameraAccessException) {
                false
            }
        } ?: ids.firstOrNull()
    }

    /**
     * Returns true if the [CameraDevice] error code indicates a fatal, unrecoverable condition.
     *
     * Fatal errors: [CameraDevice.ERROR_CAMERA_DISABLED], [CameraDevice.ERROR_MAX_CAMERAS_IN_USE].
     * Non-fatal: [CameraDevice.ERROR_CAMERA_DEVICE], [CameraDevice.ERROR_CAMERA_SERVICE].
     */
    private fun isFatalDeviceError(error: Int): Boolean =
        error == CameraDevice.StateCallback.ERROR_CAMERA_DISABLED ||
            error == CameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE

    /**
     * Returns true if the [CameraAccessException] indicates a fatal condition.
     *
     * [CameraAccessException.CAMERA_DISABLED] is fatal; all others are recoverable.
     */
    private fun isFatalAccessException(e: CameraAccessException): Boolean = e.reason == CameraAccessException.CAMERA_DISABLED

    /**
     * Maps a [CameraDevice] error integer to a (code, message) pair for Dart callbacks.
     */
    private fun errorCodeToMessage(error: Int): Pair<String, String> =
        when (error) {
            CameraDevice.StateCallback.ERROR_CAMERA_IN_USE -> Pair("camera_in_use", "Camera is already in use")
            CameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE -> Pair("max_cameras_in_use", "Too many cameras are open")
            CameraDevice.StateCallback.ERROR_CAMERA_DISABLED -> Pair("camera_disabled", "Camera disabled by policy")
            CameraDevice.StateCallback.ERROR_CAMERA_DEVICE -> Pair("camera_device_error", "Fatal camera device error")
            CameraDevice.StateCallback.ERROR_CAMERA_SERVICE -> Pair("camera_service_error", "Camera service error")
            else -> Pair("camera_error", "Unknown camera error: $error")
        }
}
