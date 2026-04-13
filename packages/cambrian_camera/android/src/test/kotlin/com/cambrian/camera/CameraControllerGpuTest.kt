package com.cambrian.camera

import android.content.Context
import android.content.SharedPreferences
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.net.Uri
import android.os.Handler
import android.view.Surface
import io.flutter.view.TextureRegistry
import java.lang.reflect.Field
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.mockito.kotlin.any
import org.mockito.kotlin.anyOrNull
import org.mockito.kotlin.argumentCaptor
import org.mockito.kotlin.eq
import org.mockito.kotlin.mock
import org.mockito.kotlin.never
import org.mockito.kotlin.verify
import org.mockito.kotlin.verifyNoMoreInteractions
import org.mockito.kotlin.whenever

/**
 * JVM unit tests for CameraController GPU wiring logic.
 *
 * These tests use reflection to inject a mock [GpuPipeline] into a [CameraController]
 * instance, avoiding the need to spin up a real Camera2 session.
 *
 * The inline Mockito mock-maker (configured in mockito-extensions/) enables mocking
 * of concrete Android classes such as [CameraManager] and [CameraFlutterApi].
 */
class CameraControllerGpuTest {

    private lateinit var controller: CameraController
    private lateinit var mockGpuPipeline: GpuPipeline
    private lateinit var gpuPipelineField: Field
    private lateinit var lastParamsField: Field
    private lateinit var mockCameraManager: CameraManager
    private lateinit var mockSurfaceProducer: TextureRegistry.SurfaceProducer
    private lateinit var mockRawSurfaceProducer: TextureRegistry.SurfaceProducer
    private lateinit var videoRecorderField: Field
    private lateinit var isRecordingField: Field
    private lateinit var stateField: Field
    private lateinit var mockVideoRecorder: VideoRecorder
    private lateinit var mockFlutterApi: CameraFlutterApi

    @Before
    fun setUp() {
        // Mock CameraManager so the cast in the CameraController constructor succeeds.
        mockCameraManager = mock()

        // Mock SharedPreferences (and Editor) so SettingsStore.<init> does not NPE.
        // With isReturnDefaultValues=true, unstubbed object-return methods return null;
        // the non-null prefs assignment in SettingsStore throws if not stubbed here.
        val mockEditor: SharedPreferences.Editor = mock {
            on { putString(any(), anyOrNull()) }.thenAnswer { it.mock }
            on { putLong(any(), any()) }.thenAnswer { it.mock }
            on { putFloat(any(), any()) }.thenAnswer { it.mock }
            on { putBoolean(any(), any()) }.thenAnswer { it.mock }
            on { remove(any()) }.thenAnswer { it.mock }
        }
        val mockSharedPreferences: SharedPreferences = mock {
            on { edit() }.thenReturn(mockEditor)
        }
        val mockContext: Context = mock {
            on { getSystemService(Context.CAMERA_SERVICE) }.thenReturn(mockCameraManager)
            on { getSharedPreferences(any(), any()) }.thenReturn(mockSharedPreferences)
        }
        mockSurfaceProducer = mock()
        mockRawSurfaceProducer = mock()
        mockFlutterApi = mock()

        controller = CameraController(
            context = mockContext,
            surfaceProducer = mockSurfaceProducer,
            rawSurfaceProducer = mockRawSurfaceProducer,
            enableRawStream = false,
            rawStreamHeight = 0,
            flutterApi = mockFlutterApi,
            handle = 1L,
        )

        mockGpuPipeline = mock()
        mockVideoRecorder = mock()

        // Cache the private fields for injection and inspection.
        gpuPipelineField = CameraController::class.java.getDeclaredField("gpuPipeline")
        gpuPipelineField.isAccessible = true

        lastParamsField = CameraController::class.java.getDeclaredField("lastProcessingParams")
        lastParamsField.isAccessible = true

        videoRecorderField = CameraController::class.java.getDeclaredField("videoRecorder")
        videoRecorderField.isAccessible = true

        isRecordingField = CameraController::class.java.getDeclaredField("isRecording")
        isRecordingField.isAccessible = true

        stateField = CameraController::class.java.getDeclaredField("state")
        stateField.isAccessible = true

        // Android Handler stubs are no-ops with isReturnDefaultValues=true — post() never
        // runs the runnable. Inject synchronous mocks so callbacks fire on the calling thread.
        val syncHandler: Handler = mock {
            on { post(any()) }.thenAnswer { invocation ->
                invocation.getArgument<Runnable>(0).run()
                true
            }
        }
        listOf("backgroundHandler", "mainHandler").forEach { name ->
            CameraController::class.java.getDeclaredField(name)
                .apply { isAccessible = true }
                .set(controller, syncHandler)
        }
    }

