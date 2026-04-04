package com.cambrian.camera

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented test that verifies the GPU pipeline delivers frames to registered
 * FULL_RES sinks via [GpuPipeline.nativeGpuDrawAndReadback].
 *
 * Architecture recap:
 *   OES texture → FBO (shader) → PBO readback → ImagePipeline.deliverFullResRgba
 *   → registered FULL_RES sink callbacks (on consumer dispatch thread)
 *
 * The GpuRenderer uses a double-buffered PBO scheme: the first drawAndReadback
 * call only writes into PBO[writeIdx] and skips the callback (firstFrame_ guard).
 * The second call maps PBO[readIdx] from the previous frame and fires callbacks.
 * Therefore two calls are required to trigger at least one sink delivery.
 */
@RunWith(AndroidJUnit4::class)
class GpuSinkConsistencyTest {

    /**
     * Verifies that calling nativeGpuDrawAndReadback twice results in at least
     * one frame being delivered to a registered FULL_RES sink.
     *
     * The test runs entirely on the test thread, which is valid because
     * nativeGpuInit makes the EGL context current on the calling thread and
     * all subsequent GL operations (drawAndReadback) must run on the same thread.
     *
     * Sink delivery is asynchronous (dispatched on ImagePipeline's consumer
     * thread), so the test polls with a bounded timeout after the second
     * drawAndReadback call.
     */
    @Test
    fun sinkReceivesFrameAfterDrawAndReadback() {
        val width  = 640
        val height = 480

        // Identity transform matrix (as returned by SurfaceTexture.getTransformMatrix
        // when there is no scaling/flip applied).
        val identityMatrix = floatArrayOf(
            1f, 0f, 0f, 0f,
            0f, 1f, 0f, 0f,
            0f, 0f, 1f, 0f,
            0f, 0f, 0f, 1f,
        )
        val frameId = 1L
        val sinkName = "test-sink-consistency"

        // 1. Create a native ImagePipeline (null preview surface = headless).
        val pipelineHandle = CameraController.nativeInit(null, width, height)
        assertNotEquals("nativeInit must return a non-zero pipeline handle", 0L, pipelineHandle)

        // 2. Create an offscreen GpuRenderer (null preview surface = pbuffer only).
        //    nativeGpuInit creates an EGL context and makes it current on this thread.
        val gpuHandle = GpuPipeline.nativeGpuInit(null, width, height, null, 0, 0)
        assertNotEquals("nativeGpuInit must return a non-zero GPU handle", 0L, gpuHandle)

        try {
            // 3. Register a test FULL_RES sink that counts deliveries (role = 0 = FULL_RES).
            GpuPipelineTestBridge.nativeAddDeliveryCountSink(pipelineHandle, sinkName, 0)

            // 4a. First drawAndReadback: writes PBO[0], skips callback (firstFrame_ guard).
            //     OES texture name 0 samples as transparent black — valid for a smoke test.
            GpuPipeline.nativeGpuDrawAndReadback(
                gpuHandle, pipelineHandle,
                /* oesTexture = */ 0,
                identityMatrix,
                frameId,
                /* sensorTimestampNs = */ frameId,
                /* exposureTimeNs = */ 0L,
                /* iso = */ 0,
                /* displayRotation = */ 0
            )

            // 4b. Second drawAndReadback: maps PBO[1] from the first frame,
            //     fires fullResCb → ImagePipeline.deliverFullResRgba → consumer dispatch.
            GpuPipeline.nativeGpuDrawAndReadback(
                gpuHandle, pipelineHandle,
                /* oesTexture = */ 0,
                identityMatrix,
                frameId + 1,
                /* sensorTimestampNs = */ frameId + 1,
                /* exposureTimeNs = */ 0L,
                /* iso = */ 0,
                /* displayRotation = */ 0
            )

            // 5. Wait for the consumer dispatch thread to invoke the sink callback.
            //    Poll with 10 ms intervals up to 500 ms total.
            val deadlineMs = System.currentTimeMillis() + 500L
            var deliveryCount = 0
            while (System.currentTimeMillis() < deadlineMs) {
                deliveryCount = GpuPipelineTestBridge.nativeGetDeliveryCount(
                    pipelineHandle, sinkName
                )
                if (deliveryCount > 0) break
                Thread.sleep(10L)
            }

            // 6. Assert at least one frame was delivered to the FULL_RES sink.
            //    A negative value means nativeAddDeliveryCountSink was not found by the JNI
            //    lookup (sink never registered), which is also a test failure.
            assertTrue(
                "Expected FULL_RES sink to receive at least 1 frame after two " +
                    "drawAndReadback calls, but delivery count was $deliveryCount " +
                    "(negative means the sink was never registered by nativeAddDeliveryCountSink)",
                deliveryCount > 0
            )

            // 7. Byte-level assertion: last delivered frame has correct size and non-zero pixels.
            val fullResBytes = GpuPipelineTestBridge.nativeGetLastDeliveredRgba(pipelineHandle, sinkName)
            assertNotNull("nativeGetLastDeliveredRgba must return non-null after delivery", fullResBytes)
            assertEquals("full-res frame must have correct byte count", width * height * 4, fullResBytes!!.size)
            assertTrue(
                "full-res frame must contain at least one non-zero byte",
                fullResBytes.any { it != 0.toByte() }
            )
        } finally {
            // Always release both handles to avoid leaking GL/EGL resources.
            if (gpuHandle != 0L) GpuPipeline.nativeGpuRelease(gpuHandle)
            CameraController.nativeRelease(pipelineHandle)
        }
    }

