// Copyright (c) 2025 Cambrian. All rights reserved.
package com.cambrian.camera

import android.app.Activity
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.view.TextureRegistry

/**
 * Per-camera session state.
 *
 * Holds the [TextureRegistry.SurfaceTextureEntry] whose [TextureRegistry.SurfaceTextureEntry.id]
 * is used as the camera handle returned to Dart. Phase 3 will extend this with a real
 * CameraDevice/CaptureSession once the Camera2 controller is wired in.
 *
 * @property entry The Flutter texture entry backing this camera's preview surface.
 */
data class CameraSession(
    val entry: TextureRegistry.SurfaceTextureEntry,
)

/**
 * CambrianCameraPlugin — Flutter plugin entry point for the cambrian_camera package.
 *
 * Lifecycle:
 * - [onAttachedToEngine] — receives the [FlutterPlugin.FlutterPluginBinding], registers the
 *   Pigeon [CameraHostApi] handler and stores the [TextureRegistry] reference.
 * - [onDetachedFromEngine] — tears down the Pigeon handler and releases all active sessions.
 * - [onAttachedToActivity] / [onDetachedFromActivity] — keeps an [Activity] reference available
 *   for Phase 3 (Camera2 requires an Activity context for permission checks).
 *
 * Phase 2: Stub implementation — registers the TextureRegistry, manages [CameraSession] objects,
 * and returns the texture ID as the camera handle. No real camera hardware is opened yet.
 */
class CambrianCameraPlugin : FlutterPlugin, ActivityAware, CameraHostApi {

    // -------------------------------------------------------------------------
    // State
    // -------------------------------------------------------------------------

    /** Flutter texture registry used to create [TextureRegistry.SurfaceTextureEntry] objects. */
    private var textureRegistry: TextureRegistry? = null

    /**
     * Pigeon-generated Flutter API used to push state/error events back to Dart.
     * Initialised in [onAttachedToEngine], cleared in [onDetachedFromEngine].
     */
    private var flutterApi: CameraFlutterApi? = null

    /** Live camera sessions, keyed by handle (= [TextureRegistry.SurfaceTextureEntry.id]). */
    private val sessions = HashMap<Long, CameraSession>()

    /** Current activity, kept for Phase 3 Camera2 usage. */
    private var activity: Activity? = null

    // -------------------------------------------------------------------------
    // FlutterPlugin
    // -------------------------------------------------------------------------