    /** Injects the mock GpuPipeline into the controller via reflection. */
    private fun injectGpuPipeline(pipeline: GpuPipeline?) {
        gpuPipelineField.set(controller, pipeline)
    }

    private fun buildParams(
        brightness: Double = 0.5,
        contrast: Double = 1.0,
        saturation: Double = 1.2,
        blackR: Double = 0.01,
        blackG: Double = 0.02,
        blackB: Double = 0.03,
    ) = CamProcessingParams(
        blackR = blackR, blackG = blackG, blackB = blackB,
        gamma = 1.0,
        brightness = brightness,
        contrast = contrast,
        saturation = saturation,
    )

    /**
     * When gpuPipeline is set, setProcessingParams must call setAdjustments
     * with the correct values and update lastProcessingParams.
     */
    @Test
    fun `setProcessingParams routes to gpuPipeline setAdjustments`() {
        injectGpuPipeline(mockGpuPipeline)

        val params = buildParams(brightness = 0.7, contrast = 1.3, saturation = 0.9,
            blackR = 0.05, blackG = 0.06, blackB = 0.07)
        controller.setProcessingParams(params)

        verify(mockGpuPipeline).setAdjustments(
            brightness = 0.7,
            contrast = 1.3,
            saturation = 0.9,
            blackR = 0.05,
            blackG = 0.06,
            blackB = 0.07,
            gamma = 1.0,
        )

        val stored = lastParamsField.get(controller) as CamProcessingParams?
        assertEquals(params, stored)
    }

    /**
     * When gpuPipeline is null, setProcessingParams must not crash and must
     * still update lastProcessingParams.
     */
    @Test
    fun `setProcessingParams is no-op when gpuPipeline is null`() {
        injectGpuPipeline(null)

        val params = buildParams(brightness = 0.2)
        controller.setProcessingParams(params)

        // No interaction with any mock GPU pipeline.
        verify(mockGpuPipeline, never()).setAdjustments(any(), any(), any(), any(), any(), any(), any())

        val stored = lastParamsField.get(controller) as CamProcessingParams?
        assertEquals(params, stored)
    }

    /**
     * When gpuPipeline is set and teardown runs, stop() must be called on the pipeline.
     * Teardown is invoked via reflection to avoid triggering full Camera2 session cleanup.
     */
    @Test
    fun `teardown calls gpuPipeline stop and clears field`() {
        injectGpuPipeline(mockGpuPipeline)

        // Invoke the private teardown() method directly via reflection.
        val teardownMethod = CameraController::class.java.getDeclaredMethod("teardown")
        teardownMethod.isAccessible = true
        teardownMethod.invoke(controller)

        verify(mockGpuPipeline).stop()
        assertNull(gpuPipelineField.get(controller))
    }

    /**
     * The raw stream has no adjustable parameters — only the processed path responds to
     * setAdjustments. This test documents that GpuPipeline exposes a single setAdjustments
     * entry point with no separate raw adjustment call.
     */
    @Test
    fun `setProcessingParams does not affect raw stream`() {
        injectGpuPipeline(mockGpuPipeline)

        val params = buildParams()
        controller.setProcessingParams(params)

        // The processed path calls setAdjustments exactly once.
        verify(mockGpuPipeline).setAdjustments(
            brightness = params.brightness,
            contrast = params.contrast,
            saturation = params.saturation,
            blackR = params.blackR,
            blackG = params.blackG,
            blackB = params.blackB,
            gamma = params.gamma,
        )
        // No other interactions — GpuPipeline has no separate raw adjustment path.
        verifyNoMoreInteractions(mockGpuPipeline)
    }