    /**
     * Verifies that calling nativeGpuDrawAndReadback twice results in at least
     * one frame being delivered to a registered RAW sink, and that the delivered
     * frame has the correct raw stream dimensions.
     *
     * The raw path uses a separate FBO/PBO pair sized to (rawW x rawH).  The
     * same double-buffer guard applies, so two drawAndReadback calls are required.
     */
    @Test
    fun rawSinkReceivesFrameAfterDrawAndReadback() {
        val width  = 640
        val height = 480
        val rawW   = 320
        val rawH   = 240

        val identityMatrix = floatArrayOf(
            1f, 0f, 0f, 0f,
            0f, 1f, 0f, 0f,
            0f, 0f, 1f, 0f,
            0f, 0f, 0f, 1f,
        )
        val sinkName = "test-sink-raw"

        // 1. Create a native ImagePipeline (null preview surface = headless).
        val pipelineHandle = CameraController.nativeInit(null, width, height)
        assertNotEquals("nativeInit must return a non-zero pipeline handle", 0L, pipelineHandle)

        // 2. Create an offscreen GpuRenderer with raw stream enabled (rawW=320, rawH=240).
        val gpuHandle = GpuPipeline.nativeGpuInit(null, width, height, null, rawW, rawH)
        assertNotEquals("nativeGpuInit must return a non-zero GPU handle", 0L, gpuHandle)

        try {
            // 3. Register a RAW sink (role = 2 = RAW).
            GpuPipelineTestBridge.nativeAddDeliveryCountSink(pipelineHandle, sinkName, 2)

            // 4. Two drawAndReadback calls needed for PBO double-buffer.
            repeat(2) { i ->
                GpuPipeline.nativeGpuDrawAndReadback(
                    gpuHandle, pipelineHandle,
                    /* oesTexture = */ 0,
                    identityMatrix,
                    (i + 1).toLong(),
                    /* sensorTimestampNs = */ (i + 1).toLong(),
                    /* exposureTimeNs = */ 0L,
                    /* iso = */ 0,
                    /* displayRotation = */ 0
                )
            }

            // 5. Poll for delivery with a bounded timeout.
            val deadlineMs = System.currentTimeMillis() + 500L
            var count = 0
            while (System.currentTimeMillis() < deadlineMs) {
                count = GpuPipelineTestBridge.nativeGetDeliveryCount(pipelineHandle, sinkName)
                if (count > 0) break
                Thread.sleep(10L)
            }
            assertTrue("RAW sink must receive at least 1 frame", count > 0)

            // 6. Byte-level assertion: raw frame has correct dimensions and non-zero pixels.
            val rawBytes = GpuPipelineTestBridge.nativeGetLastDeliveredRgba(pipelineHandle, sinkName)
            assertNotNull("nativeGetLastDeliveredRgba must return non-null for RAW sink", rawBytes)
            assertEquals("raw frame must have correct byte count", rawW * rawH * 4, rawBytes!!.size)
            assertTrue(
                "raw frame must contain at least one non-zero byte",
                rawBytes.any { it != 0.toByte() }
            )
        } finally {
            // Always release both handles to avoid leaking GL/EGL resources.
            if (gpuHandle != 0L) GpuPipeline.nativeGpuRelease(gpuHandle)
            CameraController.nativeRelease(pipelineHandle)
        }
    }
}
