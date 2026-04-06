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
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Camera2 lifecycle manager for the cambrian_camera plugin.
 *
 * Responsibilities:
 * - Opens a Camera2 device and configures a [CaptureSession] with a [GpuPipeline]
 *   (OES SurfaceTexture → GL render thread → RGBA sinks) and a JPEG [ImageReader] for still capture.
 * - Routes shader adjustment params via [GpuPipeline.setAdjustments].
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
    private val rawSurfaceProducer: TextureRegistry.SurfaceProducer?,
    private val enableRawStream: Boolean,
    private val rawStreamHeight: Int,
    private val flutterApi: CameraFlutterApi,
    val handle: Long,
) {
    // -------------------------------------------------------------------------
    // JNI bridge
    // -------------------------------------------------------------------------

    companion object {
        init {
            try {
                System.loadLibrary("cambrian_camera")
            } catch (_: UnsatisfiedLinkError) {
                // Library not available in JVM unit tests; JNI calls will throw at runtime
                // if invoked without the native library loaded.
            }
        }

        /** Initialises the native pipeline and pre-allocates the input ring for the given dims. */
        @JvmStatic external fun nativeInit(previewSurface: Surface?, width: Int, height: Int): Long

        // YUV layout constants — kept in sync with InputRing.h.
        const val YUV_FORMAT_UNKNOWN = 0
        const val YUV_FORMAT_NV21    = 1  // VU interleaved (Android default)
        const val YUV_FORMAT_NV12    = 2  // UV interleaved
        const val YUV_FORMAT_I420    = 3  // Planar

        /** Releases all resources held by the native pipeline. */
        @JvmStatic external fun nativeRelease(pipelinePtr: Long)

        /**
         * Notifies the native pipeline of a new processed-preview [Surface] (e.g. after a surface
         * recreation event from [TextureRegistry.SurfaceProducer.Callback]).
         */
        @JvmStatic external fun nativeSetPreviewWindow(
            pipelinePtr: Long,
            previewSurface: Surface?,
        )

        /**
         * Copies one YUV_420_888 frame into the C++ input ring. Returns immediately;
         * the caller may close the camera Image right after this call returns.
         *
         * @param pipelinePtr      Pointer returned by [nativeInit].
         * @param yBuffer          Direct ByteBuffer for the Y plane.
         * @param yRowStride       Row stride of the Y plane in bytes.
         * @param uBuffer          Direct ByteBuffer for the U (Cb) plane.
         * @param uvRowStride      Row stride of U/V planes in bytes.
         * @param uvPixelStride    Pixel stride of U/V planes (1=I420, 2=NV12/NV21).
         * @param vBuffer          Direct ByteBuffer for the V (Cr) plane.
         * @param width            Frame width in pixels.
         * @param height           Frame height in pixels.
         * @param frameId          Monotonic frame counter (streamFrameCount).
         * @param iso              Sensor ISO from latest capture result; 0 if not yet known.
         * @param exposureTimeNs   Exposure duration in ns from latest capture result; 0 if unknown.
         * @param sensorTimestamp  Sensor timestamp from [android.media.Image.getTimestamp].
         * @param yuvFormat        YUV layout constant ([YUV_FORMAT_NV21]/NV12/I420).
         */
        @JvmStatic external fun nativeDeliverYuv(
            pipelinePtr: Long,
            yBuffer: ByteBuffer, yRowStride: Int,
            uBuffer: ByteBuffer, uvRowStride: Int, uvPixelStride: Int,
            vBuffer: ByteBuffer,
            width: Int, height: Int,
            frameId: Long,
            iso: Int, exposureTimeNs: Long, sensorTimestamp: Long,
            yuvFormat: Int,
        )

        /**
         * Updates the C++ pipeline's processing parameters (fire-and-forget).
         * The next frame will pick up the new values.
         */
        @JvmStatic external fun nativeSetProcessingParams(
            pipelinePtr: Long,
            blackR: Double, blackG: Double, blackB: Double,
            gamma: Double,
            brightness: Double,
            saturation: Double,
        )
    }

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------

    /** Internal camera lifecycle state. */
    private enum class State { CLOSED, OPENING, STREAMING, RECOVERING, ERROR }

    @Volatile private var state: State = State.CLOSED

    /** True once [close] or [release] has been called. The instance must not be reused. */
    @Volatile private var released = false

    // -------------------------------------------------------------------------
    // Camera2 resources
    // -------------------------------------------------------------------------

    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    /** Serialises concurrent open/close calls so we never open the device twice. */
    private val openLock = Semaphore(1)

    @Volatile private var cameraDevice: CameraDevice? = null

    @Volatile private var captureSession: CameraCaptureSession? = null

    @Volatile private var imageReader: ImageReader? = null

    @Volatile private var gpuPipeline: GpuPipeline? = null

    @Volatile private var jpegImageReader: ImageReader? = null

    /** True while a still-capture is in flight; prevents listener overwrites from concurrent calls. */
    private val isCaptureInFlight = AtomicBoolean(false)

    /** Repeating request rebuilt whenever settings change. */
    @Volatile private var repeatingRequest: CaptureRequest? = null

    /** The surface currently targeted by the repeating request. */
    @Volatile private var repeatingTargetSurface: Surface? = null

    /** Opaque pointer to the native pipeline, set after [nativeInit]. */
    @Volatile private var nativePipelinePtr: Long = 0L

    /** Encoder-side recording state. Null until first startRecording() call. */
    private var videoRecorder: VideoRecorder? = null

    /** True when a recording is active; gates encoder surface inclusion in session. */
    @Volatile private var isRecording = false

    /** Encoder target fps set by the last startRecording() call; used to align AE fps range. */
    @Volatile private var recordingFps: Int = 30

    /**
     * Guards [nativePipelinePtr] reads/writes and JNI calls that touch the native pipeline.
     * Ensures [nativeDeliverYuv] and [nativeRelease] never run concurrently for the same pointer.
     */
    private val pipelineLock = Any()

    /** Last processing params applied via [setProcessingParams]; replayed after pipeline recreation. */
    @Volatile private var lastProcessingParams: CamProcessingParams? = null

    /** Latest preview dimensions configured on [surfaceProducer]. */
    @Volatile private var previewWidth: Int = 0

    @Volatile private var previewHeight: Int = 0

    /** Raw stream dimensions, set during [startCaptureSession] when [enableRawStream] is true. */
    @Volatile private var rawW: Int = 0

    @Volatile private var rawH: Int = 0

    /** Camera ID resolved in [open]; stored for reconnect retries. */
    @Volatile private var resolvedCameraId: String? = null

    /** Settings to apply at session start; updated by [updateSettings]. */
    @Volatile private var pendingSettings: CamSettings? = null

    /**
     * Accumulated settings state. Each [updateSettings] call merges non-null
     * incoming fields into this object so that omitted fields retain their
     * previous values across calls (instead of reverting to Camera2 template
     * defaults).
     */
    @Volatile private var appliedSettings: CamSettings = CamSettings()

    /** Frame counter used for periodic diagnostics and as frameId for the native pipeline. */
    @Volatile private var streamFrameCount: Long = 0L

    /** Capture-result counter used for periodic diagnostics. */
    @Volatile private var captureResultCount: Long = 0L

    /**
     * YUV layout of the Camera2 stream, detected from plane strides on the first frame
     * and cached for all subsequent frames. Reset to [YUV_FORMAT_UNKNOWN] at each
     * session start. Accessed only from the camera background thread; no @Volatile needed.
     */
    private var detectedYuvFormat: Int = YUV_FORMAT_UNKNOWN

    /**
     * Last sensor values reported by Camera2 capture results.
     * Updated on every frame from the latest TotalCaptureResult.
     * Used to seed manual mode when the user switches one field to manual —
     * the partner is initialised to the last live AE value so exposure is continuous.
     */
    @Volatile private var lastKnownIso: Int? = null
    @Volatile private var lastKnownExposureTimeNs: Long? = null

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
                    val ptr = nativePipelinePtr
                    if (ptr == 0L) return
                    val width = previewWidth
                    val height = previewHeight
                    if (width > 0 && height > 0) {
                        surfaceProducer.setSize(width, height)
                    }
                    nativeSetPreviewWindow(ptr, surfaceProducer.getSurface())
                    // Rebind the GPU renderer's processed preview EGL surface so the
                    // preview resumes after Flutter recreates the SurfaceProducer surface.
                    gpuPipeline?.rebindPreviewSurface(surfaceProducer.getSurface())
                }

                override fun onSurfaceCleanup() {
                    val ptr = nativePipelinePtr
                    if (ptr != 0L) nativeSetPreviewWindow(ptr, null)
                    // Detach the GPU renderer's processed preview EGL surface so it
                    // stops rendering to a dead surface while the app is backgrounded.
                    gpuPipeline?.rebindPreviewSurface(null)
                }
            },
        )
        rawSurfaceProducer?.setCallback(
            object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() {
                    val w = rawW
                    val h = rawH
                    if (w > 0 && h > 0) {
                        rawSurfaceProducer.setSize(w, h)
                    }
                    // Rebind the new native window to the GPU renderer so raw preview
                    // resumes after Flutter recreates the SurfaceProducer surface.
                    gpuPipeline?.rebindRawSurface(rawSurfaceProducer.getSurface())
                }

                override fun onSurfaceCleanup() {
                    // No-op: raw surface lifecycle is managed by GpuPipeline (EGL).
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
        if (released) {
            callback(Result.failure(FlutterError("already_released", "CameraController cannot be reused after close()", null)))
            return
        }

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
                        handleNonFatalError(CamErrorCode.CAMERA_DISCONNECTED, "Camera disconnected unexpectedly")
                        mainHandler.post { safeCallback(Result.failure(FlutterError(CamErrorCode.CAMERA_DISCONNECTED.name, "Camera disconnected", null))) }
                    }

                    override fun onError(
                        camera: CameraDevice,
                        error: Int,
                    ) {
                        openLock.release()
                        camera.close()
                        cameraDevice = null

                        val (errCode, message) = errorCodeToMessage(error)
                        val fatal = isFatalDeviceError(error)
                        if (fatal) {
                            handleFatalError(errCode, message)
                        } else {
                            handleNonFatalError(errCode, message)
                        }
                        mainHandler.post { safeCallback(Result.failure(FlutterError(errCode.name, message, null))) }
                    }
                },
            )
        } catch (e: CameraAccessException) {
            openLock.release()
            val fatal = isFatalAccessException(e)
            val message = e.message ?: "CameraAccessException"
            if (fatal) {
                handleFatalError(CamErrorCode.CAMERA_ACCESS_ERROR, message)
            } else {
                handleNonFatalError(CamErrorCode.CAMERA_ACCESS_ERROR, message)
            }
            safeCallback(Result.failure(FlutterError(CamErrorCode.CAMERA_ACCESS_ERROR.name, message, null)))
        } catch (e: SecurityException) {
            openLock.release()
            handleFatalError(CamErrorCode.PERMISSION_DENIED, e.message ?: "SecurityException")
            safeCallback(Result.failure(FlutterError(CamErrorCode.PERMISSION_DENIED.name, e.message, null)))
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
        released = true
        teardown()
        backgroundThread.quitSafely()
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
                    // Report non-zero raw stream info only when the GPU pipeline is actually
                    // running with raw enabled; nativeGpuInit may silently disable it.
                    rawStreamTextureId = if (gpuPipeline?.isRunning == true) rawSurfaceProducer?.id() ?: 0L else 0L,
                    rawStreamWidth = if (gpuPipeline?.isRunning == true) rawW.toLong() else 0L,
                    rawStreamHeight = if (gpuPipeline?.isRunning == true) rawH.toLong() else 0L,
                    streamWidth = previewWidth.toLong(),
                    streamHeight = previewHeight.toLong(),
                )
            callback(Result.success(caps))
        } catch (e: CameraAccessException) {
            callback(Result.failure(FlutterError("camera_access_error", e.message, null)))
        }
    }

    /**
     * Updates per-frame ISP settings by rebuilding the repeating [CaptureRequest].
     *
     * Non-null fields in [incoming] are merged into [appliedSettings]; null fields
     * are left unchanged. This means callers only need to send the fields they
     * want to change — omitted fields retain their previous values.
     *
     * If no session is active the merged settings are stored as [pendingSettings]
     * and applied when the next session starts.
     *
     * ## ISO + Exposure coupling
     *
     * [CamSettings.isoMode] and [CamSettings.exposureMode] are tied to a single
     * Camera2 flag (`CONTROL_AE_MODE`), so they must always end up in the same mode:
     *
     * - **Auto is contagious:** setting either field to `"auto"` automatically
     *   propagates to the other field.  You may set only one to `"auto"` in a call —
     *   the partner is pulled along silently.
     * - **Auto wins over manual:** if one field is `"auto"` and the other is `"manual"`
     *   after merging, both are pulled to `"auto"`.  This handles the common UI case
     *   where an ISO slider emits `{iso=auto, exposure=manual(lastValue)}` — the intent
     *   is to switch to auto mode, and the stale manual value on the other slider is
     *   correctly discarded.
     * - **Manual latches from last AE values:** when only one field is set to manual
     *   (the other is null = "don't change"), the partner is automatically seeded from
     *   the last sensor values reported by Camera2 capture results
     *   (`lastKnownIso` / `lastKnownExposureTimeNs`), so brightness is continuous.
     *   If no capture result has arrived yet, the call is rejected with
     *   [CamErrorCode.SETTINGS_CONFLICT].
     *
     * @param incoming The settings to merge and apply.
     */
    fun updateSettings(incoming: CamSettings) {
        // Phase 1 (merge) + auto-propagation.
        // Camera2 ties ISO and exposure to a single CONTROL_AE_MODE flag (ON = both auto,
        // OFF = both manual).  Auto is contagious: if either field is "auto" after merging,
        // both are pulled to auto.  This means an incoming {iso=auto, exposure=manual} pair
        // (e.g. from a UI where the ISO slider was moved to auto while exposure retained its
        // value) resolves correctly — auto wins and both switch to auto mode.
        var merged = mergeSettings(appliedSettings, incoming)
        val mergedIsoAuto = merged.isoMode == "auto"
        val mergedExpAuto = merged.exposureMode == "auto"
        if (mergedIsoAuto && !mergedExpAuto) {
            // iso switched to auto — pull exposure along with it
            merged = merged.copy(exposureMode = "auto", exposureTimeNs = null)
        } else if (mergedExpAuto && !mergedIsoAuto) {
            // exposure switched to auto — pull iso along with it
            merged = merged.copy(isoMode = "auto", iso = null)
        }

        // If one side is manual and the other is not (user only set one field),
        // auto-fill the partner from the last known AE values.  This implements "latch on
        // manual": the sensor transitions smoothly without a brightness jump because it
        // starts from the value AE was already using.
        val finalIsoManual = merged.isoMode == "manual"
        val finalExpManual = merged.exposureMode == "manual"
        if (finalIsoManual && !finalExpManual) {
            val knownExp = lastKnownExposureTimeNs
            if (knownExp == null) {
                val msg = "Cannot switch to manual ISO: no prior AE exposure value available yet. " +
                    "Provide exposureTimeNs explicitly or wait for the first capture result."
                android.util.Log.e("CambrianCamera", msg)
                mainHandler.post {
                    flutterApi.onError(handle, CamError(CamErrorCode.SETTINGS_CONFLICT, msg, false)) {}
                }
                return
            }
            android.util.Log.d("CambrianCamera", "Auto-filled exposureTimeNs=$knownExp from last AE result")
            merged = merged.copy(exposureMode = "manual", exposureTimeNs = knownExp)
        } else if (finalExpManual && !finalIsoManual) {
            val knownIso = lastKnownIso
            if (knownIso == null) {
                val msg = "Cannot switch to manual exposure: no prior AE ISO value available yet. " +
                    "Provide iso explicitly or wait for the first capture result."
                android.util.Log.e("CambrianCamera", msg)
                mainHandler.post {
                    flutterApi.onError(handle, CamError(CamErrorCode.SETTINGS_CONFLICT, msg, false)) {}
                }
                return
            }
            android.util.Log.d("CambrianCamera", "Auto-filled iso=$knownIso from last AE result")
            merged = merged.copy(isoMode = "manual", iso = knownIso.toLong())
        }

        appliedSettings = merged
        pendingSettings = merged
        val session = captureSession ?: return
        val device = cameraDevice ?: return
        val targetSurface = repeatingTargetSurface ?: gpuPipeline?.cameraSurface ?: return

        try {
            val request = buildCaptureRequest(device, merged)
            repeatingRequest = request
            if (CambrianCameraConfig.verboseDiagnostics) {
                android.util.Log.d(
                    "CambrianCamera",
                    "updateSettings request target=${describeTargetSurface(targetSurface)} " +
                        "iso=${merged.isoMode ?: "unchanged"}(${merged.iso ?: "-"}) " +
                        "exposure=${merged.exposureMode ?: "unchanged"}(${merged.exposureTimeNs ?: "-"})",
                )
            }
            session.setRepeatingRequest(request, repeatingCaptureCallback, backgroundHandler)
            if (CambrianCameraConfig.verboseSettings) {
                android.util.Log.d("CambrianCamera", buildSettingsLog(merged))
            }
        } catch (e: CameraAccessException) {
            // Non-fatal; the session may be closing. Log and ignore.
            android.util.Log.w("CameraController", "updateSettings failed: ${e.message}")
        } catch (e: IllegalStateException) {
            android.util.Log.w("CameraController", "updateSettings: session already closed")
        }
    }

    /**
     * Merges [incoming] settings into [base], returning a new [CamSettings] where
     * non-null fields from [incoming] overwrite those in [base].
     */
    private fun mergeSettings(base: CamSettings, incoming: CamSettings): CamSettings = CamSettings(
        isoMode = incoming.isoMode ?: base.isoMode,
        iso = if (incoming.isoMode != null) incoming.iso else base.iso,
        exposureMode = incoming.exposureMode ?: base.exposureMode,
        exposureTimeNs = if (incoming.exposureMode != null) incoming.exposureTimeNs else base.exposureTimeNs,
        focusMode = incoming.focusMode ?: base.focusMode,
        focusDistanceDiopters = if (incoming.focusMode != null) incoming.focusDistanceDiopters else base.focusDistanceDiopters,
        wbMode = incoming.wbMode ?: base.wbMode,
        wbGainR = if (incoming.wbMode != null) incoming.wbGainR else base.wbGainR,
        wbGainG = if (incoming.wbMode != null) incoming.wbGainG else base.wbGainG,
        wbGainB = if (incoming.wbMode != null) incoming.wbGainB else base.wbGainB,
        zoomRatio = incoming.zoomRatio ?: base.zoomRatio,
        noiseReductionMode = incoming.noiseReductionMode ?: base.noiseReductionMode,
        edgeMode = incoming.edgeMode ?: base.edgeMode,
        evCompensation = incoming.evCompensation ?: base.evCompensation,
    )

    /** Formats [settings] fields into a single log line, omitting unchanged fields. */
    private fun buildSettingsLog(settings: CamSettings): String {
        val parts = mutableListOf<String>()
        settings.isoMode?.let { mode ->
            parts += if (mode == "manual") "iso=${settings.iso}" else "iso=$mode"
        }
        settings.exposureMode?.let { mode ->
            parts += if (mode == "manual") "exposureNs=${settings.exposureTimeNs}" else "exposure=$mode"
        }
        settings.focusMode?.let { mode ->
            parts += if (mode == "manual") "focus=${String.format("%.3f", settings.focusDistanceDiopters ?: 0.0)}dpt" else "focus=$mode"
        }
        settings.wbMode?.let { mode ->
            parts += when (mode) {
                "manual" -> "wb=manual(R=${settings.wbGainR} G=${settings.wbGainG} B=${settings.wbGainB})"
                else -> "wb=$mode"
            }
        }
        settings.zoomRatio?.let { parts += "zoom=${String.format("%.2f", it)}x" }
        settings.evCompensation?.let { parts += "ev=$it" }
        return "updateSettings: ${parts.joinToString(" ")}"
    }

    /**
     * Forwards processing parameters to the GPU pipeline shader uniforms (fire-and-forget).
     * The next frame rendered by [GpuPipeline] will pick up the new values.
     *
     * @param params Image processing parameters (black balance, brightness, contrast, saturation, etc.).
     */
    fun setProcessingParams(params: CamProcessingParams) {
        lastProcessingParams = params
        if (CambrianCameraConfig.debugDataFlow) {
            android.util.Log.d("CambrianCamera", "[DataFlow] Processing params: brightness=${params.brightness} contrast=${params.contrast} saturation=${params.saturation}")
        }
        // GPU path: uniforms are updated via GpuPipeline.setAdjustments().
        // nativeSetProcessingParams is not called — the CPU pipeline is inactive.
        gpuPipeline?.setAdjustments(
            brightness = params.brightness,
            contrast   = params.contrast,
            saturation = params.saturation,
            blackR     = params.blackR,
            blackG     = params.blackG,
            blackB     = params.blackB,
            gamma      = params.gamma,
        )
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

        if (!isCaptureInFlight.compareAndSet(false, true)) {
            callback(Result.failure(FlutterError("capture_in_progress", "A capture is already in progress", null)))
            return
        }

        try {
            // Register the listener BEFORE triggering capture so the image can never
            // arrive before the listener is installed (eliminating the race condition).
            jpegReader.setOnImageAvailableListener({ reader ->
                // One-shot: clear immediately so teardown / a subsequent capture don't re-fire.
                reader.setOnImageAvailableListener(null, null)
                val image: Image? = try { reader.acquireNextImage() } catch (_: Exception) { null }
                if (image == null) {
                    isCaptureInFlight.set(false)
                    mainHandler.post { callback(Result.failure(FlutterError("capture_failed", "Failed to acquire JPEG image", null))) }
                    return@setOnImageAvailableListener
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
                    isCaptureInFlight.set(false)
                }
            }, backgroundHandler)

            val jpegRequest =
                device
                    .createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
                    .apply {
                        addTarget(jpegReader.surface)
                    }.build()

            session.capture(jpegRequest, null, backgroundHandler)
        } catch (e: CameraAccessException) {
            isCaptureInFlight.set(false)
            jpegReader.setOnImageAvailableListener(null, null) // clear listener on failure
            callback(Result.failure(FlutterError("camera_access_error", e.message, null)))
        } catch (e: Exception) {
            // Ensure we always clear the in-flight flag and listener on any other failure
            isCaptureInFlight.set(false)
            jpegReader.setOnImageAvailableListener(null, null)
            callback(Result.failure(FlutterError("capture_failed", e.message, null)))
        }
    }

    /**
     * Returns the opaque native pipeline pointer for direct JNI interop, or null if
     * the pipeline has not yet been initialised (i.e. before [open] completes).
     *
     * @param callback Invoked with the native pointer, or null when not ready.
     */
    fun getNativePipelineHandle(callback: (Result<Long?>) -> Unit) {
        callback(Result.success(if (nativePipelinePtr != 0L) nativePipelinePtr else null))
    }

    /**
     * Starts a video recording session.
     *
     * Prepares the [VideoRecorder], starts encoding into a MediaStore file, and adds
     * the encoder's input surface to the Camera2 session so the camera HAL writes frames
     * directly to the encoder via the hardware path. The callback is invoked on the main
     * thread with the content URI of the output file on success, or a [FlutterError] on
     * failure.
     *
     * @param callback Invoked with the content URI string on success, or a failure.
     */
    /**
     * Rebuilds and resubmits the repeating capture request using the current [appliedSettings]
     * and [isRecording] state. Call after toggling [isRecording] so Camera2 switches between
     * [CameraDevice.TEMPLATE_PREVIEW] and [CameraDevice.TEMPLATE_RECORD].
     */
    private fun rebuildRepeatingRequest() {
        val session = captureSession ?: return
        val device = cameraDevice ?: return
        if (repeatingTargetSurface == null && gpuPipeline?.cameraSurface == null) return
        try {
            val request = buildCaptureRequest(device, appliedSettings)
            repeatingRequest = request
            session.setRepeatingRequest(request, repeatingCaptureCallback, backgroundHandler)
        } catch (e: CameraAccessException) {
            android.util.Log.w("CameraController", "rebuildRepeatingRequest failed: ${e.message}")
        } catch (e: IllegalStateException) {
            android.util.Log.w("CameraController", "rebuildRepeatingRequest: session already closed")
        }
    }

    fun startRecording(outputDirectory: String? = null, fileName: String? = null, bitrate: Int? = null, fps: Int? = null, callback: (Result<String>) -> Unit) {
        backgroundHandler.post {
            if (state != State.STREAMING || isRecording) {
                mainHandler.post {
                    callback(Result.failure(FlutterError("invalid_state", "Cannot start recording: camera not streaming or already recording", null)))
                }
                return@post
            }
            try {
                if (videoRecorder == null) {
                    videoRecorder = VideoRecorder(context)
                }
                val configuredFps = fps ?: 30
                videoRecorder!!.prepare(previewWidth, previewHeight, bitrate = bitrate ?: 50_000_000, fps = configuredFps)
                val surface = videoRecorder!!.inputSurface
                    ?: throw IllegalStateException("VideoRecorder.inputSurface is null after prepare()")
                val uri = videoRecorder!!.start(outputDirectory, fileName)
                // Route tone-mapped GPU frames directly to the encoder (no CPU copy).
                gpuPipeline?.setEncoderSurface(surface)
                // isRecording guards startRecording/stopRecording re-entry.
                // Store fps so createRepeatingRequestBuilder aligns AE fps range with encoder.
                recordingFps = configuredFps
                isRecording = true
                // Switch Camera2 to TEMPLATE_RECORD for video-optimised settings.
                rebuildRepeatingRequest()
                mainHandler.post { callback(Result.success(uri)) }
            } catch (e: Exception) {
                mainHandler.post {
                    callback(Result.failure(FlutterError("recording_start_failed", e.message, null)))
                }
            }
        }
    }

    /**
     * Stops the active video recording and finalizes the output file.
     *
     * Signals end-of-stream to the encoder, waits for the drain thread to finish, then
     * finalizes the MediaStore entry and removes the encoder surface from the Camera2
     * session. The callback is invoked on the main thread with the content URI of the
     * finalized file.
     *
     * @param callback Invoked with the content URI string on success, or a failure.
     */
    fun stopRecording(callback: (Result<String>) -> Unit) {
        backgroundHandler.post {
            if (!isRecording) {
                mainHandler.post {
                    callback(Result.failure(FlutterError("invalid_state", "Cannot stop recording: no recording in progress", null)))
                }
                return@post
            }
            val recorder = videoRecorder ?: run {
                mainHandler.post {
                    callback(Result.failure(FlutterError("invalid_state", "VideoRecorder unexpectedly null", null)))
                }
                return@post
            }
            isRecording = false
            // Revert Camera2 to TEMPLATE_PREVIEW now that recording has stopped.
            rebuildRepeatingRequest()
            // Detach encoder surface from GPU pipeline before stopping the codec.
            gpuPipeline?.setEncoderSurface(null)
            val uri = try {
                recorder.stop()
            } catch (e: Exception) {
                mainHandler.post {
                    callback(Result.failure(FlutterError("recording_failed", e.message, null)))
                }
                return@post
            }
            mainHandler.post { callback(Result.success(uri)) }
        }
    }

    /**
     * Tears down all resources without emitting state events.
     *
     * Called by the plugin on engine detach. Use [close] for orderly user-initiated shutdown.
     */
    fun release() {
        released = true
        teardown()
        backgroundThread.quitSafely()
    }

    // -------------------------------------------------------------------------
    // Internal: session setup
    // -------------------------------------------------------------------------

    /**
     * Starts a Camera2 [CaptureSession] on the already-opened [cameraDevice].
     *
     * Initialises a [GpuPipeline] that wraps a SurfaceTexture (OES) and a GL render thread.
     * A separate JPEG [ImageReader] is pre-allocated for still capture.
     *
     * Frame path: Camera2 → GpuPipeline (OES → GL render → PBO readback) → ImagePipeline sinks
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
        detectedYuvFormat = YUV_FORMAT_UNKNOWN

        previewWidth = streamWidth
        previewHeight = streamHeight
        if (CambrianCameraConfig.debugDataFlow) {
            android.util.Log.i("CambrianCamera", "[DataFlow] Stream resolution: ${streamWidth}x${streamHeight} (4:3=${streamWidth * 3 == streamHeight * 4})")
        }
        surfaceProducer.setSize(streamWidth, streamHeight)
        if (enableRawStream && rawSurfaceProducer != null) {
            rawW = (streamWidth.toFloat() / streamHeight * rawStreamHeight + 0.5f).toInt() and 1.inv()
            rawH = rawStreamHeight
            rawSurfaceProducer.setSize(rawW, rawH)
        } else {
            rawW = 0
            rawH = 0
        }
        android.util.Log.i("CambrianCamera", "Camera stream resolution selected: ${streamWidth}x$streamHeight")

        // JPEG ImageReader — pre-allocated for still capture (use streaming resolution).
        val jpegReader = ImageReader.newInstance(streamWidth, streamHeight, ImageFormat.JPEG, 1)
        jpegImageReader = jpegReader

        // Pass null: ImagePipeline is used only for sink dispatch in the GPU path.
        // GpuRenderer owns the preview surface via EGL.
        nativePipelinePtr = nativeInit(null, streamWidth, streamHeight)
        if (nativePipelinePtr == 0L) {
            android.util.Log.e("CambrianCamera", "startCaptureSession: nativeInit failed — aborting session startup")
            jpegImageReader = null
            jpegReader.close()
            mainHandler.post {
                openCallback(Result.failure(FlutterError("init_failed", "Native pipeline init failed", null)))
            }
            return
        }

        // GPU pipeline — SurfaceTexture receives camera frames as an OES texture;
        // GpuPipeline renders each frame on its GL thread and delivers RGBA to pipeline sinks.
        val rawPreviewSurface = if (enableRawStream) rawSurfaceProducer?.getSurface() else null
        val pipeline = GpuPipeline(
            streamWidth, streamHeight,
            surfaceProducer.getSurface(),
            rawPreviewSurface, rawW, rawH,
            context,
            nativePipelinePtr
        )
        pipeline.start()
        gpuPipeline = pipeline

        // Replay any previously set processing params so they survive pipeline recreation.
        lastProcessingParams?.let { setProcessingParams(it) }

        val gpuSurface = pipeline.cameraSurface
        if (gpuSurface == null) {
            android.util.Log.e("CambrianCamera", "startCaptureSession: GPU init failed — camera surface is null")
            gpuPipeline = null
            pipeline.stop()
            synchronized(pipelineLock) {
                val ptr = nativePipelinePtr
                if (ptr != 0L) {
                    nativePipelinePtr = 0L
                    nativeRelease(ptr)
                }
            }
            jpegImageReader = null
            jpegReader.close()
            mainHandler.post {
                openCallback(Result.failure(FlutterError("gpu_init_failed", "GPU pipeline init failed", null)))
            }
            return
        }
        val surfaces = listOf(gpuSurface, jpegReader.surface)

        repeatingTargetSurface = gpuSurface

        val outputs = surfaces.map { OutputConfiguration(it) }
        device.createCaptureSession(
            SessionConfiguration(
                SessionConfiguration.SESSION_REGULAR,
                outputs,
                { command -> backgroundHandler.post(command) },
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        android.util.Log.i("CambrianCamera", "Camera session configured: ${previewWidth}x$previewHeight")
                        captureSession = session
                        try {
                            val settings = pendingSettings
                            val request =
                                if (settings != null) {
                                    buildCaptureRequest(device, settings)
                                } else {
                                    buildDefaultCaptureRequest(device)
                                }
                            repeatingRequest = request
                            if (CambrianCameraConfig.verboseDiagnostics) {
                                android.util.Log.d(
                                    "CambrianCamera",
                                    "setRepeatingRequest target=${describeTargetSurface(repeatingTargetSurface)} " +
                                        "initialIso=${settings?.isoMode ?: "default"}(${settings?.iso ?: "-"}) " +
                                        "initialExposure=${settings?.exposureMode ?: "default"}(${settings?.exposureTimeNs ?: "-"})",
                                )
                            }
                            session.setRepeatingRequest(request, repeatingCaptureCallback, backgroundHandler)
                            setState(State.STREAMING)
                            emitState("streaming")
                            mainHandler.post { openCallback(Result.success(handle)) }
                        } catch (e: CameraAccessException) {
                            handleNonFatalError(CamErrorCode.CAMERA_ACCESS_ERROR, e.message ?: "CameraAccessException")
                            mainHandler.post { openCallback(Result.failure(FlutterError(CamErrorCode.CAMERA_ACCESS_ERROR.name, e.message, null))) }
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        handleNonFatalError(CamErrorCode.CONFIGURATION_FAILED, "CaptureSession configuration failed")
                        mainHandler.post {
                            openCallback(
                                Result.failure(FlutterError(CamErrorCode.CONFIGURATION_FAILED.name, "Session configuration failed", null)),
                            )
                        }
                    }
                },
            ),
        )
    }

    /**
     * Detects the YUV interleaving layout by inspecting plane strides.
     *
     * Camera2 YUV_420_888 is device-agnostic and doesn't advertise its internal layout
     * directly. We infer it from pixelStride and the relative sizes of the U and V buffers:
     * - pixelStride == 1 → I420 (planar, separate U and V planes)
     * - pixelStride == 2 and V buffer larger → NV21 (V starts 1 byte before U in memory)
     * - pixelStride == 2 otherwise → NV12 (U starts 1 byte before V in memory)
     */
    private fun detectYuvFormat(image: android.media.Image): Int {
        val uPlane = image.planes[1]
        val vPlane = image.planes[2]
        return when {
            uPlane.pixelStride == 1 -> YUV_FORMAT_I420
            vPlane.buffer.remaining() > uPlane.buffer.remaining() -> YUV_FORMAT_NV21
            else -> YUV_FORMAT_NV12
        }
    }

    private fun yuvFormatName(format: Int): String = when (format) {
        YUV_FORMAT_NV21 -> "NV21"
        YUV_FORMAT_NV12 -> "NV12"
        YUV_FORMAT_I420 -> "I420"
        else -> "UNKNOWN($format)"
    }

    /**
     * Queries the device's supported YUV_420_888 output sizes and returns the largest 4:3 one.
     *
     * 4:3 is preferred because the sensor's native aspect ratio is 4:3 on most Android devices,
     * giving the highest-quality output without cropping. Falls back to 1280×960 (also 4:3) if
     * the device does not advertise any 4:3 YUV sizes.
     *
     * @return Triple of (format, width, height).
     */
    private fun resolveStreamFormat(device: CameraDevice): Triple<Int, Int, Int> {
        val chars = cameraManager.getCameraCharacteristics(device.id)
        val configMap = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        // Filter to 4:3: most sensors have a 4:3 active pixel array (SENSOR_INFO_ACTIVE_ARRAY_SIZE).
        // Non-4:3 output sizes crop that area, discarding live pixels. The largest 4:3 YUV size
        // = full sensor utilisation. getOutputSizes() is the authoritative valid-size list;
        // any size from it is guaranteed accepted by createCaptureSession.
        val largest = configMap
            ?.getOutputSizes(ImageFormat.YUV_420_888)
            ?.filter { it.width * 3 == it.height * 4 }
            ?.maxByOrNull { it.width.toLong() * it.height }
        return if (largest != null) {
            Triple(ImageFormat.YUV_420_888, largest.width, largest.height)
        } else {
            Triple(ImageFormat.YUV_420_888, 1280, 960)
        }
    }

    // -------------------------------------------------------------------------
    // Internal: CaptureRequest builders
    // -------------------------------------------------------------------------

    /**
     * Creates a [CaptureRequest.Builder] for repeating preview or recording requests.
     *
     * Uses [CameraDevice.TEMPLATE_RECORD] when [isRecording] is true (correct template for
     * video capture), otherwise [CameraDevice.TEMPLATE_PREVIEW] for continuous streaming.
     * (TEMPLATE_ZERO_SHUTTER_LAG is designed for still-capture pipelines, not preview.)
     *
     * Sets [CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE] to match the encoder fps when
     * recording, or the highest sustained preview rate otherwise.  Without this, Camera2's
     * AE algorithm is free to ramp exposure time beyond 1/fps s, dropping frames.
     *
     * The returned builder already has [gpuPipeline]?.cameraSurface added as target
     * (so the GPU OES SurfaceTexture receives camera frames) and [CaptureRequest.CONTROL_MODE_AUTO]
     * applied. When recording, the encoder [VideoRecorder.persistentSurface] is also added
     * as a target. The JPEG [jpegImageReader] is intentionally excluded — it is targeted only
     * by the one-shot request in [takePicture].
     */
    private fun createRepeatingRequestBuilder(
        device: CameraDevice,
    ): CaptureRequest.Builder {
        val template = if (isRecording) CameraDevice.TEMPLATE_RECORD else CameraDevice.TEMPLATE_PREVIEW
        val builder = device.createCaptureRequest(template)

        // Camera2 targets the GpuPipeline's SurfaceTexture; the GL thread renders
        // each OES frame and delivers RGBA to pipeline sinks.
        gpuPipeline?.cameraSurface?.let { builder.addTarget(it) }
        builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)

        // Anti-banding: constrain AE exposure choices to safe multiples of the mains
        // flicker period to prevent a moving horizontal band artifact under artificial
        // lighting (rolling shutter × light flicker mismatch).
        builder.set(CaptureRequest.CONTROL_AE_ANTIBANDING_MODE, CaptureRequest.CONTROL_AE_ANTIBANDING_MODE_AUTO)

        val chars = cameraManager.getCameraCharacteristics(device.id)
        val fpsRanges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
        if (fpsRanges != null && fpsRanges.isNotEmpty()) {
            val best = if (isRecording) {
                // Recording: use [targetFps/2, targetFps] so AE can lower fps in dark scenes
                // rather than blowing out exposure, while the upper bound matches the encoder
                // fps so AE exposure choices stay frame-aligned with the container framerate.
                val targetFps = recordingFps
                val halfFps = targetFps / 2
                fpsRanges.firstOrNull { it.lower == halfFps && it.upper == targetFps }
                    ?: fpsRanges.firstOrNull { it.upper == targetFps }
                    ?: fpsRanges.minWithOrNull(compareBy({ it.lower }, { it.upper }))!!
            } else {
                // Preview: lock to the highest sustained fps so the live feed doesn't stutter.
                fpsRanges.maxWithOrNull(
                    compareBy({ it.lower }, { if (it.lower == it.upper) 1 else 0 })
                )!!
            }
            builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, best)
            android.util.Log.d("CambrianCamera", "AE fps range: [${best.lower}, ${best.upper}] (recording=$isRecording)")
        }

        return builder
    }

    /**
     * Builds a default repeating [CaptureRequest] (auto-everything).
     */
    private fun buildDefaultCaptureRequest(
        device: CameraDevice,
    ): CaptureRequest =
        createRepeatingRequestBuilder(device)
            .apply {
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            }.build()

    /**
     * Builds a repeating [CaptureRequest] populated from [settings], targeting [surface].
     *
     * Auto-capable settings use mode strings:
     * - `"auto"` — let Camera2 control the parameter (template default).
     * - `"manual"` — apply the companion value field.
     * - `null` — field was not included; since [settings] is already merged via
     *   [mergeSettings], null here means the setting was never set at all.
     *
     * Non-auto settings apply their value directly when non-null.
     */
    private fun buildCaptureRequest(
        device: CameraDevice,
        settings: CamSettings,
    ): CaptureRequest =
        createRepeatingRequestBuilder(device)
            .apply {

                // CONTROL_AE_MODE must be OFF for SENSOR_SENSITIVITY and SENSOR_EXPOSURE_TIME
                // to take effect — Camera2 ignores both keys when AE is running.
                val wantsManualAe = settings.isoMode == "manual" || settings.exposureMode == "manual"
                val wantsAutoAe   = settings.isoMode == "auto"   || settings.exposureMode == "auto"
                when {
                    wantsManualAe -> set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_OFF)
                    wantsAutoAe   -> set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                    // both null: don't touch AE_MODE — preserve whatever the template set
                }

                // ISO: "auto" = AE controls, "manual" = fixed value.
                when (settings.isoMode) {
                    "manual" -> settings.iso?.let { set(CaptureRequest.SENSOR_SENSITIVITY, it.toInt()) }
                    "auto", null -> { /* don't set → template default (AE controls ISO) */ }
                    else -> android.util.Log.w("CambrianCamera", "Unknown isoMode: ${settings.isoMode}")
                }

                // Exposure time: "auto" = AE controls, "manual" = fixed value.
                when (settings.exposureMode) {
                    "manual" -> settings.exposureTimeNs?.let { set(CaptureRequest.SENSOR_EXPOSURE_TIME, it) }
                    "auto", null -> { /* don't set → template default (AE controls shutter) */ }
                    else -> android.util.Log.w("CambrianCamera", "Unknown exposureMode: ${settings.exposureMode}")
                }

                // Focus: "auto" = continuous AF, "manual" = fixed distance.
                when (settings.focusMode) {
                    "manual" -> {
                        settings.focusDistanceDiopters?.let {
                            set(CaptureRequest.LENS_FOCUS_DISTANCE, it.toFloat())
                        }
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                    }
                    "auto" -> {
                        set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
                    }
                    null -> { /* don't set → template default (continuous AF) */ }
                    else -> android.util.Log.w("CambrianCamera", "Unknown focusMode: ${settings.focusMode}")
                }

                // White balance: "auto" = AWB, "locked" = freeze, "manual" = user gains.
                when (settings.wbMode) {
                    "auto" -> {
                        set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_AUTO)
                        set(CaptureRequest.CONTROL_AWB_LOCK, false)
                    }
                    "locked" -> {
                        set(CaptureRequest.CONTROL_AWB_LOCK, true)
                    }
                    "manual" -> {
                        set(CaptureRequest.CONTROL_AWB_MODE, CaptureRequest.CONTROL_AWB_MODE_OFF)
                        val gainR = (settings.wbGainR ?: 1.0).toFloat()
                        val gainG = (settings.wbGainG ?: 1.0).toFloat()
                        val gainB = (settings.wbGainB ?: 1.0).toFloat()
                        set(
                            CaptureRequest.COLOR_CORRECTION_MODE,
                            CaptureRequest.COLOR_CORRECTION_MODE_TRANSFORM_MATRIX,
                        )
                        // RggbChannelVector takes four args: R, G_even, G_odd, B.
                        // The RGGB Bayer pattern has two green photosites (one per row of
                        // the 2×2 tile). Most sensors have symmetric green response so the
                        // same gainG is used for both — this is correct, not a copy-paste error.
                        set(
                            CaptureRequest.COLOR_CORRECTION_GAINS,
                            android.hardware.camera2.params.RggbChannelVector(gainR, gainG, gainG, gainB),
                        )
                    }
                    null -> { /* don't set → template default (AWB auto) */ }
                    else -> android.util.Log.w("CambrianCamera", "Unknown wbMode: ${settings.wbMode}")
                }

                // Zoom — use CONTROL_ZOOM_RATIO on API 30+, fall back to SCALER_CROP_REGION.
                settings.zoomRatio?.let { zoom ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        set(CaptureRequest.CONTROL_ZOOM_RATIO, zoom.toFloat())
                    } else {
                        applyZoomViaCropRegion(this, zoom)
                    }
                }

                // Noise reduction mode
                settings.noiseReductionMode?.let {
                    set(CaptureRequest.NOISE_REDUCTION_MODE, it.toInt())
                }

                // Edge enhancement mode
                settings.edgeMode?.let { set(CaptureRequest.EDGE_MODE, it.toInt()) }

                // EV compensation — only applied by Camera2 when CONTROL_AE_MODE != OFF.
                // Has no effect when isoMode or exposureMode is "manual" (AE is disabled).
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

    // -------------------------------------------------------------------------
    // Internal: resource teardown
    // -------------------------------------------------------------------------

    /**
     * Closes all Camera2 resources and resets internal references.
     *
     * Safe to call from any state. Does NOT emit state events (callers must do that).
     */
    private fun teardown() {
        // Stop any active recording before tearing down the session.
        if (isRecording) {
            isRecording = false
            gpuPipeline?.setEncoderSurface(null)
            try { videoRecorder?.stop() } catch (e: Exception) {
                android.util.Log.w("CambrianCamera", "teardown: error stopping recording: ${e.message}")
            }
            mainHandler.post { flutterApi.onRecordingStateChanged(handle, "error") {} }
        }

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
            gpuPipeline?.stop()
        } catch (_: Exception) {
        }
        gpuPipeline = null

        try {
            jpegImageReader?.close()
        } catch (_: Exception) {
        }
        jpegImageReader = null
        repeatingTargetSurface = null
        streamFrameCount = 0L
        captureResultCount = 0L
        detectedYuvFormat = YUV_FORMAT_UNKNOWN
        lastKnownIso = null
        lastKnownExposureTimeNs = null

        // Release native pipeline; pipelineLock guards nativeRelease against concurrent
        // startup/shutdown (nativeDeliverYuv is not called in the GPU path).
        synchronized(pipelineLock) {
            val ptr = nativePipelinePtr
            if (ptr != 0L) {
                nativePipelinePtr = 0L
                nativeRelease(ptr)
            }
        }

        videoRecorder?.release()
        videoRecorder = null
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
        code: CamErrorCode,
        message: String,
    ) {
        if (state == State.ERROR) return // Already in a terminal state.

        setState(State.RECOVERING)
        emitState("recovering")
        mainHandler.post { flutterApi.onError(handle, CamError(code, message, false)) {} }

        if (retryCount >= maxRetries) {
            handleFatalError(CamErrorCode.MAX_RETRIES_EXCEEDED, "Camera failed after $maxRetries retries")
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
                handleFatalError(CamErrorCode.PERMISSION_DENIED, "Camera permission lost during recovery")
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
                            startCaptureSession {}
                        }

                        override fun onDisconnected(camera: CameraDevice) {
                            openLock.release()
                            camera.close()
                            cameraDevice = null
                            handleNonFatalError(CamErrorCode.CAMERA_DISCONNECTED, "Camera disconnected during recovery")
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
                    handleFatalError(CamErrorCode.CAMERA_ACCESS_ERROR, e.message ?: "CameraAccessException")
                } else {
                    handleNonFatalError(CamErrorCode.CAMERA_ACCESS_ERROR, e.message ?: "CameraAccessException")
                }
            } catch (e: InterruptedException) {
                // Lock acquire interrupted; give up gracefully.
            } catch (e: SecurityException) {
                openLock.release()
                handleFatalError(CamErrorCode.PERMISSION_DENIED, e.message ?: "SecurityException")
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
        code: CamErrorCode,
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
                // Always track the latest sensor values so that switching to manual mode
                // can seed the partner field with the last live AE value.
                result.get(CaptureResult.SENSOR_SENSITIVITY)?.let { lastKnownIso = it }
                result.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let { lastKnownExposureTimeNs = it }

                captureResultCount++

                // Send actual sensor values to Dart at ~3 Hz (every 10th result at 30 fps).
                if (captureResultCount % 10L == 0L) {
                    val afState = result.get(CaptureResult.CONTROL_AF_STATE)
                    // Only report focus distance when AF has locked — during PASSIVE_SCAN the
                    // HAL reports raw lens-sweep positions, not the subject distance, which
                    // causes the focus dial to thrash. Emit null during scanning so the UI
                    // stays at the last locked value.
                    val afLocked = afState == CaptureResult.CONTROL_AF_STATE_PASSIVE_FOCUSED ||
                        afState == CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED
                    val focusDist = if (afLocked) result.get(CaptureResult.LENS_FOCUS_DISTANCE) else null
                    val wbGains = result.get(CaptureResult.COLOR_CORRECTION_GAINS)
                    val frameResult = CamFrameResult(
                        iso = result.get(CaptureResult.SENSOR_SENSITIVITY)?.toLong(),
                        exposureTimeNs = result.get(CaptureResult.SENSOR_EXPOSURE_TIME),
                        focusDistanceDiopters = focusDist?.toDouble(),
                        wbGainR = wbGains?.red?.toDouble(),
                        wbGainG = wbGains?.let { (it.greenEven.toDouble() + it.greenOdd.toDouble()) / 2.0 },
                        wbGainB = wbGains?.blue?.toDouble(),
                    )
                    mainHandler.post { flutterApi.onFrameResult(handle, frameResult) {} }
                }

                if (!CambrianCameraConfig.verboseDiagnostics) return
                if (captureResultCount != 1L && captureResultCount % 60L != 0L) return
                val aeMode = result.get(CaptureResult.CONTROL_AE_MODE)
                val aeState = result.get(CaptureResult.CONTROL_AE_STATE)
                android.util.Log.d(
                    "CambrianCamera",
                    "capture result#$captureResultCount target=${describeTargetSurface(repeatingTargetSurface)} " +
                        "aeMode=$aeMode aeState=$aeState iso=$lastKnownIso exposureNs=$lastKnownExposureTimeNs",
                )
            }
        }

    private fun describeTargetSurface(surface: Surface?): String {
        val gpuSurface = gpuPipeline?.cameraSurface
        return when {
            surface == null -> "null"
            gpuSurface != null && surface === gpuSurface -> "gpuPipeline"
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
    private fun errorCodeToMessage(error: Int): Pair<CamErrorCode, String> =
        when (error) {
            CameraDevice.StateCallback.ERROR_CAMERA_IN_USE      -> Pair(CamErrorCode.CAMERA_IN_USE,       "Camera is already in use")
            CameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE -> Pair(CamErrorCode.MAX_CAMERAS_IN_USE,  "Too many cameras are open")
            CameraDevice.StateCallback.ERROR_CAMERA_DISABLED    -> Pair(CamErrorCode.CAMERA_DISABLED,     "Camera disabled by policy")
            CameraDevice.StateCallback.ERROR_CAMERA_DEVICE      -> Pair(CamErrorCode.CAMERA_DEVICE,       "Fatal camera device error")
            CameraDevice.StateCallback.ERROR_CAMERA_SERVICE     -> Pair(CamErrorCode.CAMERA_SERVICE,      "Camera service error")
            else                                                -> Pair(CamErrorCode.UNKNOWN,              "Unknown camera error: $error")
        }
}