    /**
     * When onSurfaceAvailable fires but no native pipeline is active (nativePipelinePtr == 0),
     * the callback must return early without calling rebindPreviewSurface.
     *
     * Note: the positive path (ptr != 0) calls gpuPipeline?.rebindPreviewSurface, which
     * cannot be exercised in JVM unit tests without loading the native library.
     * That path is covered by integration/device tests.
     */
    @Test
    fun `onSurfaceAvailable with no active pipeline does not call rebindPreviewSurface`() {
        injectGpuPipeline(mockGpuPipeline)

        // nativePipelinePtr defaults to 0 — onSurfaceAvailable returns early.
        val callbackCaptor = argumentCaptor<TextureRegistry.SurfaceProducer.Callback>()
        verify(mockSurfaceProducer).setCallback(callbackCaptor.capture())
        callbackCaptor.firstValue.onSurfaceAvailable()

        verify(mockGpuPipeline, never()).rebindPreviewSurface(any())
    }

    /**
     * When the Flutter SurfaceProducer fires onSurfaceCleanup, the controller must call
     * rebindPreviewSurface(null) to detach the GPU renderer from the dead surface.
     */
    @Test
    fun `onSurfaceCleanup calls rebindPreviewSurface with null`() {
        injectGpuPipeline(mockGpuPipeline)

        val callbackCaptor = argumentCaptor<TextureRegistry.SurfaceProducer.Callback>()
        verify(mockSurfaceProducer).setCallback(callbackCaptor.capture())
        callbackCaptor.firstValue.onSurfaceCleanup()

        verify(mockGpuPipeline).rebindPreviewSurface(null)
    }

    /**
     * Returns a mock [CameraCharacteristics] that returns null for every key query.
     * The CameraController handles null gracefully by using default values.
     */
    private fun makeMockCameraCharacteristics(): CameraCharacteristics {
        val mockChars: CameraCharacteristics = mock()
        whenever(mockChars.get(any<CameraCharacteristics.Key<Any>>())).thenReturn(null)
        return mockChars
    }

    /**
     * Sets a private field on [controller] by name using reflection.
     */
    private fun setPrivateField(fieldName: String, value: Any?) {
        val field = CameraController::class.java.getDeclaredField(fieldName)
        field.isAccessible = true
        field.set(controller, value)
    }

    /**
     * When enableRawStream is true and a session has been started (rawW/rawH populated),
     * getCapabilities must report the raw texture id and dimensions from the raw surface producer.
     */
    @Test
    fun `getCapabilities returns raw dimensions when enabled`() {
        // Build a context that vends the shared mockCameraManager and a no-op SharedPreferences.
        val rawMockEditor: SharedPreferences.Editor = mock {
            on { putString(any(), anyOrNull()) }.thenAnswer { it.mock }
            on { putLong(any(), any()) }.thenAnswer { it.mock }
            on { putFloat(any(), any()) }.thenAnswer { it.mock }
            on { putBoolean(any(), any()) }.thenAnswer { it.mock }
            on { remove(any()) }.thenAnswer { it.mock }
        }
        val rawMockSharedPreferences: SharedPreferences = mock {
            on { edit() }.thenReturn(rawMockEditor)
        }
        val mockContext: Context = mock {
            on { getSystemService(Context.CAMERA_SERVICE) }.thenReturn(mockCameraManager)
            on { getSharedPreferences(any(), any()) }.thenReturn(rawMockSharedPreferences)
        }
        val mockSurfaceProducer: TextureRegistry.SurfaceProducer = mock()
        val mockFlutterApi: CameraFlutterApi = mock()

        // Create a controller with enableRawStream = true.
        val rawController = CameraController(
            context = mockContext,
            surfaceProducer = mockSurfaceProducer,
            rawSurfaceProducer = mockRawSurfaceProducer,
            enableRawStream = true,
            rawStreamHeight = 480,
            flutterApi = mockFlutterApi,
            handle = 2L,
        )

        // Simulate a completed session start by injecting rawW, rawH, and a running gpuPipeline.
        val rawWField = CameraController::class.java.getDeclaredField("rawW")
        rawWField.isAccessible = true
        rawWField.set(rawController, 640)

        val rawHField = CameraController::class.java.getDeclaredField("rawH")
        rawHField.isAccessible = true
        rawHField.set(rawController, 480)

        // Inject a mock GpuPipeline so isRunning returns true — capabilities
        // gate raw stream fields on pipeline readiness.
        val mockPipeline: GpuPipeline = mock()
        whenever(mockPipeline.isRunning).thenReturn(true)
        val gpuField = CameraController::class.java.getDeclaredField("gpuPipeline")
        gpuField.isAccessible = true
        gpuField.set(rawController, mockPipeline)

        // Set resolvedCameraId so getCapabilities skips selectDefaultCameraId().
        val resolvedCameraIdField = CameraController::class.java.getDeclaredField("resolvedCameraId")
        resolvedCameraIdField.isAccessible = true
        resolvedCameraIdField.set(rawController, "camera0")

        // Mock raw surface producer to return a known texture id.
        whenever(mockRawSurfaceProducer.id()).thenReturn(42L)

        // Mock camera characteristics — return null for all keys (uses defaults).
        val mockChars = makeMockCameraCharacteristics()
        whenever(mockCameraManager.getCameraCharacteristics("camera0")).thenReturn(mockChars)

        var capabilities: CamCapabilities? = null
        rawController.getCapabilities { result ->
            capabilities = result.getOrNull()
        }

        val caps = capabilities!!
        assertEquals(42L, caps.rawStreamTextureId)
        assertEquals(640L, caps.rawStreamWidth)
        assertEquals(480L, caps.rawStreamHeight)
    }

