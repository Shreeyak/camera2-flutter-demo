// Copyright (c) 2025 Cambrian. All rights reserved.
package com.cambrian.camera

import android.app.Activity
import android.content.Context
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.view.TextureRegistry

/**
 * Per-camera session state.
 *
 * Holds the [TextureRegistry.SurfaceProducer] whose [TextureRegistry.SurfaceProducer.id]
 * is used as the camera handle returned to Dart, and the [CameraController] that manages
 * the Camera2 lifecycle for this session.
 *
 * @property producer             Flutter texture entry backing the processed preview.
 * @property rawSurfaceProducer  Flutter texture entry backing the raw (pre-processing) preview.
 * @property controller  Camera2 lifecycle manager for this session.
 */
data class CameraSession(
    val producer: TextureRegistry.SurfaceProducer,
    val rawSurfaceProducer: TextureRegistry.SurfaceProducer?,
    val controller: CameraController,
)

/**
 * CambrianCameraPlugin — Flutter plugin entry point for the cambrian_camera package.
 *
 * Lifecycle:
 * - [onAttachedToEngine] — receives the [FlutterPlugin.FlutterPluginBinding], registers the
 *   Pigeon [CameraHostApi] handler, creates the [CameraFlutterApi], and stores the
 *   [TextureRegistry] and application context.
 * - [onDetachedFromEngine] — tears down the Pigeon handler, releases all active sessions.
 * - [onAttachedToActivity] / [onDetachedFromActivity] — keeps an [Activity] reference for
 *   camera permission checks and context.
 *
 * Delegates all [CameraHostApi] calls to [CameraController], which implements the
 * real Camera2 lifecycle and JNI bridge.
 *
 * Note: [VideoRecordingReceiver] tracks only the most recently opened camera.
 * In multi-session scenarios, ADB recording broadcasts affect that camera only.
 */
class CambrianCameraPlugin : FlutterPlugin, ActivityAware, CameraHostApi {

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /** Application context stored at engine attach time. */
    private var applicationContext: Context? = null

    /** Flutter texture registry used to create [TextureRegistry.SurfaceProducer] objects. */
    private var textureRegistry: TextureRegistry? = null

    /**
     * Pigeon-generated Flutter API used to push state/error events back to Dart.
     * Initialised in [onAttachedToEngine], cleared in [onDetachedFromEngine].
     */
    private var flutterApi: CameraFlutterApi? = null

    /** Live camera sessions, keyed by handle (= [TextureRegistry.SurfaceProducer.id]). */
    private val sessions = HashMap<Long, CameraSession>()

    /** Current activity, used as context for Camera2 and permission checks. */
    private var activity: Activity? = null

    // -------------------------------------------------------------------------
    // FlutterPlugin
    // -------------------------------------------------------------------------

    /**
     * Called when the plugin is attached to the Flutter engine.
     *
     * Stores the application context, texture registry, creates the [CameraFlutterApi],
     * and registers the Pigeon [CameraHostApi] handler.
     */
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Clean up stale sessions from a previous engine (e.g. hot restart
        // where onDetachedFromEngine didn't complete before re-attach).
        if (sessions.isNotEmpty()) {
            Log.w(TAG,
                "onAttachedToEngine: cleaning up ${sessions.size} stale session(s)")
            sessions.values.forEach { session ->
                try { session.controller.release() } catch (_: Exception) {}
                try { session.producer.release() } catch (_: Exception) {}
                try { session.rawSurfaceProducer?.release() } catch (_: Exception) {}
            }
            sessions.clear()
        }

        applicationContext = binding.applicationContext
        textureRegistry = binding.textureRegistry
        flutterApi = CameraFlutterApi(binding.binaryMessenger)
        CameraHostApi.setUp(binding.binaryMessenger, this)
        cleanOrphanedPendingEntries(binding.applicationContext)
    }

    /**
     * Deletes any [MediaStore.Video.Media.IS_PENDING] = 1 entries owned by this app.
     *
     * Called once at engine attach to clean up orphaned entries left behind if a previous
     * process was killed mid-recording before [VideoRecorder.stop] could finalise the file.
     * No-op on API levels below Q where [MediaStore.Video.Media.IS_PENDING] is unavailable.
     */
    private fun cleanOrphanedPendingEntries(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        try {
            context.contentResolver.delete(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                "${MediaStore.Video.Media.IS_PENDING} = 1 AND " +
                    "${MediaStore.Video.Media.OWNER_PACKAGE_NAME} = ?",
                arrayOf(context.packageName),
            )
        } catch (e: Exception) {
            Log.w(TAG, "cleanOrphanedPendingEntries: $e")
        }
    }

