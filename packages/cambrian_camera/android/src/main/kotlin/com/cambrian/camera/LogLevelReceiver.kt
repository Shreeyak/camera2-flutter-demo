package com.cambrian.camera

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Toggles CambrianCameraConfig logging flags via ADB broadcast.
 *
 * Usage:
 *   adb shell am broadcast -a com.cambrian.camera.SET_LOG_LEVEL --ei level 0
 *
 * Levels:
 *   0 = quiet (all flags false)
 *   1 = default (verboseSettings=true, verboseDiagnostics=true)
 *   2 = verbose (adds debugDataFlow=true)
 *   3 = full (adds verboseFullResult=true)
 */
class LogLevelReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val level = intent.getIntExtra("level", -1)
        if (level < 0) {
            Log.w(TAG, "SET_LOG_LEVEL: missing or invalid 'level' extra")
            return
        }
        CambrianCameraConfig.verboseSettings = level >= 1
        CambrianCameraConfig.verboseDiagnostics = level >= 1
        CambrianCameraConfig.debugDataFlow = level >= 2
        CambrianCameraConfig.verboseFullResult = level >= 3
        Log.i(TAG, "Log level set to $level: settings=${level >= 1} diag=${level >= 1} dataFlow=${level >= 2} fullResult=${level >= 3}")
    }

    companion object {
        private const val TAG = "CC/LogLevel"
    }
}