    /**
     * When enableRawStream is false, getCapabilities must report zero for all three raw fields
     * regardless of what the raw surface producer reports.
     */
    @Test
    fun `getCapabilities returns zero raw fields when disabled`() {
        // Set resolvedCameraId so getCapabilities skips selectDefaultCameraId().
        setPrivateField("resolvedCameraId", "camera0")

        // Mock camera characteristics — return null for all keys (uses defaults).
        val mockChars = makeMockCameraCharacteristics()
        whenever(mockCameraManager.getCameraCharacteristics("camera0")).thenReturn(mockChars)

        var capabilities: CamCapabilities? = null
        controller.getCapabilities { result ->
            capabilities = result.getOrNull()
        }

        val caps = capabilities!!
        assertEquals(0L, caps.rawStreamTextureId)
        assertEquals(0L, caps.rawStreamWidth)
        assertEquals(0L, caps.rawStreamHeight)
    }

    @Test
    fun `startRecording sets isRecording to true`() {
        val mockSurface: Surface = mock()
        val mockUri: Uri = mock()
        whenever(mockVideoRecorder.inputSurface).thenReturn(mockSurface)
        whenever(mockVideoRecorder.start(anyOrNull(), anyOrNull())).thenReturn(
            VideoRecorder.RecordingResult(mockUri, "fake_video.mp4")
        )
        videoRecorderField.set(controller, mockVideoRecorder)

        // Set state = STREAMING via reflection
        val streamingState = CameraController::class.java
            .declaredClasses.first { it.simpleName == "State" }
            .enumConstants!!.first { (it as Enum<*>).name == "STREAMING" }
        stateField.set(controller, streamingState)

        val latch = CountDownLatch(1)
        controller.startRecording { latch.countDown() }
        assertTrue(latch.await(2, TimeUnit.SECONDS))

        assertTrue(isRecordingField.getBoolean(controller))
        verify(mockVideoRecorder).prepare(any(), any(), any(), any())
    }

    @Test
    fun `stopRecording when not recording returns failure`() {
        val latch = CountDownLatch(1)
        var captured: Result<String>? = null
        controller.stopRecording { result ->
            captured = result
            latch.countDown()
        }
        assertTrue(latch.await(2, TimeUnit.SECONDS))

        val result = captured!!
        assertTrue(result.isFailure)
        val err = result.exceptionOrNull() as FlutterError
        assertEquals("invalid_state", err.code)
    }

    @Test
    fun `teardown while recording emits error recording state`() {
        whenever(mockVideoRecorder.stop()).thenReturn("content://fake/1")
        videoRecorderField.set(controller, mockVideoRecorder)
        isRecordingField.setBoolean(controller, true)

        controller.release()

        // Drain mainHandler to ensure posted callbacks execute
        val latch = CountDownLatch(1)
        val mainHandlerField = CameraController::class.java
            .getDeclaredField("mainHandler").apply { isAccessible = true }
        val mainHandler = mainHandlerField.get(controller) as Handler
        mainHandler.post { latch.countDown() }
        assertTrue(latch.await(2, TimeUnit.SECONDS))

        verify(mockVideoRecorder).stop()
        verify(mockFlutterApi).onRecordingStateChanged(eq(1L), eq("error"), any())
    }

