// Copyright (c) 2025 Cambrian. All rights reserved.
package com.cambrian.camera

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * BroadcastReceiver that handles ADB intents to start/stop video recording.
 *
 * Usage:
 *   adb shell am broadcast -a com.cambrian.camera.START_RECORDING
 *   adb shell am broadcast -a com.cambrian.camera.STOP_RECORDING
 *
 * The active [CameraController] must be registered via [activeController] before
 * broadcasts will have any effect.
 */
class VideoRecordingReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION_START = "com.cambrian.camera.START_RECORDING"
        const val ACTION_STOP  = "com.cambrian.camera.STOP_RECORDING"
        private const val TAG  = "VideoRecordingReceiver"

        /**
         * The currently active [CameraController]. Set by [CambrianCameraPlugin] when a
         * camera is opened and cleared when it is closed. Reads/writes are fine with
         * [Volatile] because the receiver only reads this field, and the plugin only
         * writes it from the main thread.
         */
        @Volatile
        var activeController: CameraController? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        val controller = activeController ?: run {
            Log.w(TAG, "onReceive: no active camera controller — ignoring ${intent.action}")
            return
        }
        when (intent.action) {
            ACTION_START -> {
                Log.i(TAG, "START_RECORDING broadcast received")
                controller.startRecording { result ->
                    result.fold(
                        onSuccess = { uri -> Log.i(TAG, "Recording started: $uri") },
                        onFailure = { e  -> Log.e(TAG, "Recording failed to start: ${e.message}") },
                    )
                }
            }
            ACTION_STOP -> {
                Log.i(TAG, "STOP_RECORDING broadcast received")
                controller.stopRecording { result ->
                    result.fold(
                        onSuccess = { uri -> Log.i(TAG, "Recording saved: $uri") },
                        onFailure = { e  -> Log.e(TAG, "Recording failed to stop: ${e.message}") },
                    )
                }
            }
            else -> Log.w(TAG, "Unknown action: ${intent.action}")
        }
    }
}
