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
import android.hardware.camera2.CaptureFailure
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
import android.util.Log
import android.util.Range
import android.util.Rational
import android.util.Size
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.io.File
import java.io.FileOutputStream
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
 * - Provides [captureNaturalPicture] (hardware ISP JPEG, no post-processing) and
 *   [captureImage] (GPU post-processed frame from the C++ pipeline, JPEG or PNG).
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

        /** Initialises the native ImagePipeline and returns an opaque handle. */
        @JvmStatic external fun nativeInit(): Long

        /**
         * Backward-compatible overload used by instrumentation tests.
         * The [previewSurface], [width], and [height] parameters are accepted for API
         * compatibility but are not forwarded to the native layer (the pipeline is
         * headless at init time; surfaces are bound later via [GpuPipeline.nativeGpuInit]).
         */
        @JvmStatic
        fun nativeInit(previewSurface: android.view.Surface?, width: Int, height: Int): Long =
            nativeInit()

        /** Releases all resources held by the native pipeline. */
        @JvmStatic external fun nativeRelease(pipelinePtr: Long)

        // Self-healing thresholds
        /** Number of consecutive HAL REASON_ERROR failures before triggering recovery. */
        const val HAL_ERROR_THRESHOLD = 5
        /** FPS below this value for [LOW_FPS_STREAK_LIMIT] heartbeats triggers a degradation alert. */
        const val LOW_FPS_THRESHOLD = 15.0
        /** Number of consecutive low-FPS heartbeats before emitting [CamErrorCode.FPS_DEGRADED]. */
        const val LOW_FPS_STREAK_LIMIT = 3
        /** Milliseconds AE may stay in SEARCHING before emitting [CamErrorCode.AE_CONVERGENCE_TIMEOUT]. */
        const val AE_CONVERGENCE_TIMEOUT_MS = 5000L
    }

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------

    /** Internal camera lifecycle state. */
    private enum class State { CLOSED, OPENING, STREAMING, RECOVERING, PAUSED, ERROR }

    @Volatile private var state: State = State.CLOSED

    /** True once [close] or [release] has been called. The instance must not be reused. */
    @Volatile private var released = false

    /**
     * True while the app is in the background (between [backgroundSuspend] and [backgroundResume]).
     *
     * When true, recovery retries are suppressed — there is no point reopening a camera that we
     * intentionally released so that other apps can use it. [handleNonFatalError] checks this flag
     * and returns immediately without scheduling a retry. [startCaptureSession] also checks it to
     * handle the race where an in-flight [openCamera] completes after we have already suspended.
     */
    @Volatile private var backgroundSuspended = false

    /**
     * True when Dart has explicitly called [pause] and has not yet called [resume].
     *
     * Tracks Dart-side intent so that [backgroundResume] does not wastefully reopen the camera
     * when the user is on a non-camera screen.  If Dart paused the camera (e.g. user navigated
     * away from the camera page), then the app goes to background and returns, [backgroundResume]
     * sees this flag and skips the reopen — Dart will call [resume] when the user navigates back.
     */
    @Volatile private var dartPaused = false

    // -------------------------------------------------------------------------
    // Camera2 resources
    // -------------------------------------------------------------------------

    private val cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    /**
     * Monitors camera availability system-wide.
     *
     * When our camera is preempted by a higher-priority client (incoming call, another app in
     * multi-window) and our retry loop exhausts [maxRetries], we enter [State.ERROR] — a terminal
     * state that the retry loop cannot escape.  This callback provides the escape hatch: when the
     * camera becomes available again, we reset [retryCount] and trigger a fresh [doReopenCamera].
     *
     * Registered once when the controller is first opened; unregistered on [close] / [release].
     */
    private val cameraAvailabilityCallback = object : CameraManager.AvailabilityCallback() {
        override fun onCameraAvailable(cameraId: String) {
            if (cameraId != resolvedCameraId) return
            if (released || backgroundSuspended || dartPaused) return
            if (state != State.ERROR) return
            Log.i("CC/Cam", "[$handle] camera $cameraId available again — recovering from ERROR")
            backgroundHandler.post {
                if (released || backgroundSuspended || dartPaused) return@post
                if (state != State.ERROR) return@post
                retryCount = 0
                doReopenCamera()
            }
        }
    }

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
     * Ensures [nativeRelease] does not run concurrently with pipeline init or GPU dispatch.
     */
    private val pipelineLock = Any()

    /** Last processing params applied via [setProcessingParams]; replayed after pipeline recreation. */
    @Volatile private var lastProcessingParams: CamProcessingParams? = null

    /** Persists capture settings and processing params across full process restarts. */
    private val settingsStore = SettingsStore(context)

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

    /** Capture-result counter used for periodic diagnostics. */
    @Volatile private var captureResultCount: Long = 0L

    // Accessed only from backgroundHandler thread via CaptureCallback — no synchronization needed.
    /** Per-interval capture failure counter (reset after each heartbeat). */
    private var captureFailureCount = 0L

    /** Per-interval buffer-lost counter (reset after each heartbeat). */
    private var bufferLostCount = 0L

    /** Consecutive HAL capture errors (REASON_ERROR); reset on any successful frame. */
    private var consecutiveHalErrors = 0

    /** FPS degradation streak: number of consecutive heartbeats with FPS below threshold. */
    private var lowFpsStreak = 0

    /** Timestamp (elapsedRealtime ms) when AE entered SEARCHING; 0 when not searching. */
    private var aeSearchingStartMs = 0L

    // 3A state tracking for Tier 1 state-change logs
    @Volatile private var lastAeState: Int? = null
    @Volatile private var lastAfState: Int? = null
    @Volatile private var lastAwbState: Int? = null

    /**
     * Last sensor values reported by Camera2 capture results.
     * Updated on every frame from the latest TotalCaptureResult.
     * Used to seed manual mode when the user switches one field to manual —
     * the partner is initialised to the last live AE value so exposure is continuous.
     */
    @Volatile private var lastKnownIso: Int? = null
    @Volatile private var lastKnownExposureTimeNs: Long? = null

    // Additional capture-result fields used for EXIF metadata in captureImage().
    @Volatile private var lastKnownFocalLengthMm: Float? = null
    @Volatile private var lastKnownAperture: Float? = null          // f-number, e.g. 1.8
    @Volatile private var lastKnownFocusDistanceDiopters: Float? = null
    @Volatile private var lastKnownWbGainR: Float? = null
    @Volatile private var lastKnownWbGainG: Float? = null           // average of greenEven + greenOdd
    @Volatile private var lastKnownWbGainB: Float? = null

    // -------------------------------------------------------------------------
    // Frame stall watchdog
    // -------------------------------------------------------------------------

    /** Timestamp (elapsedRealtime ms) of the last successful capture result; 0 before first frame. */
    @Volatile private var lastCaptureResultMs: Long = 0L
    private val stallCheckIntervalMs = 3_000L
    private val stallTimeoutMs       = 5_000L

    private val stallWatchdog = object : Runnable {
        override fun run() {
            if (released || state != State.STREAMING) return
            val elapsed = android.os.SystemClock.elapsedRealtime() - lastCaptureResultMs
            if (elapsed > stallTimeoutMs) {
                Log.w("CC/Cam", "[$handle] Frame stall detected: ${elapsed}ms — triggering recovery")
                handleNonFatalError(CamErrorCode.PIPELINE_ERROR, "Frame delivery stalled (${elapsed}ms)")
                // Watchdog does not re-post itself here. Recovery always routes through
                // startCaptureSession(), which re-posts the watchdog after entering STREAMING.
                return
            }
            backgroundHandler.postDelayed(this, stallCheckIntervalMs)
        }
    }

    // -------------------------------------------------------------------------
    // Auto-recovery
    // -------------------------------------------------------------------------

    private var retryCount = 0
    private val maxRetries = 5

    /** Exponential backoff delays indexed by retry count (capped at index 4). */
    private val backoffDelaysMs = longArrayOf(500, 1_000, 2_000, 4_000, 8_000)

    /** Pending recovery retry runnable, stored so [backgroundSuspend] can cancel it explicitly. */
    private var pendingRetryRunnable: Runnable? = null

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
                    val width = previewWidth
                    val height = previewHeight
                    Log.i("CC/Cam", "surface available ${width}×${height}")
                    if (width > 0 && height > 0) {
                        surfaceProducer.setSize(width, height)
                    }
                    // Rebind the GPU renderer's processed preview EGL surface so the
                    // preview resumes after Flutter recreates the SurfaceProducer surface.
                    gpuPipeline?.rebindPreviewSurface(surfaceProducer.getSurface())
                }

                override fun onSurfaceCleanup() {
                    Log.i("CC/Cam", "surface cleanup")
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

        // Merge incoming settings with any persisted settings from a previous session.
        // Incoming settings (from Dart open() call) take priority; persisted values fill in
        // any fields not explicitly set, so the user's last-known configuration is restored
        // across a full process kill.
        val persisted = if (settingsStore.hasSavedSettings()) settingsStore.loadSettings() else CamSettings()
        val merged = if (settings != null) mergeSettings(persisted, settings) else persisted
        pendingSettings = merged
        appliedSettings = merged
        // Restore processing params from previous session if not yet set.
        if (lastProcessingParams == null && settingsStore.hasSavedProcessingParams()) {
            lastProcessingParams = settingsStore.loadProcessingParams()
        }
        resolvedCameraId = cameraId ?: selectDefaultCameraId()

        val id = resolvedCameraId
        if (id == null) {
            callback(Result.failure(FlutterError("no_camera", "No camera device found on this device", null)))
            return
        }

        // Register once so we learn when the camera becomes available after preemption.
        // Safe to call repeatedly — CameraManager de-duplicates the same callback instance.
        cameraManager.registerAvailabilityCallback(cameraAvailabilityCallback, backgroundHandler)

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
                        if (retryCount > 0) {
                            Log.i("CC/Cam", "device reopened after recovery (retries=$retryCount)")
                        } else {
                            Log.i("CC/Cam", "device opened")
                        }
                        retryCount = 0 // Reset backoff counter on successful open.
                        startCaptureSession(safeCallback)
                    }

                    override fun onDisconnected(camera: CameraDevice) {
                        openLock.release()
                        camera.close()
                        cameraDevice = null
                        Log.w("CC/Cam", "device disconnected")
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
                        Log.e("CC/Cam", "device error=$error fatal=$fatal")
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
            // Some OEMs throw SecurityException from openCamera() immediately after the keyguard
            // is dismissed even though the app still holds CAMERA permission. Treat this as
            // non-fatal so the recovery loop retries; a second attempt typically succeeds.
            // A genuine permission denial surfaces as CameraAccessException(CAMERA_DISABLED) or
            // checkSelfPermission failure earlier in this method, so retrying is safe here.
            handleNonFatalError(CamErrorCode.CAMERA_ACCESS_ERROR, "SecurityException on camera open (transient): ${e.message}")
            safeCallback(Result.failure(FlutterError(CamErrorCode.CAMERA_ACCESS_ERROR.name, e.message, null)))
        }
    }

    /**
     * Pauses the camera: tears down the capture session and Camera2 resources
     * without marking the controller as released. The instance can be resumed
     * with [resume].
     *
     * Emits a "paused" state event to Dart.
     */
    fun pause(callback: (Result<Unit>) -> Unit) {
        if (state != State.STREAMING) {
            callback(Result.success(Unit))
            return
        }
        Log.i("CC/Cam", "[$handle] pausing (Dart-initiated)")
        dartPaused = true
        // Tear down only the capture session; keep CameraDevice open for fast resume.
        // OPENING reuses its existing meaning: "device held, no capture session running".
        setState(State.OPENING)
        teardownSession()
        // NOTE: do NOT set released=true and do NOT quit backgroundThread — instance stays alive
        emitState("paused")
        callback(Result.success(Unit))
    }

    /**
     * Resumes the camera after [pause]: restarts the capture session on the already-open
     * [CameraDevice]. Much faster than a full reopen.
     *
     * No-op if the controller is not in [State.OPENING] (i.e. not currently paused or the
     * HAL already closed the device — in that case [onDisconnected] transitions to RECOVERING).
     */
    fun resume(callback: (Result<Unit>) -> Unit) {
        dartPaused = false
        // If the controller was background-suspended while Dart-paused, the device is fully
        // closed.  A lightweight session restart is not possible — do a full reopen instead.
        if (backgroundSuspended) {
            Log.i("CC/Cam", "[$handle] resume after background suspend — full reopen")
            backgroundSuspended = false
            retryCount = 0
            backgroundHandler.post { doReopenCamera() }
            callback(Result.success(Unit))
            return
        }
        if (state != State.OPENING || cameraDevice == null) {
            // Not in a paused state or device was lost — if ERROR, availability callback
            // will handle recovery; otherwise nothing to do.
            callback(Result.success(Unit))
            return
        }
        Log.i("CC/Cam", "[$handle] resuming")
        startCaptureSession { result ->
            result.fold(
                onSuccess = { callback(Result.success(Unit)) },
                onFailure = { e -> callback(Result.failure(e)) },
            )
        }
    }

    /**
     * Fully releases the camera device and all resources when the app moves to the background
     * (process [onStop]).
     *
     * Unlike [pause], which kept the [CameraDevice] open for fast session restart, this does a
     * full [teardown] so that other apps (phone dialler, system camera, etc.) can acquire the
     * camera while we are invisible. The controller instance remains alive and can be reopened
     * via [backgroundResume] when the app returns to the foreground.
     *
     * Setting [backgroundSuspended] before changing state ensures that any in-flight
     * [handleNonFatalError] retry or [startCaptureSession] call that races with us will see
     * the flag and abort cleanly.
     */
    fun backgroundSuspend(callback: (Result<Unit>) -> Unit) {
        if (released) {
            callback(Result.success(Unit))
            return
        }
        backgroundHandler.post {
            if (released) {
                mainHandler.post { callback(Result.success(Unit)) }
                return@post
            }
            Log.i("CC/Cam", "[$handle] backgroundSuspend — fully releasing camera device")
            backgroundSuspended = true
            // Explicitly cancel any pending recovery retry so it cannot fire after we teardown.
            pendingRetryRunnable?.let { backgroundHandler.removeCallbacks(it) }
            pendingRetryRunnable = null
            // Transition to CLOSED before teardown so that any postDelayed recovery callback
            // that fires while teardown runs sees state != RECOVERING and aborts.
            setState(State.CLOSED)
            teardown()
            emitState("suspended")
            mainHandler.post { callback(Result.success(Unit)) }
        }
    }

    /**
     * Reopens the camera when the app returns to the foreground (process [onStart]).
     *
     * Performs a full [CameraDevice] open — identical to the initial [open] flow — so the
     * camera is available to other apps in between. Extra startup latency is acceptable; the
     * rest of the app is unaffected because the reopen happens entirely on the background thread
     * and errors feed into the existing non-fatal recovery path.
     *
     * No-op if the controller was never suspended, has been permanently released, or if Dart
     * had explicitly [pause]d the camera before the app went to background (Dart will call
     * [resume] when it is ready for frames again — no point streaming to a hidden screen).
     */
    fun backgroundResume(callback: (Result<Unit>) -> Unit) {
        if (released) {
            callback(Result.success(Unit))
            return
        }
        backgroundHandler.post {
            if (released || !backgroundSuspended) {
                mainHandler.post { callback(Result.success(Unit)) }
                return@post
            }
            if (dartPaused) {
                // Dart explicitly paused the camera before the app went to background.
                // Stay suspended — Dart will call resume() when it is ready for frames.
                Log.i("CC/Cam", "[$handle] backgroundResume skipped — Dart-paused")
                mainHandler.post { callback(Result.success(Unit)) }
                return@post
            }
            Log.i("CC/Cam", "[$handle] backgroundResume — reopening camera")
            backgroundSuspended = false
            // Fresh lifecycle transition — reset backoff so a transient open failure does not
            // immediately hit maxRetries because of a stale count from a pre-background error.
            retryCount = 0
            // Callback returns immediately; the reopen is fire-and-forget from the caller's
            // perspective. State/error events flow to Dart via the existing Pigeon callbacks.
            mainHandler.post { callback(Result.success(Unit)) }
            doReopenCamera()
        }
    }

    fun close(callback: (Result<Unit>) -> Unit) {
        released = true
        cameraManager.unregisterAvailabilityCallback(cameraAvailabilityCallback)
        // Post teardown to backgroundHandler so it serialises with any in-flight
        // backgroundSuspend / recovery work, avoiding concurrent teardown on two threads.
        backgroundHandler.post {
            teardown()
            backgroundThread.quitSafely()
            mainHandler.post {
                emitState("closed")
                setState(State.CLOSED)
                callback(Result.success(Unit))
            }
        }
    }

    /**
     * Pauses the camera session by tearing down Camera2 resources without closing the controller.
     *
     * If a recording is in progress it is stopped first to avoid leaving the recorder running
     * with no incoming frames. Emits a "paused" state event to Dart after teardown completes.
     */
    fun pause() {
        backgroundHandler.post {
            if (isRecording) {
                Log.w("CC/Cam", "[$handle] auto-stopping recording before pause")
                isRecording = false
                gpuPipeline?.setEncoderSurface(null)
                try { videoRecorder?.stop() } catch (e: Exception) {
                    Log.w("CC/Cam", "recording stop on pause failed: ${e.message}")
                }
                mainHandler.post { flutterApi.onRecordingStateChanged(handle, "idle") {} }
            }
            teardown()
            mainHandler.post {
                emitState("paused")
                setState(State.CLOSED)
            }
        }
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
                Log.e("CC/Settings", msg)
                mainHandler.post {
                    flutterApi.onError(handle, CamError(CamErrorCode.SETTINGS_CONFLICT, msg, false)) {}
                }
                return
            }
            Log.d("CC/Settings", "Auto-filled exposureTimeNs=$knownExp from last AE result")
            merged = merged.copy(exposureMode = "manual", exposureTimeNs = knownExp)
        } else if (finalExpManual && !finalIsoManual) {
            val knownIso = lastKnownIso
            if (knownIso == null) {
                val msg = "Cannot switch to manual exposure: no prior AE ISO value available yet. " +
                    "Provide iso explicitly or wait for the first capture result."
                Log.e("CC/Settings", msg)
                mainHandler.post {
                    flutterApi.onError(handle, CamError(CamErrorCode.SETTINGS_CONFLICT, msg, false)) {}
                }
                return
            }
            Log.d("CC/Settings", "Auto-filled iso=$knownIso from last AE result")
            merged = merged.copy(isoMode = "manual", iso = knownIso.toLong())
        }

        val prevSettings = appliedSettings
        appliedSettings = merged
        pendingSettings = merged
        settingsStore.saveSettings(merged)
        val session = captureSession ?: return
        val device = cameraDevice ?: return
        val targetSurface = repeatingTargetSurface ?: gpuPipeline?.cameraSurface ?: return

        try {
            val request = buildCaptureRequest(device, merged)
            repeatingRequest = request
            session.setRepeatingRequest(request, repeatingCaptureCallback, backgroundHandler)
            if (merged != prevSettings) {
                Log.i("CC/Settings", "iso=${merged.isoMode}:${merged.iso ?: "-"} exp=${merged.exposureMode}:${fmtExpMs(merged.exposureTimeNs)} focus=${merged.focusMode}:${merged.focusDistanceDiopters ?: "-"} wb=${merged.wbMode} zoom=${merged.zoomRatio ?: "-"}")
            }
            if (CambrianCameraConfig.verboseSettings) {
                Log.d("CC/Settings", buildSettingsLog(merged))
            }
        } catch (e: CameraAccessException) {
            // Non-fatal; the session may be closing. Log and ignore.
            Log.w("CC/Cam", "updateSettings failed: ${e.message}")
        } catch (e: IllegalStateException) {
            Log.w("CC/Cam", "updateSettings: session already closed")
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
     * Returns persisted processing params from a previous session, or null if none were saved.
     * Called by Dart to initialize slider UI with last-known values.
     */
    fun getPersistedProcessingParams(): CamProcessingParams? =
        if (settingsStore.hasSavedProcessingParams()) settingsStore.loadProcessingParams() else null

    /**
     * Forwards processing parameters to the GPU pipeline shader uniforms (fire-and-forget).
     * The next frame rendered by [GpuPipeline] will pick up the new values.
     *
     * @param params Image processing parameters (black balance, brightness, contrast, saturation, etc.).
     */
    fun setProcessingParams(params: CamProcessingParams) {
        lastProcessingParams = params
        settingsStore.saveProcessingParams(params)
        if (CambrianCameraConfig.debugDataFlow) {
            Log.d("CC/Cam", "Processing params: brightness=${params.brightness} contrast=${params.contrast} saturation=${params.saturation}")
        }
        // Uniforms are updated via GpuPipeline.setAdjustments(); the GPU shader handles all transforms.
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
     * Captures a still JPEG image using Camera2's hardware ISP ImageReader.
     *
     * **Important:** This method bypasses the GPU post-processing pipeline. The resulting image
     * reflects raw ISP output — no LUT, color transforms (saturation, contrast, brightness,
     * black-level, gamma) or other adjustments applied by [GpuPipeline] are present.
     * Use this when you need the highest-fidelity hardware-encoded JPEG.
     *
     * For a post-processed image that matches what the user sees on screen, use [captureImage].
     *
     * Captures via the pre-allocated JPEG [ImageReader], acquires the next image on a
     * background thread, and writes the bytes to `<cacheDir>/capture_<timestamp>.jpg`.
     *
     * @param callback Invoked with the absolute file path on success, or a [FlutterError].
     */
    fun captureNaturalPicture(callback: (Result<String>) -> Unit) {
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
     * Captures the next GPU post-processed full-resolution RGBA frame from the C++ pipeline,
     * encodes it as JPEG or PNG, saves it to disk, and writes EXIF metadata.
     *
     * Format is inferred from the [fileName] extension:
     * - `.jpg` / `.jpeg` → JPEG (quality 90)
     * - `.png` or absent / unrecognised extension → PNG (lossless)
     *
     * The default output directory is the app-specific Pictures folder
     * ([Context.getExternalFilesDir] with [android.os.Environment.DIRECTORY_PICTURES]).
     * No additional storage permissions are required on API 33+.
     *
     * EXIF metadata (ISO, exposure time, focal length, aperture, WB gains, orientation,
     * and capture timestamp) is written using [androidx.exifinterface.media.ExifInterface]
     * after the file has been successfully encoded. Metadata fields are best-effort:
     * if a value was not reported by the hardware, the corresponding EXIF tag is omitted.
     *
     * @param outputDirectory Absolute path to the target directory, or null for the default.
     * @param fileName        Filename including extension, or null for a timestamped default.
     * @param callback        Invoked with the absolute file path on success, or a [FlutterError].
     */
    fun captureImage(
        outputDirectory: String?,
        fileName: String?,
        callback: (Result<String>) -> Unit,
    ) {
        val pipelinePtr = nativePipelinePtr
        if (pipelinePtr == 0L) {
            callback(Result.failure(FlutterError("not_streaming", "Pipeline not initialized", null)))
            return
        }

        backgroundHandler.post {
            // Resolve output directory: use caller-supplied path or default to app Pictures folder.
            val dir = if (outputDirectory != null) {
                File(outputDirectory).also { it.mkdirs() }
            } else {
                context.getExternalFilesDir(android.os.Environment.DIRECTORY_PICTURES)
                    ?: context.cacheDir
            }

            // Resolve filename; default to PNG with a timestamp if omitted or extension-less.
            val ts = System.currentTimeMillis()
            val resolvedName = when {
                fileName.isNullOrBlank()   -> "capture_$ts.png"
                !fileName.contains('.')    -> "$fileName.png"
                else                       -> fileName
            }
            val lowerName = resolvedName.lowercase(java.util.Locale.ROOT)
            // JPEG quality 90: good perceptual quality with reasonable file size.
            val jpegQuality = 90

            val file = File(dir, resolvedName)
            val errorMsg = nativeCaptureImage(pipelinePtr, file.absolutePath, jpegQuality)

            if (errorMsg.isNotEmpty()) {
                mainHandler.post {
                    callback(Result.failure(FlutterError("capture_failed", errorMsg, null)))
                }
                return@post
            }

            // Write EXIF metadata. ExifInterface supports JPEG and PNG on API 31+;
            // minSdk is 33 so this is always safe.
            if (lowerName.endsWith(".jpg") || lowerName.endsWith(".jpeg") || lowerName.endsWith(".png")) {
                try {
                    writeExifMetadata(file)
                } catch (e: Exception) {
                    // Non-fatal: the image file is already saved. Log and continue.
                    Log.w("CC/Cam", "[$handle] captureImage: failed to write EXIF — ${e.message}")
                }
            }

            mainHandler.post { callback(Result.success(file.absolutePath)) }
        }
    }

    /**
     * Writes available capture-result metadata into [file] as EXIF tags.
     *
     * All fields are best-effort: if the hardware did not report a value in recent
     * capture results, the corresponding EXIF tag is omitted rather than zeroed.
     */
    private fun writeExifMetadata(file: File) {
        // android.media.ExifInterface supports JPEG and PNG on API 31+; minSdk is 33.
        val exif = android.media.ExifInterface(file.absolutePath)

        // Exposure time in seconds (stored as decimal string per ExifInterface spec).
        lastKnownExposureTimeNs?.let { ns ->
            val secs = ns / 1_000_000_000.0
            exif.setAttribute(android.media.ExifInterface.TAG_EXPOSURE_TIME, secs.toString())
        }

        // ISO sensitivity.
        lastKnownIso?.let { iso ->
            exif.setAttribute(android.media.ExifInterface.TAG_ISO_SPEED_RATINGS, iso.toString())
        }

        // Focal length as a rational: "numerator/denominator" (millimetres × 1000 / 1000).
        lastKnownFocalLengthMm?.let { fl ->
            exif.setAttribute(android.media.ExifInterface.TAG_FOCAL_LENGTH,
                "${(fl * 1000).toInt()}/1000")
        }

        // f-number (aperture).
        lastKnownAperture?.let { ap ->
            exif.setAttribute(android.media.ExifInterface.TAG_F_NUMBER, ap.toString())
        }

        // White-balance gains stored as JSON in UserComment (no standard EXIF WB-gains tag exists).
        lastKnownWbGainR?.let { r ->
            val g = lastKnownWbGainG ?: 1f
            val b = lastKnownWbGainB ?: 1f
            exif.setAttribute(android.media.ExifInterface.TAG_USER_COMMENT,
                """{"wb":{"r":$r,"g":$g,"b":$b}}""")
        }

        // Orientation derived from the current display rotation.
        @Suppress("DEPRECATION")
        val displayRot = when (
            (context.getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager)
                .defaultDisplay.rotation
        ) {
            android.view.Surface.ROTATION_90  ->  90
            android.view.Surface.ROTATION_180 -> 180
            android.view.Surface.ROTATION_270 -> 270
            else                              ->   0
        }
        val orientationTag = when (displayRot) {
            90  -> android.media.ExifInterface.ORIENTATION_ROTATE_90
            180 -> android.media.ExifInterface.ORIENTATION_ROTATE_180
            270 -> android.media.ExifInterface.ORIENTATION_ROTATE_270
            else -> android.media.ExifInterface.ORIENTATION_NORMAL
        }
        exif.setAttribute(android.media.ExifInterface.TAG_ORIENTATION, orientationTag.toString())

        // Capture timestamp in EXIF datetime format "YYYY:MM:DD HH:MM:SS".
        val sdf = java.text.SimpleDateFormat("yyyy:MM:dd HH:mm:ss", java.util.Locale.US)
        exif.setAttribute(android.media.ExifInterface.TAG_DATETIME_ORIGINAL,
            sdf.format(java.util.Date()))

        exif.saveAttributes()
    }

    /** JNI: request the next full-res RGBA frame from the C++ pipeline, encode, and save. */
    private external fun nativeCaptureImage(pipelinePtr: Long, outputPath: String, jpegQuality: Int): String

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
            Log.w("CC/Cam", "rebuildRepeatingRequest failed: ${e.message}")
        } catch (e: IllegalStateException) {
            Log.w("CC/Cam", "rebuildRepeatingRequest: session already closed")
        }
    }

    /**
     * Starts a video recording session.
     *
     * Prepares the [VideoRecorder], starts encoding into a MediaStore file, and routes
     * tone-mapped GPU frames to the encoder via [GpuPipeline.setEncoderSurface]. The
     * callback is invoked on the main thread with the content URI of the output file on
     * success, or a [FlutterError] on failure.
     *
     * @param outputDirectory MediaStore RELATIVE_PATH (e.g. "Movies/MyApp/"); defaults to "Movies/CambrianCamera/".
     * @param fileName        Display name without extension; ".mp4" is appended automatically.
     * @param bitrate         Target encoder bitrate in bits/s; defaults to 50 Mbps.
     * @param fps             Target encoder frame rate; defaults to 30 fps.
     * @param callback        Invoked with the content URI string on success, or a failure.
     */
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
                val result = videoRecorder!!.start(outputDirectory, fileName)
                // Route tone-mapped GPU frames directly to the encoder (no CPU copy).
                gpuPipeline?.setEncoderSurface(surface)
                // isRecording guards startRecording/stopRecording re-entry.
                // Store fps so createRepeatingRequestBuilder aligns AE fps range with encoder.
                recordingFps = configuredFps
                isRecording = true
                // Switch Camera2 to TEMPLATE_RECORD for video-optimised settings.
                rebuildRepeatingRequest()
                // Encode as "uri|displayName" for the Dart layer to split on the first '|'.
                mainHandler.post { callback(Result.success("${result.uri}|${result.displayName}")) }
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
            if (recorder.wasEosDrainTimedOut()) {
                Log.w("CC/Cam", "recording may be truncated (EOS drain timeout)")
                mainHandler.post {
                    flutterApi.onError(handle, CamError(
                        CamErrorCode.RECORDING_TRUNCATED,
                        "Recording may be truncated — EOS drain timed out",
                        false
                    )) {}
                }
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
        Log.i("CC/Cam", "release handle=$handle")
        released = true
        cameraManager.unregisterAvailabilityCallback(cameraAvailabilityCallback)
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
        // Guard against the race where an in-flight openCamera() completes after backgroundSuspend()
        // has already run. Close the device we just received and return without starting a session —
        // backgroundResume() will trigger a fresh open when the user returns.
        if (backgroundSuspended || released) {
            Log.i("CC/Cam", "[$handle] startCaptureSession: suppressed (backgroundSuspended=$backgroundSuspended released=$released)")
            cameraDevice?.close()
            cameraDevice = null
            return
        }

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
        captureResultCount = 0L
        captureFailureCount = 0L
        bufferLostCount = 0L

        previewWidth = streamWidth
        previewHeight = streamHeight
        if (CambrianCameraConfig.debugDataFlow) {
            Log.i("CC/Cam", "Stream resolution: ${streamWidth}x${streamHeight} (4:3=${streamWidth * 3 == streamHeight * 4})")
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
        Log.i("CC/Cam", "streaming fmt=YUV_420_888 ${streamWidth}×${streamHeight}")

        // JPEG ImageReader — pre-allocated for still capture (use streaming resolution).
        val jpegReader = ImageReader.newInstance(streamWidth, streamHeight, ImageFormat.JPEG, 1)
        jpegImageReader = jpegReader

        // ImagePipeline is used only for sink dispatch in the GPU path.
        // GpuRenderer owns the preview surface via EGL.
        nativePipelinePtr = nativeInit()
        if (nativePipelinePtr == 0L) {
            Log.e("CC/Cam", "startCaptureSession: nativeInit failed — aborting session startup")
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
        pipeline.onStallDetected = { elapsedMs ->
            Log.w("CC/Cam", "frame stall reported: ${elapsedMs}ms")
            mainHandler.post {
                flutterApi.onError(handle, CamError(CamErrorCode.FRAME_STALL, "Frame stall: ${elapsedMs}ms since last frame", false)) {}
            }
        }
        pipeline.onPreviewRebindNeeded = {
            Log.i("CC/Cam", "rebinding preview surface after swap failures")
            val newSurface = surfaceProducer?.getSurface()
            if (newSurface != null) {
                pipeline.rebindPreviewSurface(newSurface)
            } else {
                Log.w("CC/Cam", "no surface available for rebind")
            }
        }

        // Replay any previously set processing params so they survive pipeline recreation.
        lastProcessingParams?.let { setProcessingParams(it) }

        val gpuSurface = pipeline.cameraSurface
        if (gpuSurface == null) {
            Log.e("CC/Cam", "startCaptureSession: GPU init failed — camera surface is null")
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
                        Log.i("CC/Cam", "session configured ${previewWidth}×$previewHeight")
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
                            session.setRepeatingRequest(request, repeatingCaptureCallback, backgroundHandler)
                            setState(State.STREAMING)
                            emitState("streaming")
                            // Start the frame stall watchdog now that streaming is active.
                            lastCaptureResultMs = android.os.SystemClock.elapsedRealtime()
                            backgroundHandler.postDelayed(stallWatchdog, stallCheckIntervalMs)
                            mainHandler.post { openCallback(Result.success(handle)) }
                        } catch (e: CameraAccessException) {
                            handleNonFatalError(CamErrorCode.CAMERA_ACCESS_ERROR, e.message ?: "CameraAccessException")
                            mainHandler.post { openCallback(Result.failure(FlutterError(CamErrorCode.CAMERA_ACCESS_ERROR.name, e.message, null))) }
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        val surfaceDesc = surfaces.joinToString { describeTargetSurface(it) }
                        Log.e("CC/Cam", "session configure failed: surfaces=[$surfaceDesc] preview=${previewWidth}×${previewHeight}")
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
     * applied. Encoder output is routed via [GpuPipeline.setEncoderSurface] rather than as a
     * Camera2 session target. The JPEG [jpegImageReader] is intentionally excluded — it is
     * targeted only by the one-shot request in [captureNaturalPicture].
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
            Log.d("CC/3A", "AE fps range: [${best.lower}, ${best.upper}] (recording=$isRecording)")
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
                    else -> Log.w("CC/Settings", "Unknown isoMode: ${settings.isoMode}")
                }

                // Exposure time: "auto" = AE controls, "manual" = fixed value.
                when (settings.exposureMode) {
                    "manual" -> settings.exposureTimeNs?.let { set(CaptureRequest.SENSOR_EXPOSURE_TIME, it) }
                    "auto", null -> { /* don't set → template default (AE controls shutter) */ }
                    else -> Log.w("CC/Settings", "Unknown exposureMode: ${settings.exposureMode}")
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
                    else -> Log.w("CC/Settings", "Unknown focusMode: ${settings.focusMode}")
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
                    else -> Log.w("CC/Settings", "Unknown wbMode: ${settings.wbMode}")
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
     * Tears down the capture session and GPU/native pipeline, but **keeps [cameraDevice] open**.
     *
     * Used by [pause] to cheaply release the session when the app backgrounds, so that
     * [resume] can restart the session without the latency of reopening the camera device.
     *
     * If the HAL closes the device while paused, the existing [CameraDevice.StateCallback.onDisconnected]
     * callback fires → [handleNonFatalError] → full recovery.
     */
    private fun teardownSession() {
        backgroundHandler.removeCallbacks(stallWatchdog)

        // Thread-safety note: Camera2's captureSession.close() and imageReader.close() are
        // thread-safe per the Camera2 API contract. Callbacks running on backgroundHandler
        // null-check captureSession/imageReader before use, so the race is benign.
        // This mirrors the pattern in teardown() (pre-existing design decision).
        try { captureSession?.close() } catch (_: Exception) {}
        captureSession = null

        try { imageReader?.close() } catch (_: Exception) {}
        imageReader = null

        try { gpuPipeline?.stop() } catch (_: Exception) {}
        gpuPipeline = null

        try { jpegImageReader?.close() } catch (_: Exception) {}
        jpegImageReader = null
        repeatingTargetSurface = null
        lastCaptureResultMs = 0L
        captureResultCount = 0L

        synchronized(pipelineLock) {
            val ptr = nativePipelinePtr
            if (ptr != 0L) {
                nativePipelinePtr = 0L
                nativeRelease(ptr)
            }
        }
    }

    /**
     * Closes all Camera2 resources and marks this controller as released.
     * After this call the controller cannot be reused.
     */
    private fun teardown() {
        backgroundHandler.removeCallbacks(stallWatchdog)

        // Stop any active recording before tearing down the session.
        if (isRecording) {
            Log.w("CC/Cam", "[$handle] stopping active recording during teardown")
            isRecording = false
            gpuPipeline?.setEncoderSurface(null)
            try { videoRecorder?.stop() } catch (e: Exception) {
                Log.w("CC/Cam", "recording stop on teardown failed: ${e.message}")
            }
            mainHandler.post { flutterApi.onRecordingStateChanged(handle, "idle") {} }
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
        captureResultCount = 0L
        captureFailureCount = 0L
        bufferLostCount = 0L
        consecutiveHalErrors = 0
        lowFpsStreak = 0
        aeSearchingStartMs = 0L
        lastKnownIso = null
        lastKnownExposureTimeNs = null
        lastKnownFocalLengthMm = null
        lastKnownAperture = null
        lastKnownFocusDistanceDiopters = null
        lastKnownWbGainR = null
        lastKnownWbGainG = null
        lastKnownWbGainB = null
        lastAeState = null
        lastAfState = null
        lastAwbState = null

        // Release native pipeline; pipelineLock guards nativeRelease against concurrent
        // startup/shutdown.
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

        // App is intentionally in the background — we released the camera voluntarily so other
        // apps can use it. Suppress recovery: backgroundResume() will reopen when we return.
        if (backgroundSuspended) {
            Log.d("CC/Cam", "[$handle] suppressing recovery — camera intentionally released in background")
            setState(State.CLOSED)
            return
        }

        val delayMs = backoffDelaysMs[minOf(retryCount, backoffDelaysMs.size - 1)]
        Log.w("CC/Cam", "non-fatal: code=$code msg=$message retry=${retryCount}/${maxRetries} backoff=${delayMs}ms")
        setState(State.RECOVERING)
        emitState("recovering")
        mainHandler.post { flutterApi.onError(handle, CamError(code, message, false)) {} }

        if (retryCount >= maxRetries) {
            handleFatalError(CamErrorCode.MAX_RETRIES_EXCEEDED, "Camera failed after $maxRetries retries")
            return
        }

        retryCount++

        pendingRetryRunnable?.let { backgroundHandler.removeCallbacks(it) }
        val retryRunnable = Runnable {
            pendingRetryRunnable = null
            if (resolvedCameraId == null) return@Runnable
            if (state != State.RECOVERING) return@Runnable // Cancelled by explicit close or backgroundSuspend.
            teardown()
            doReopenCamera()
        }
        pendingRetryRunnable = retryRunnable
        backgroundHandler.postDelayed(retryRunnable, delayMs)
    }

    /**
     * Performs a full [CameraDevice] open on [backgroundHandler].
     *
     * Shared by [backgroundResume] and the recovery retry loop inside [handleNonFatalError].
     * On success, transitions to STREAMING via [startCaptureSession]. On failure, routes to
     * [handleNonFatalError] or [handleFatalError] as appropriate.
     *
     * [SecurityException] is treated as non-fatal here: some OEMs throw it from [openCamera]
     * immediately after the keyguard is dismissed even though [CAMERA] permission is still
     * granted. The recovery loop will retry and the second attempt typically succeeds.
     */
    private fun doReopenCamera() {
        val id = resolvedCameraId ?: return
        if (context.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            handleFatalError(CamErrorCode.PERMISSION_DENIED, "Camera permission not granted")
            return
        }
        setState(State.OPENING)
        emitState("opening")
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
                        handleNonFatalError(CamErrorCode.CAMERA_DISCONNECTED, "Camera disconnected on resume")
                    }

                    override fun onError(camera: CameraDevice, error: Int) {
                        openLock.release()
                        camera.close()
                        cameraDevice = null
                        val (errCode, errMsg) = errorCodeToMessage(error)
                        if (isFatalDeviceError(error)) handleFatalError(errCode, errMsg)
                        else handleNonFatalError(errCode, errMsg)
                    }
                },
            )
        } catch (e: InterruptedException) {
            // Thread interrupted — give up gracefully; backgroundResume will not retry.
        } catch (e: CameraAccessException) {
            openLock.release()
            if (isFatalAccessException(e)) handleFatalError(CamErrorCode.CAMERA_ACCESS_ERROR, e.message ?: "CameraAccessException")
            else handleNonFatalError(CamErrorCode.CAMERA_ACCESS_ERROR, e.message ?: "CameraAccessException")
        } catch (e: SecurityException) {
            openLock.release()
            // OEM bug: SecurityException thrown after keyguard dismiss even with valid permission.
            // Treat as non-fatal so the recovery loop retries after a short backoff.
            handleNonFatalError(CamErrorCode.CAMERA_ACCESS_ERROR, "SecurityException on camera open (transient): ${e.message}")
        }
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
        Log.e("CC/Cam", "fatal: code=$code msg=$message")
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
            override fun onCaptureFailed(
                session: CameraCaptureSession,
                request: CaptureRequest,
                failure: CaptureFailure,
            ) {
                val reason = when (failure.reason) {
                    CaptureFailure.REASON_ERROR -> "ERROR"
                    CaptureFailure.REASON_FLUSHED -> "FLUSHED"
                    else -> "UNKNOWN(${failure.reason})"
                }
                Log.w("CC/Cam", "[$handle] capture failed: reason=$reason frame=${failure.frameNumber}")
                captureFailureCount++

                // Ignore additional HAL failures while already recovering — they would enqueue
                // duplicate recovery retries that each delay and re-open the camera.
                if (state == State.RECOVERING) {
                    Log.d("CC/Cam", "[$handle] ignoring HAL capture failure while already recovering")
                    return
                }

                // Trigger recovery on repeated HAL errors; REASON_FLUSHED is expected during
                // teardown and does not indicate a degraded HAL state.
                if (failure.reason == CaptureFailure.REASON_ERROR) {
                    consecutiveHalErrors++
                    if (consecutiveHalErrors >= HAL_ERROR_THRESHOLD) {
                        Log.w("CC/Cam", "HAL error threshold reached ($consecutiveHalErrors consecutive failures), triggering recovery")
                        consecutiveHalErrors = 0
                        handleNonFatalError(CamErrorCode.CAPTURE_FAILURE, "Repeated HAL capture failures")
                    }
                }
            }

            override fun onCaptureCompleted(
                session: CameraCaptureSession,
                request: CaptureRequest,
                result: TotalCaptureResult,
            ) {
                // Reset HAL error streak on every successful frame.
                consecutiveHalErrors = 0
                // Update stall watchdog timestamp so it knows frames are still arriving.
                lastCaptureResultMs = android.os.SystemClock.elapsedRealtime()

                // Always track the latest sensor values so that switching to manual mode
                // can seed the partner field with the last live AE value.
                result.get(CaptureResult.SENSOR_SENSITIVITY)?.let { lastKnownIso = it }
                result.get(CaptureResult.SENSOR_EXPOSURE_TIME)?.let { lastKnownExposureTimeNs = it }

                // Additional fields used for EXIF metadata in captureImage().
                result.get(CaptureResult.LENS_FOCAL_LENGTH)?.let { lastKnownFocalLengthMm = it }
                result.get(CaptureResult.LENS_APERTURE)?.let { lastKnownAperture = it }
                result.get(CaptureResult.LENS_FOCUS_DISTANCE)?.let { lastKnownFocusDistanceDiopters = it }
                result.get(CaptureResult.COLOR_CORRECTION_GAINS)?.let { gains ->
                    lastKnownWbGainR = gains.red
                    // Average the two green channels (greenEven and greenOdd from Bayer pattern)
                    lastKnownWbGainG = (gains.greenEven + gains.greenOdd) / 2f
                    lastKnownWbGainB = gains.blue
                }

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

                // Tier 1 — 3A state changes (unconditional, fires only on transitions)
                val newAeState  = result.get(CaptureResult.CONTROL_AE_STATE)
                val newAfState  = result.get(CaptureResult.CONTROL_AF_STATE)
                val newAwbState = result.get(CaptureResult.CONTROL_AWB_STATE)
                if (newAeState != lastAeState) {
                    Log.i("CC/3A", "[AE] ${aeStateName(lastAeState)} → ${aeStateName(newAeState)}  iso=${result.get(CaptureResult.SENSOR_SENSITIVITY)}  exp=${fmtExpMs(result.get(CaptureResult.SENSOR_EXPOSURE_TIME))}")
                    lastAeState = newAeState

                    // Track when AE enters SEARCHING to detect convergence timeout (Step 4).
                    if (newAeState == CaptureResult.CONTROL_AE_STATE_SEARCHING) {
                        aeSearchingStartMs = android.os.SystemClock.elapsedRealtime()
                    } else {
                        aeSearchingStartMs = 0L  // converged or locked — reset
                    }
                }

                // Check AE convergence timeout even when state hasn't changed.
                if (lastAeState == CaptureResult.CONTROL_AE_STATE_SEARCHING && aeSearchingStartMs > 0L) {
                    val elapsed = android.os.SystemClock.elapsedRealtime() - aeSearchingStartMs
                    if (elapsed >= AE_CONVERGENCE_TIMEOUT_MS) {
                        Log.w("CC/3A", "AE convergence timeout: stuck in SEARCHING for ${elapsed}ms")
                        aeSearchingStartMs = 0L  // prevent repeated firing
                        mainHandler.post {
                            flutterApi.onError(handle, CamError(
                                CamErrorCode.AE_CONVERGENCE_TIMEOUT,
                                "Auto-exposure failed to converge after ${elapsed}ms",
                                false
                            )) {}
                        }
                    }
                }

                if (newAfState != lastAfState) {
                    Log.i("CC/3A", "[AF] ${afStateName(lastAfState)} → ${afStateName(newAfState)}  focus=${result.get(CaptureResult.LENS_FOCUS_DISTANCE)?.let { "${it}D" } ?: "null"}")
                    lastAfState = newAfState
                }
                if (newAwbState != lastAwbState) {
                    Log.i("CC/3A", "[AWB] ${awbStateName(lastAwbState)} → ${awbStateName(newAwbState)}  wb=${fmtWbGains(result)}")
                    lastAwbState = newAwbState
                }

                // Tier 2 — Heartbeat (every 30 results)
                if (captureResultCount % 30L == 0L) {
                    val frameDuration = result.get(CaptureResult.SENSOR_FRAME_DURATION)
                    val fpsValue = frameDuration?.let { 1_000_000_000.0 / it }

                    // FPS degradation detection (always runs, regardless of verboseDiagnostics).
                    if (fpsValue != null && fpsValue < LOW_FPS_THRESHOLD) {
                        lowFpsStreak++
                        if (lowFpsStreak == LOW_FPS_STREAK_LIMIT) {
                            Log.w("CC/Cam", "sustained low FPS: ${"%.1f".format(fpsValue)} for $lowFpsStreak heartbeats")
                            mainHandler.post {
                                flutterApi.onError(handle, CamError(
                                    CamErrorCode.FPS_DEGRADED,
                                    "FPS degraded to ${"%.1f".format(fpsValue)} for $lowFpsStreak consecutive heartbeat intervals",
                                    false
                                )) {}
                            }
                        }
                    } else {
                        lowFpsStreak = 0
                    }

                    // Verbose heartbeat log (gated).
                    if (CambrianCameraConfig.verboseDiagnostics) {
                        val fps = fpsValue?.let { "%.1f".format(it) } ?: "?"
                        Log.d("CC/3A", "[HB #$captureResultCount] fps=$fps  ae=${aeStateName(newAeState)} iso=${result.get(CaptureResult.SENSOR_SENSITIVITY)} exp=${fmtExpMs(result.get(CaptureResult.SENSOR_EXPOSURE_TIME))}  af=${afStateName(newAfState)} focus=${result.get(CaptureResult.LENS_FOCUS_DISTANCE)?.let { "${it}D" } ?: "-"}  awb=${awbStateName(newAwbState)}  capFail=$captureFailureCount bufLost=$bufferLostCount")
                        captureFailureCount = 0L
                        bufferLostCount = 0L

                        // InputRing dimension mismatch count (Step 6).
                        val ptr = nativePipelinePtr
                        if (ptr != 0L) {
                            val mismatches = GpuPipeline.nativeGetDimensionMismatchCount(ptr)
                            if (mismatches > 0) {
                                Log.w("CC/Cam", "InputRing dimension mismatches: $mismatches since last heartbeat")
                            }
                        }
                    }
                }
                if (CambrianCameraConfig.verboseFullResult && captureResultCount % 30L == 0L) {
                    Log.d("CC/3A", "[FULL #$captureResultCount] $result")
                }
            }

            override fun onCaptureBufferLost(
                session: CameraCaptureSession,
                request: CaptureRequest,
                target: Surface,
                frameNumber: Long,
            ) {
                val surfaceName = describeTargetSurface(target)
                Log.w("CC/Cam", "buffer lost: surface=$surfaceName frame=$frameNumber")
                bufferLostCount++
            }

            override fun onCaptureSequenceAborted(
                session: CameraCaptureSession,
                sequenceId: Int,
            ) {
                Log.w("CC/Cam", "capture sequence aborted: seq=$sequenceId")
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

    private fun aeStateName(state: Int?): String = when (state) {
        CaptureResult.CONTROL_AE_STATE_INACTIVE        -> "INACTIVE"
        CaptureResult.CONTROL_AE_STATE_SEARCHING       -> "SEARCHING"
        CaptureResult.CONTROL_AE_STATE_CONVERGED       -> "CONVERGED"
        CaptureResult.CONTROL_AE_STATE_LOCKED          -> "LOCKED"
        CaptureResult.CONTROL_AE_STATE_FLASH_REQUIRED  -> "FLASH_REQ"
        CaptureResult.CONTROL_AE_STATE_PRECAPTURE      -> "PRECAPTURE"
        null                                           -> "null"
        else                                           -> "AE($state)"
    }

    private fun afStateName(state: Int?): String = when (state) {
        CaptureResult.CONTROL_AF_STATE_INACTIVE              -> "INACTIVE"
        CaptureResult.CONTROL_AF_STATE_PASSIVE_SCAN          -> "PASSIVE_SCAN"
        CaptureResult.CONTROL_AF_STATE_PASSIVE_FOCUSED       -> "PASSIVE_FOCUSED"
        CaptureResult.CONTROL_AF_STATE_ACTIVE_SCAN           -> "ACTIVE_SCAN"
        CaptureResult.CONTROL_AF_STATE_FOCUSED_LOCKED        -> "FOCUSED_LOCKED"
        CaptureResult.CONTROL_AF_STATE_NOT_FOCUSED_LOCKED    -> "NOT_FOCUSED_LOCKED"
        CaptureResult.CONTROL_AF_STATE_PASSIVE_UNFOCUSED     -> "PASSIVE_UNFOCUSED"
        null                                                 -> "null"
        else                                                 -> "AF($state)"
    }

    private fun awbStateName(state: Int?): String = when (state) {
        CaptureResult.CONTROL_AWB_STATE_INACTIVE    -> "INACTIVE"
        CaptureResult.CONTROL_AWB_STATE_SEARCHING   -> "SEARCHING"
        CaptureResult.CONTROL_AWB_STATE_CONVERGED   -> "CONVERGED"
        CaptureResult.CONTROL_AWB_STATE_LOCKED      -> "LOCKED"
        null                                        -> "null"
        else                                        -> "AWB($state)"
    }

    private fun fmtExpMs(ns: Long?): String = if (ns == null) "null" else "${ns / 1_000_000}ms"

    private fun fmtWbGains(result: TotalCaptureResult): String {
        val g = result.get(CaptureResult.COLOR_CORRECTION_GAINS) ?: return "null"
        return "[R:${"%.2f".format(g.red)} Ge:${"%.2f".format(g.greenEven)} Go:${"%.2f".format(g.greenOdd)} B:${"%.2f".format(g.blue)}]"
    }

    /** Updates internal state field and logs transitions. */
    private fun setState(newState: State) {
        val prev = state
        state = newState
        if (prev != newState) {
            Log.i("CC/Cam", "$prev → $newState")
        }
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
     * Fatal errors: [CameraDevice.ERROR_CAMERA_DISABLED] (device policy / MDM — no point retrying).
     * Non-fatal (retryable): all others, including [CameraDevice.ERROR_CAMERA_IN_USE] and
     * [CameraDevice.ERROR_MAX_CAMERAS_IN_USE] — these simply mean another app currently holds
     * the camera. The recovery loop will retry with backoff until the camera becomes available.
     */
    private fun isFatalDeviceError(error: Int): Boolean =
        error == CameraDevice.StateCallback.ERROR_CAMERA_DISABLED

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