    /**
     * Called when the plugin is detached from the Flutter engine.
     *
     * Releases all active camera sessions without waiting for Dart callbacks
     * (engine is already shutting down), then clears all engine-scoped references.
     */
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        Log.i(TAG, "detached sessions=${sessions.size}")
        CameraHostApi.setUp(binding.binaryMessenger, null)
        sessions.values.forEach { session ->
            try { session.controller.release() } catch (_: Exception) {}
            try { session.producer.release() } catch (_: Exception) {}
            try { session.rawSurfaceProducer?.release() } catch (_: Exception) {}
        }
        sessions.clear()
        VideoRecordingReceiver.activeController = null
        flutterApi = null
        textureRegistry = null
        applicationContext = null
    }

    // -------------------------------------------------------------------------
    // ActivityAware
    // -------------------------------------------------------------------------

    /** Stores the activity reference when the plugin is first bound to an activity. */
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    /** Clears the activity reference when configuration changes require rebinding. */
    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    /** Restores the activity reference after a configuration change. */
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
    }

    /** Clears the activity reference when the plugin is permanently detached from the activity. */
    override fun onDetachedFromActivity() {
        activity = null
    }

    // -------------------------------------------------------------------------
    // CameraHostApi implementation
    // -------------------------------------------------------------------------

    /**
     * Opens a camera session.
     *
     * Creates a [TextureRegistry.SurfaceProducer] for the Flutter preview, constructs a
     * [CameraController], and delegates the open to it. The handle returned to Dart is the
     * [TextureRegistry.SurfaceProducer.id], which also serves as the Flutter [Texture] widget ID.
     *
     * @param cameraId Optional camera device ID string; null selects the default back camera.
     * @param settings Optional initial capture settings.
     * @param callback Invoked with [Result.success] containing the handle, or [Result.failure].
     */
    override fun open(cameraId: String?, settings: CamSettings?, callback: (Result<Long>) -> Unit) {
        val registry = textureRegistry
        val api = flutterApi
        // Prefer the activity context for permission checks; fall back to application context.
        val ctx: Context? = activity ?: applicationContext

        if (registry == null || api == null || ctx == null) {
            callback(Result.failure(FlutterError("no_engine", "Plugin not fully attached", null)))
            return
        }

        val enableRawStream = settings?.enableRawStream ?: false
        val rawStreamHeight = settings?.rawStreamHeight ?: 0L
        val producer = registry.createSurfaceProducer()
        val rawSurfaceProducer = if (enableRawStream) registry.createSurfaceProducer() else null
        val handle = producer.id()
        Log.i(TAG, "open handle=$handle cameraId=${cameraId ?: "default"}")
        val controller = CameraController(ctx, producer, rawSurfaceProducer, enableRawStream, rawStreamHeight.toInt(), api, handle)

        // Register the session immediately so that close() can tear it down even if open()
        // hasn't returned yet.  On failure, remove the session and release resources.
        sessions[handle] = CameraSession(producer, rawSurfaceProducer, controller)
        controller.open(cameraId, settings) { result ->
            if (result.isFailure) {
                sessions.remove(handle)
                try { controller.release() } catch (_: Exception) {}
                try { producer.release() } catch (_: Exception) {}
                try { rawSurfaceProducer?.release() } catch (_: Exception) {}
            } else {
                // Last-opened camera owns activeController. In multi-session scenarios,
                // ADB recording broadcasts target whichever camera was opened most recently.
                VideoRecordingReceiver.activeController = controller
            }
            callback(result)
        }
    }

    /**
     * Returns real camera capabilities by querying [android.hardware.camera2.CameraCharacteristics].
     *
     * @param handle The camera handle returned by [open].
     * @param callback Invoked with [Result.success] containing the capabilities.
     */
    override fun getCapabilities(handle: Long, callback: (Result<CamCapabilities>) -> Unit) {
        val controller = sessions[handle]?.controller
        if (controller == null) {
            callback(Result.failure(FlutterError("invalid_handle", "No session for handle $handle", null)))
            return
        }
        controller.getCapabilities(callback)
    }

    /**
     * Updates the repeating [android.hardware.camera2.CaptureRequest] with new ISP settings.
     *
     * @param handle   The camera handle.
     * @param settings The new capture settings to apply.
     */
    override fun updateSettings(handle: Long, settings: CamSettings) {
        sessions[handle]?.controller?.updateSettings(settings)
    }

    /**
     * Updates C++ pipeline processing parameters.
     *
     * Forwards parameters to the C++ image pipeline via JNI.
     *
     * @param handle The camera handle.
     * @param params The processing parameters to apply.
     */
    override fun setProcessingParams(handle: Long, params: CamProcessingParams) {
        sessions[handle]?.controller?.setProcessingParams(params)
    }

    /**
     * Captures a still JPEG image and returns its file path.
     *
     * @param handle   The camera handle.
     * @param callback Invoked with [Result.success] containing the file path.
     */
    override fun takePicture(handle: Long, callback: (Result<String>) -> Unit) {
        val controller = sessions[handle]?.controller
        if (controller == null) {
            callback(Result.failure(FlutterError("invalid_handle", "No session for handle $handle", null)))
            return
        }
        controller.takePicture(callback)
    }

    /**
     * Returns the native pipeline pointer for direct C++ consumer registration.
     *
     * @param handle   The camera handle.
     * @param callback Invoked with [Result.success] containing the native pointer (may be 0).
     */
    override fun getNativePipelineHandle(handle: Long, callback: (Result<Long?>) -> Unit) {
        val controller = sessions[handle]?.controller
        if (controller == null) {
            callback(Result.failure(FlutterError("invalid_handle", "No session for handle $handle", null)))
            return
        }
        controller.getNativePipelineHandle(callback)
    }

    /**
     * Returns the current display rotation in degrees CW from portrait: 0, 90, 180, or 270.
     *
     * Used by Dart preview widgets to select the correct [RotatedBox.quarterTurns] for
     * all four device orientations. Falls back to 0 (portrait) if activity is unavailable.
     */
    @Suppress("DEPRECATION")
    override fun getDisplayRotation(): Long {
        val rot = activity?.windowManager?.defaultDisplay?.rotation ?: return 0L
        return when (rot) {
            Surface.ROTATION_90  ->  90L
            Surface.ROTATION_180 -> 180L
            Surface.ROTATION_270 -> 270L
            else                 ->   0L
        }
    }

    /**
     * Starts a video recording session for the camera identified by [handle].
     *
     * Delegates to [CameraController.startRecording]. On success, emits a
     * "recording" state change via [CameraFlutterApi.onRecordingStateChanged].
     * On failure, emits an "error" state change before forwarding the failure.
     *
     * @param handle   The camera handle returned by [open].
     * @param callback Invoked with [Result.success] containing the output URI, or [Result.failure].
     */
    override fun startRecording(handle: Long, outputDirectory: String?, fileName: String?, bitrate: Long?, fps: Long?, callback: (Result<String>) -> Unit) {
        val session = sessions[handle] ?: run {
            callback(Result.failure(FlutterError("invalid_handle", "No camera session for handle $handle", null)))
            return
        }
        session.controller.startRecording(outputDirectory, fileName, bitrate?.toInt(), fps?.toInt()) { result ->
            // Best-effort state notification. Channel errors are discarded — the Pigeon
            // reply callback below is always invoked regardless, so no state is lost.
            result.onSuccess {
                flutterApi?.onRecordingStateChanged(handle, "recording") { }
            }
            result.onFailure {
                flutterApi?.onRecordingStateChanged(handle, "error") { }
            }
            callback(result)
        }
    }

    /**
     * Stops the active video recording session for the camera identified by [handle].
     *
     * Delegates to [CameraController.stopRecording]. On success, emits an
     * "idle" state change via [CameraFlutterApi.onRecordingStateChanged].
     * On failure, emits an "error" state change before forwarding the failure.
     *
     * @param handle   The camera handle returned by [open].
     * @param callback Invoked with [Result.success] containing the output URI, or [Result.failure].
     */
    override fun stopRecording(handle: Long, callback: (Result<String>) -> Unit) {
        val session = sessions[handle] ?: run {
            callback(Result.failure(FlutterError("invalid_handle", "No camera session for handle $handle", null)))
            return
        }
        session.controller.stopRecording { result ->
            // Best-effort state notification. Channel errors are discarded — the Pigeon
            // reply callback below is always invoked regardless, so no state is lost.
            result.onSuccess {
                flutterApi?.onRecordingStateChanged(handle, "idle") { }
            }
            result.onFailure {
                flutterApi?.onRecordingStateChanged(handle, "error") { }
            }
            callback(result)
        }
    }

    /**
     * Closes the camera session identified by [handle].
     *
     * Delegates teardown to [CameraController.close], then releases the
     * [TextureRegistry.SurfaceProducer] and removes the session from the map.
     *
     * @param handle   The camera handle previously returned by [open].
     * @param callback Invoked with [Result.success] on success, or [Result.failure] if the
     *   handle is not found.
     */
    override fun close(handle: Long, callback: (Result<Unit>) -> Unit) {
        Log.i(TAG, "close handle=$handle")
        val session = sessions.remove(handle)
        if (session == null) {
            callback(Result.failure(FlutterError("invalid_handle", "No session for handle $handle", null)))
            return
        }
        if (VideoRecordingReceiver.activeController === session.controller) {
            VideoRecordingReceiver.activeController = null
        }
        session.controller.close { result ->
            session.producer.release()
            session.rawSurfaceProducer?.release()
            callback(result)
        }
    }

    companion object {
        private const val TAG = "CC/Plugin"
    }
}
