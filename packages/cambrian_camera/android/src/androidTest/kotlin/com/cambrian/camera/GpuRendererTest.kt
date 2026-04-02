package com.cambrian.camera

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GpuRendererSmokeTest {

    /** Tracker width/height are pure Kotlin math — no GL context needed. */
    @Test
    fun trackerDimensionsAreCorrect() {
        val pipeline = GpuPipeline(3840, 2160, null, 0L)
        assertEquals(854, pipeline.trackerWidth)
        assertEquals(480, pipeline.trackerHeight)
    }

    /** Same check for a 4:3 sensor resolution. */
    @Test
    fun trackerDimensionsFor4x3CameraAreCorrect() {
        val pipeline = GpuPipeline(4160, 3120, null, 0L)
        assertEquals(640, pipeline.trackerWidth)
        assertEquals(480, pipeline.trackerHeight)
    }

    /** nativeGpuInit with a null preview surface must return a non-zero handle. */
    @Test
    fun gpuInitWithNullPreviewSucceeds() {
        val handle = GpuPipeline.nativeGpuInit(null, 640, 480)
        assertNotEquals("nativeGpuInit should return non-zero handle", 0L, handle)
        if (handle != 0L) GpuPipeline.nativeGpuRelease(handle)
    }

    /** Init twice, release twice — must not crash. */
    @Test
    fun gpuInitAndReleaseIsIdempotent() {
        val handle1 = GpuPipeline.nativeGpuInit(null, 640, 480)
        val handle2 = GpuPipeline.nativeGpuInit(null, 640, 480)
        if (handle1 != 0L) GpuPipeline.nativeGpuRelease(handle1)
        if (handle2 != 0L) GpuPipeline.nativeGpuRelease(handle2)
    }

    /** Setting adjustments on a valid handle must not throw. */
    @Test
    fun setAdjustmentsDoesNotCrash() {
        val handle = GpuPipeline.nativeGpuInit(null, 640, 480)
        if (handle != 0L) {
            GpuPipeline.nativeGpuSetAdjustments(handle, 0.1, 1.2, 0.8, 0.0, 0.0, 0.0)
            GpuPipeline.nativeGpuRelease(handle)
        }
    }

    /** Releasing a zero handle must be a no-op (JNI guard). */
    @Test
    fun gpuReleaseWithZeroHandleIsSafe() {
        GpuPipeline.nativeGpuRelease(0L)
    }
}
