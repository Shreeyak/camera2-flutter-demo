// Copyright (c) 2025 Cambrian. All rights reserved.
package com.cambrian.camera

import android.content.Context
import android.content.SharedPreferences

/**
 * Persists camera and processing settings to [SharedPreferences] so they survive a full
 * process kill. Settings are written on every change (fire-and-forget via [apply]) and
 * loaded once during [CameraController.open].
 *
 * Only ISP capture-request parameters and GPU shader adjustments are stored — not
 * transient state like recording flags or raw-stream configuration.
 */
internal class SettingsStore(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // -----------------------------------------------------------------
    // CamSettings
    // -----------------------------------------------------------------

    /** Returns true if settings have ever been persisted. */
    fun hasSavedSettings(): Boolean = prefs.contains(KEY_ISO_MODE)

    fun saveSettings(s: CamSettings) {
        prefs.edit()
            .putStringOrRemove(KEY_ISO_MODE, s.isoMode)
            .putLongOrRemove(KEY_ISO, s.iso)
            .putStringOrRemove(KEY_EXPOSURE_MODE, s.exposureMode)
            .putLongOrRemove(KEY_EXPOSURE_TIME_NS, s.exposureTimeNs)
            .putStringOrRemove(KEY_FOCUS_MODE, s.focusMode)
            .putDoubleOrRemove(KEY_FOCUS_DISTANCE, s.focusDistanceDiopters)
            .putStringOrRemove(KEY_WB_MODE, s.wbMode)
            .putDoubleOrRemove(KEY_WB_GAIN_R, s.wbGainR)
            .putDoubleOrRemove(KEY_WB_GAIN_G, s.wbGainG)
            .putDoubleOrRemove(KEY_WB_GAIN_B, s.wbGainB)
            .putDoubleOrRemove(KEY_ZOOM_RATIO, s.zoomRatio)
            .putLongOrRemove(KEY_NOISE_REDUCTION, s.noiseReductionMode)
            .putLongOrRemove(KEY_EDGE_MODE, s.edgeMode)
            .putLongOrRemove(KEY_EV_COMPENSATION, s.evCompensation)
            .apply()
    }

    fun loadSettings(): CamSettings = CamSettings(
        isoMode = prefs.getStringOrNull(KEY_ISO_MODE),
        iso = prefs.getLongOrNull(KEY_ISO),
        exposureMode = prefs.getStringOrNull(KEY_EXPOSURE_MODE),
        exposureTimeNs = prefs.getLongOrNull(KEY_EXPOSURE_TIME_NS),
        focusMode = prefs.getStringOrNull(KEY_FOCUS_MODE),
        focusDistanceDiopters = prefs.getDoubleOrNull(KEY_FOCUS_DISTANCE),
        wbMode = prefs.getStringOrNull(KEY_WB_MODE),
        wbGainR = prefs.getDoubleOrNull(KEY_WB_GAIN_R),
        wbGainG = prefs.getDoubleOrNull(KEY_WB_GAIN_G),
        wbGainB = prefs.getDoubleOrNull(KEY_WB_GAIN_B),
        zoomRatio = prefs.getDoubleOrNull(KEY_ZOOM_RATIO),
        noiseReductionMode = prefs.getLongOrNull(KEY_NOISE_REDUCTION),
        edgeMode = prefs.getLongOrNull(KEY_EDGE_MODE),
        evCompensation = prefs.getLongOrNull(KEY_EV_COMPENSATION),
    )

    // -----------------------------------------------------------------
    // CamProcessingParams
    // -----------------------------------------------------------------

    fun hasSavedProcessingParams(): Boolean = prefs.contains(KEY_PP_BRIGHTNESS)

    fun saveProcessingParams(p: CamProcessingParams) {
        prefs.edit()
            .putDouble(KEY_PP_BLACK_R, p.blackR)
            .putDouble(KEY_PP_BLACK_G, p.blackG)
            .putDouble(KEY_PP_BLACK_B, p.blackB)
            .putDouble(KEY_PP_GAMMA, p.gamma)
            .putDouble(KEY_PP_BRIGHTNESS, p.brightness)
            .putDouble(KEY_PP_CONTRAST, p.contrast)
            .putDouble(KEY_PP_SATURATION, p.saturation)
            .apply()
    }

    fun loadProcessingParams(): CamProcessingParams = CamProcessingParams(
        blackR = prefs.getDouble(KEY_PP_BLACK_R, 0.0),
        blackG = prefs.getDouble(KEY_PP_BLACK_G, 0.0),
        blackB = prefs.getDouble(KEY_PP_BLACK_B, 0.0),
        gamma = prefs.getDouble(KEY_PP_GAMMA, 1.0),
        brightness = prefs.getDouble(KEY_PP_BRIGHTNESS, 0.0),
        contrast = prefs.getDouble(KEY_PP_CONTRAST, 0.0),
        saturation = prefs.getDouble(KEY_PP_SATURATION, 0.0),
    )

    // -----------------------------------------------------------------
    // Helpers — SharedPreferences lacks native Double/nullable support
    // -----------------------------------------------------------------

    private fun SharedPreferences.Editor.putStringOrRemove(key: String, value: String?): SharedPreferences.Editor =
        if (value != null) putString(key, value) else remove(key)

    private fun SharedPreferences.Editor.putLongOrRemove(key: String, value: Long?): SharedPreferences.Editor =
        if (value != null) putLong(key, value) else remove(key)

    private fun SharedPreferences.Editor.putDoubleOrRemove(key: String, value: Double?): SharedPreferences.Editor =
        if (value != null) putLong(key, value.toRawBits()) else remove(key)

    private fun SharedPreferences.Editor.putDouble(key: String, value: Double): SharedPreferences.Editor =
        putLong(key, value.toRawBits())

    private fun SharedPreferences.getStringOrNull(key: String): String? =
        if (contains(key)) getString(key, null) else null

    private fun SharedPreferences.getLongOrNull(key: String): Long? =
        if (contains(key)) getLong(key, 0L) else null

    private fun SharedPreferences.getDoubleOrNull(key: String): Double? =
        if (contains(key)) Double.fromBits(getLong(key, 0L)) else null

    private fun SharedPreferences.getDouble(key: String, default: Double): Double =
        if (contains(key)) Double.fromBits(getLong(key, 0L)) else default

    companion object {
        private const val PREFS_NAME = "cambrian_camera_settings"

        // CamSettings keys
        private const val KEY_ISO_MODE = "iso_mode"
        private const val KEY_ISO = "iso"
        private const val KEY_EXPOSURE_MODE = "exp_mode"
        private const val KEY_EXPOSURE_TIME_NS = "exp_time_ns"
        private const val KEY_FOCUS_MODE = "focus_mode"
        private const val KEY_FOCUS_DISTANCE = "focus_dist"
        private const val KEY_WB_MODE = "wb_mode"
        private const val KEY_WB_GAIN_R = "wb_r"
        private const val KEY_WB_GAIN_G = "wb_g"
        private const val KEY_WB_GAIN_B = "wb_b"
        private const val KEY_ZOOM_RATIO = "zoom"
        private const val KEY_NOISE_REDUCTION = "noise_reduction"
        private const val KEY_EDGE_MODE = "edge_mode"
        private const val KEY_EV_COMPENSATION = "ev_comp"

        // CamProcessingParams keys
        private const val KEY_PP_BLACK_R = "pp_black_r"
        private const val KEY_PP_BLACK_G = "pp_black_g"
        private const val KEY_PP_BLACK_B = "pp_black_b"
        private const val KEY_PP_GAMMA = "pp_gamma"
        private const val KEY_PP_BRIGHTNESS = "pp_brightness"
        private const val KEY_PP_CONTRAST = "pp_contrast"
        private const val KEY_PP_SATURATION = "pp_saturation"
    }
}