    /**
     * Called when the plugin is attached to the Flutter engine.
     *
     * Registers the Pigeon [CameraHostApi] handler so Dart can invoke host methods, and
     * creates the [CameraFlutterApi] used to send events back to Dart.
     */
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        textureRegistry = binding.textureRegistry
        flutterApi = CameraFlutterApi(binding.binaryMessenger)
        CameraHostApi.setUp(binding.binaryMessenger, this)
    }

    /**
     * Called when the plugin is detached from the Flutter engine.
     *
     * Clears the Pigeon handler, releases all active [CameraSession] entries, and
     * nulls out engine-scoped references.
     */
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        CameraHostApi.setUp(binding.binaryMessenger, null)
        sessions.values.forEach { it.entry.release() }
        sessions.clear()
        flutterApi = null
        textureRegistry = null
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
     * Phase 2 stub — no real Camera2 device is opened. Creates a [TextureRegistry.SurfaceTextureEntry]
     * and stores it in [sessions]. The entry's ID is the camera handle returned to Dart; Dart should
     * pass this ID to the [Texture] widget.
     *
     * Emits [CamStateUpdate]("opening") then [CamStateUpdate]("streaming") to Dart before
     * completing the callback, simulating a fast open.
     *
     * @param cameraId Optional camera device ID string (reserved for Phase 3).
     * @param settings Optional initial camera settings (reserved for Phase 3).
     * @param callback Invoked with [Result.success] containing the handle, or [Result.failure] on error.
     */
    override fun open(cameraId: String?, settings: CamSettings?, callback: (Result<Long>) -> Unit) {
        val registry = textureRegistry
        if (registry == null) {
            callback(Result.failure(FlutterError("no_engine", "TextureRegistry unavailable", null)))
            return
        }

        val entry = registry.createSurfaceTexture()
        val handle = entry.id()
        sessions[handle] = CameraSession(entry)

        // Emit opening → streaming state transitions to Dart.
        flutterApi?.onStateChanged(handle, CamStateUpdate("opening")) {}
        flutterApi?.onStateChanged(handle, CamStateUpdate("streaming")) {}

        callback(Result.success(handle))
    }

    /**
     * Returns stub camera capabilities.
     *
     * Phase 2 stub — returns hard-coded values representative of a typical modern Android camera.
     * Phase 3 will query the real CameraCharacteristics.
     *
     * @param handle The camera handle (unused in the stub).
     * @param callback Invoked with [Result.success] containing the capabilities.
     */
    override fun getCapabilities(handle: Long, callback: (Result<CamCapabilities>) -> Unit) {
        val caps = CamCapabilities(
            supportedSizes = listOf(
                CamSize(3840, 2160),  // 4K UHD
                CamSize(1920, 1080),  // 1080p
                CamSize(1280, 720),   // 720p
            ),
            isoMin = 100L,
            isoMax = 6400L,
            exposureTimeMinNs = 100_000L,          // 100 µs
            exposureTimeMaxNs = 1_000_000_000L,    // 1 s
            focusMin = 0.0,
            focusMax = 10.0,
            zoomMin = 1.0,
            zoomMax = 8.0,
            evCompMin = -6L,
            evCompMax = 6L,
            evCompensationStep = 0.5,
            supportsRgba8888 = true,
            estimatedMemoryBytes = 3840L * 2160L * 4L,  // 4K RGBA
        )
        callback(Result.success(caps))
    }

    /**
     * Updates camera capture settings.
     *
     * Phase 2 stub — no-op. Phase 3 will apply these settings to a live CaptureRequest.
     *
     * @param handle The camera handle.
     * @param settings The new capture settings to apply.
     */
    override fun updateSettings(handle: Long, settings: CamSettings) {
        // No-op stub — Phase 3 will apply settings to CaptureRequest.
    }

    /**
     * Updates the image processing parameters.
     *
     * Phase 2 stub — no-op. Phase 4 will forward these to the C++ image pipeline.
     *
     * @param handle The camera handle.
     * @param params The processing parameters to apply.
     */
    override fun setProcessingParams(handle: Long, params: CamProcessingParams) {
        // No-op stub — Phase 4 will forward params to the native image pipeline.
    }

    /**
     * Triggers a still capture.
     *
     * Phase 2 stub — returns a hard-coded placeholder path. Phase 3 will trigger a real
     * ImageReader capture and write the file.
     *
     * @param handle The camera handle.
     * @param callback Invoked with [Result.success] containing the file path.
     */
    override fun takePicture(handle: Long, callback: (Result<String>) -> Unit) {
        callback(Result.success("/stub/capture.jpg"))
    }

    /**
     * Returns the native pipeline handle for JNI interop.
     *
     * Phase 2 stub — returns 0. Phase 3/4 will return a valid native pointer or file descriptor.
     *
     * @param handle The camera handle.
     * @param callback Invoked with [Result.success] containing the native handle (0 in stub).
     */
    override fun getNativePipelineHandle(handle: Long, callback: (Result<Long>) -> Unit) {
        callback(Result.success(0L))
    }

    /**
     * Closes the camera session identified by [handle].
     *
     * Releases the associated [TextureRegistry.SurfaceTextureEntry] and removes the session
     * from [sessions]. Emits a [CamStateUpdate]("closed") event to Dart after teardown.
     *
     * @param handle The camera handle previously returned by [open].
     * @param callback Invoked with [Result.success] on success, or [Result.failure] if the
     *   handle is not found.
     */
    override fun close(handle: Long, callback: (Result<Unit>) -> Unit) {
        val session = sessions.remove(handle)
        if (session == null) {
            callback(Result.failure(FlutterError("invalid_handle", "No session for handle $handle", null)))
            return
        }
        session.entry.release()
        flutterApi?.onStateChanged(handle, CamStateUpdate("closed")) {}
        callback(Result.success(Unit))
    }
}
