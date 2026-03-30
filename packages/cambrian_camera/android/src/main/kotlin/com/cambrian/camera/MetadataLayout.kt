package com.cambrian.camera

/**
 * Flat array indices for JNI metadata transfer between Kotlin and C++.
 *
 * CameraController packs Camera2 [android.hardware.camera2.CaptureResult]
 * values into two primitive arrays — `LongArray` and `IntArray` — at these
 * fixed offsets before crossing the JNI boundary into [CameraController]'s
 * native methods.  The C++ side reads them by the same indices defined in
 * `MetadataLayout.h`.
 *
 * **Sync rule:** any addition, removal, or reordering here requires an
 * identical change in `MetadataLayout.h` and vice versa.  The C++ header
 * contains `static_assert` guards on `*_COUNT` values to catch mismatches at
 * NDK build time.
 */
object MetadataLayout {

    // -----------------------------------------------------------------------
    // long[] — 64-bit sensor values
    // -----------------------------------------------------------------------

    /** Total number of entries in the longs transfer array. */
    const val LONG_COUNT: Int = 5

    /** Index: [android.hardware.camera2.CaptureResult.CONTROL_AF_STATE] frame counter. */
    const val LONG_FRAME_NUMBER: Int = 0

    /** Index: sensor start timestamp in nanoseconds. */
    const val LONG_TIMESTAMP_NS: Int = 1

    /** Index: actual exposure duration in nanoseconds. */
    const val LONG_EXPOSURE_NS: Int = 2

    /** Index: total frame duration in nanoseconds (1/FPS ceiling). */
    const val LONG_FRAME_DURATION: Int = 3

    /** Index: rolling shutter skew in nanoseconds (top-to-bottom scan time). */
    const val LONG_ROLLING_SHUTTER_SKEW: Int = 4

    // -----------------------------------------------------------------------
    // int[] — 32-bit control/state values
    // -----------------------------------------------------------------------

    /** Total number of entries in the ints transfer array. */
    const val INT_COUNT: Int = 4

    /** Index: sensor sensitivity (ISO equivalent). */
    const val INT_ISO: Int = 0

    /** Index: AE state ([android.hardware.camera2.CaptureResult.CONTROL_AE_STATE_*]). */
    const val INT_AE_STATE: Int = 1

    /** Index: AF state ([android.hardware.camera2.CaptureResult.CONTROL_AF_STATE_*]). */
    const val INT_AF_STATE: Int = 2

    /** Index: AWB state ([android.hardware.camera2.CaptureResult.CONTROL_AWB_STATE_*]). */
    const val INT_AWB_STATE: Int = 3
}
