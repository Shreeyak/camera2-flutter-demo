package com.cambrian.camera

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * CambrianCameraPlugin — Flutter plugin entry point.
 *
 * Phase 1: Stub only (registers plugin, no camera logic yet).
 * Phase 2: Add ActivityAware, TextureRegistry, Pigeon host implementation.
 * Phase 3: Add CameraController and live preview.
 */
class CambrianCameraPlugin : FlutterPlugin {

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Phase 2: set up Pigeon host, TextureRegistry, etc.
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        // Phase 2: tear down resources.
    }
}
