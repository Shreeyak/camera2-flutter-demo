// Copyright (c) 2025 Cambrian. All rights reserved.
package com.cambrian.camera

/**
 * Central configuration object for the cambrian_camera plugin.
 *
 * All tuneable development and runtime settings live here so they are easy to
 * find and change without hunting through CameraController internals.
 *
 * Logging flags should be set to `false` before shipping to production to
 * prevent log spam at 30+ fps rates.
 */
object CambrianCameraConfig {
    /** Log every [CameraController.updateSettings] call (ISO, exposure, focus, zoom, etc.). */
    @Volatile var verboseSettings: Boolean = true

    /** Log frame-flow and capture-result diagnostics. */
    @Volatile var verboseDiagnostics: Boolean = true
}