    @Test
    fun `updateSettings with cropOutputSize invokes gpuPipeline setCropOutput and emits capabilities change`() {
        // Arrange: inject mock GpuPipeline; stub sensor dims to 4000x3000 and
        // the setCropOutput call to succeed. enableRawStream=false in the
        // test setUp, so raw dims are 0.
        gpuPipelineField.set(controller, mockGpuPipeline)
        whenever(mockGpuPipeline.setCropOutput(1600, 1200, 0, 0)).thenReturn(true)
        whenever(mockGpuPipeline.isRunning).thenReturn(true)

        // sensorStreamWidth/Height are private — set via reflection to simulate
        // a running session at 4000x3000.
        val sensorWField = CameraController::class.java.getDeclaredField("sensorStreamWidth")
        sensorWField.isAccessible = true
        sensorWField.setInt(controller, 4000)
        val sensorHField = CameraController::class.java.getDeclaredField("sensorStreamHeight")
        sensorHField.isAccessible = true
        sensorHField.setInt(controller, 3000)
        val previewWField = CameraController::class.java.getDeclaredField("previewWidth")
        previewWField.isAccessible = true
        previewWField.setInt(controller, 4000)
        val previewHField = CameraController::class.java.getDeclaredField("previewHeight")
        previewHField.isAccessible = true
        previewHField.setInt(controller, 3000)

        // Stub getCapabilities dependency: resolvedCameraId + camera characteristics.
        setPrivateField("resolvedCameraId", "camera0")
        val mockChars = makeMockCameraCharacteristics()
        whenever(mockCameraManager.getCameraCharacteristics("camera0")).thenReturn(mockChars)

        // Act
        controller.updateSettings(CamSettings(cropOutputSize = CamSize(1600L, 1200L)))

        // Assert: GPU call + preview resize + capabilities re-emit
        verify(mockGpuPipeline).setCropOutput(1600, 1200, 0, 0)
        verify(mockSurfaceProducer).setSize(1600, 1200)
        argumentCaptor<CamCapabilities>().apply {
            verify(mockFlutterApi).onCapabilitiesChanged(eq(1L), capture(), any())
            assertEquals(1600L, firstValue.streamWidth)
            assertEquals(1200L, firstValue.streamHeight)
        }
    }

    @Test
    fun `updateSettings with invalid cropOutputSize emits SETTINGS_CONFLICT error and does not touch gpu`() {
        gpuPipelineField.set(controller, mockGpuPipeline)

        val sensorWField = CameraController::class.java.getDeclaredField("sensorStreamWidth")
        sensorWField.isAccessible = true
        sensorWField.setInt(controller, 4000)
        val sensorHField = CameraController::class.java.getDeclaredField("sensorStreamHeight")
        sensorHField.isAccessible = true
        sensorHField.setInt(controller, 3000)

        // Odd width — should be rejected on the even-dim check.
        controller.updateSettings(CamSettings(cropOutputSize = CamSize(1601L, 1200L)))

        verify(mockGpuPipeline, never()).setCropOutput(any(), any(), any(), any())
        argumentCaptor<CamError>().apply {
            verify(mockFlutterApi).onError(eq(1L), capture(), any())
            assertEquals(CamErrorCode.SETTINGS_CONFLICT, firstValue.code)
        }
    }

    @Test
    fun `updateSettings with cropOutputSize equal to sensor dims is a no-op (crop inactive)`() {
        gpuPipelineField.set(controller, mockGpuPipeline)

        val sensorWField = CameraController::class.java.getDeclaredField("sensorStreamWidth")
        sensorWField.isAccessible = true
        sensorWField.setInt(controller, 4000)
        val sensorHField = CameraController::class.java.getDeclaredField("sensorStreamHeight")
        sensorHField.isAccessible = true
        sensorHField.setInt(controller, 3000)
        val previewWField = CameraController::class.java.getDeclaredField("previewWidth")
        previewWField.isAccessible = true
        previewWField.setInt(controller, 4000)
        val previewHField = CameraController::class.java.getDeclaredField("previewHeight")
        previewHField.isAccessible = true
        previewHField.setInt(controller, 3000)

        controller.updateSettings(CamSettings(cropOutputSize = CamSize(4000L, 3000L)))

        // No GPU call, no surface resize, no error, no capabilities re-emit.
        verify(mockGpuPipeline, never()).setCropOutput(any(), any(), any(), any())
        verify(mockSurfaceProducer, never()).setSize(any(), any())
        verify(mockFlutterApi, never()).onCapabilitiesChanged(any(), any(), any())
    }
}
