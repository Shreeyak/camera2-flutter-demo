// Copyright (c) 2025 Cambrian. All rights reserved.
package com.cambrian.camera

/**
 * Immutable snapshot of [android.hardware.camera2.TotalCaptureResult] fields captured
 * on a single streaming frame. Stored as [CameraController.lastCaptureSnapshot] and used
 * to populate EXIF metadata when an image is saved.
 *
 * All fields are nullable; a null value means the hardware did not report that field
 * for the captured frame. Consumers must treat every field as best-effort.
 *
 * Note: [lensDistortion] is a [FloatArray]; Kotlin data-class `equals`/`hashCode` do
 * not deep-compare arrays, but this class is never compared — it is a plain data holder.
 */
data class CaptureResultSnapshot(
    // Sensor
    val iso: Int?,                     // SENSOR_SENSITIVITY — ISO speed rating
    val exposureTimeNs: Long?,         // SENSOR_EXPOSURE_TIME — shutter duration (ns)
    val frameDurationNs: Long?,        // SENSOR_FRAME_DURATION — time between frame starts (ns)
    val sensorTimestampNs: Long?,      // SENSOR_TIMESTAMP — monotonic frame start time (ns)
    // Lens
    val focalLengthMm: Float?,         // LENS_FOCAL_LENGTH — focal length (mm)
    val aperture: Float?,              // LENS_APERTURE — f-number (e.g. 1.8)
    val focusDistanceDiopters: Float?, // LENS_FOCUS_DISTANCE — 1/m; 0 = infinity
    val lensOisMode: Int?,             // LENS_OPTICAL_STABILIZATION_MODE — 0=off, 1=on
    val lensDistortion: FloatArray?,   // LENS_DISTORTION — 5 radial/tangential coefficients
    // White balance (COLOR_CORRECTION_GAINS; g = average of greenEven + greenOdd)
    val wbGainR: Float?,
    val wbGainG: Float?,
    val wbGainB: Float?,
    val colorCorrectionMode: Int?,     // COLOR_CORRECTION_MODE — 0=transform, 1=fast, 2=HQ
    // 3A control
    val aeMode: Int?,                  // CONTROL_AE_MODE — 0=off, 1=on, 2=on+flash, …
    val aeState: Int?,                 // CONTROL_AE_STATE — 0=inactive … 5=flash required
    val afMode: Int?,                  // CONTROL_AF_MODE — 0=off, 1=auto, 3=cont-picture, …
    val afState: Int?,                 // CONTROL_AF_STATE — 0=inactive … 6=not-focused-locked
    val awbMode: Int?,                 // CONTROL_AWB_MODE — 0=off, 1=auto, 2=incandescent, …
    val awbState: Int?,                // CONTROL_AWB_STATE — 0=inactive … 3=locked
    val sceneMode: Int?,               // CONTROL_SCENE_MODE — 0=disabled, 1=face priority, …
    val captureIntent: Int?,           // CONTROL_CAPTURE_INTENT — 1=preview, 2=still, …
    // Flash
    val flashMode: Int?,               // FLASH_MODE — 0=off, 1=single, 2=torch
    val flashState: Int?,              // FLASH_STATE — 0=unavailable … 3=fired, 4=partial
    // Post-processing modes
    val noiseReductionMode: Int?,      // NOISE_REDUCTION_MODE — 0=off, 1=fast, 2=HQ, …
    val edgeMode: Int?,                // EDGE_MODE — 0=off, 1=fast, 2=HQ, 3=ZSL
    val hotPixelMode: Int?,            // HOT_PIXEL_MODE — 0=off, 1=fast, 2=HQ
    val tonemapMode: Int?,             // TONEMAP_MODE — 0=contrast curve, 1=fast, 2=HQ, …
)
