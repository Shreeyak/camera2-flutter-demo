// Copyright (c) 2025 Cambrian. All rights reserved.
package com.cambrian.camera

import android.content.ContentValues
import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMuxer
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.util.Log
import android.view.Surface
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Manages video encoding and muxing for a single recording session.
 *
 * Encapsulates a [MediaCodec] encoder operating in surface-input mode, a [MediaMuxer]
 * writing to a [MediaStore] pending entry, and the drain thread that shuttles
 * encoded buffers from the codec to the muxer.
 *
 * In surface mode the encoder exposes [inputSurface], which is added as a Camera2
 * capture session output so the camera HAL writes frames directly into the encoder
 * via the hardware path — no CPU YUV copying required.
 *
 * State machine: IDLE -> PREPARING -> RECORDING -> STOPPING -> IDLE (or ERROR)
 *
 * @param context Application or activity context used for [MediaStore] access.
 */
class VideoRecorder(private val context: Context) {

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------

    /** Internal recorder lifecycle state. */
    private enum class State { IDLE, PREPARING, RECORDING, STOPPING, ERROR }

    @Volatile private var state: State = State.IDLE

    // -------------------------------------------------------------------------
    // Codec / muxer resources
    // -------------------------------------------------------------------------

    /** The selected MIME type (HEVC or AVC), resolved in [prepare]. */
    private var selectedMime: String = MIME_HEVC

    /** The MediaCodec encoder instance, created fresh in each [prepare] call. */
    private var codec: MediaCodec? = null

    /**
     * The encoder's input [Surface] in surface mode.
     * Valid after [prepare]; Camera2 writes frames into this surface directly.
     * Becomes null after [release].
     */
    var inputSurface: Surface? = null
        private set

    /** The MediaMuxer writing to the current output file, valid between [start] and [stop]. */
    private var muxer: MediaMuxer? = null

    /** File descriptor for the current MediaStore output entry. */
    private var outputFd: ParcelFileDescriptor? = null

    /** Content URI of the current output entry, valid between [start] and [stop]. */
    private var outputUri: Uri? = null

    /** Muxer track index assigned after INFO_OUTPUT_FORMAT_CHANGED. */
    private var trackIndex: Int = -1

    /** True once muxer.start() has been called by the drain thread. */
    @Volatile private var muxerStarted: Boolean = false

    // -------------------------------------------------------------------------
    // Drain thread
    // -------------------------------------------------------------------------

    /** Background HandlerThread used to run the encoder drain loop. */
    private var drainThread: HandlerThread? = null

    /** Handler posted to the drain thread for executing [drainEncoderLoop]. */
    private var drainHandler: Handler? = null

    /**
     * Latch used to wait for the drain thread to finish EOS processing.
     * Created in [start], counted-down in [drainEncoderLoop], awaited in [stop].
     */
    private var eosLatch: CountDownLatch? = null

    /**
     * Non-null when [drainEncoderLoop] caught an exception (e.g. disk full during
     * [android.media.MediaMuxer.writeSampleData]).  Read and cleared by [stop] so the
     * failure can be rethrown on the calling thread.
     */
    @Volatile private var drainError: Exception? = null

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    /**
     * Configures the MediaCodec encoder with the given parameters.
     *
     * Selects HEVC if available, falls back to AVC. Must be called before [start].
     * On success, transitions to PREPARING state. On failure, transitions to ERROR
     * and rethrows the exception.
     *
     * @param width   Output video width in pixels.
     * @param height  Output video height in pixels.
     * @param bitrate Target bitrate in bits per second (default 50 Mbps).
     * @param fps     Target frame rate (default 30 fps).
     */
    fun prepare(width: Int, height: Int, bitrate: Int = 50_000_000, fps: Int = 30) {
        try {
            selectedMime = selectEncoderMime()
            Log.d(TAG, "prepare: mime=$selectedMime width=$width height=$height bitrate=$bitrate fps=$fps")

            val format = MediaFormat.createVideoFormat(selectedMime, width, height).apply {
                setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
                setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                // KEY_COLOR_FORMAT is not set: surface mode uses COLOR_FormatSurface implicitly.
                setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                setInteger(
                    MediaFormat.KEY_BITRATE_MODE,
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR,
                )
                if (selectedMime == MIME_HEVC) {
                    setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain)
                    setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel51)
                }
            }

            val newCodec = MediaCodec.createEncoderByType(selectedMime)
            try {
                newCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                inputSurface = newCodec.createInputSurface()
            } catch (e: Exception) {
                newCodec.release()
                throw e
            }

            // Release any previous codec before replacing.
            codec?.release()
            codec = newCodec

            state = State.PREPARING
            Log.d(TAG, "prepare: done, state=PREPARING")
        } catch (e: Exception) {
            state = State.ERROR
            Log.e(TAG, "prepare: failed", e)
            throw e
        }
    }

    /**
     * Starts encoding and muxing. Must be called after [prepare].
     *
     * Creates a MediaStore pending entry, opens its file descriptor, creates the
     * [MediaMuxer], starts the [MediaCodec], and launches the drain thread.
     *
     * @return Content URI string of the output file (still pending until [stop]).
     * @throws IllegalStateException if called before [prepare].
     */
    fun start(outputDirectory: String? = null, fileName: String? = null): String {
        check(state == State.PREPARING) { "start() called in wrong state: $state" }

        val resolver = context.contentResolver
        val timestamp = System.currentTimeMillis()
        val displayName = if (fileName != null) {
            if (fileName.endsWith(".mp4", ignoreCase = true)) fileName else "$fileName.mp4"
        } else {
            "cambrian_$timestamp.mp4"
        }
        val relPath = if (outputDirectory != null)
            outputDirectory.trimEnd('/') + "/"
        else
            android.os.Environment.DIRECTORY_MOVIES + "/CambrianCamera/"

        val contentValues = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, relPath)
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }

        val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, contentValues)
            ?: run {
                state = State.ERROR
                throw RuntimeException("VideoRecorder: MediaStore insert returned null URI")
            }
        outputUri = uri

        val fd = try {
            resolver.openFileDescriptor(uri, "w")
                ?: throw RuntimeException("VideoRecorder: openFileDescriptor returned null")
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            outputUri = null
            state = State.ERROR
            Log.e(TAG, "start: failed to open file descriptor", e)
            throw e
        }
        outputFd = fd

        val newMuxer = try {
            MediaMuxer(fd.fileDescriptor, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        } catch (e: Exception) {
            fd.close()
            outputFd = null
            resolver.delete(uri, null, null)
            outputUri = null
            state = State.ERROR
            Log.e(TAG, "start: failed to create MediaMuxer", e)
            throw e
        }
        muxer = newMuxer
        muxerStarted = false
        trackIndex = -1

        val latch = CountDownLatch(1)
        eosLatch = latch

        val currentCodec = codec ?: run {
            newMuxer.release()
            muxer = null
            fd.close()
            outputFd = null
            resolver.delete(uri, null, null)
            outputUri = null
            state = State.ERROR
            throw IllegalStateException("VideoRecorder: codec is null at start()")
        }

        currentCodec.start()

        val thread = HandlerThread("VideoEncoderDrain").also { it.start() }
        drainThread = thread
        drainHandler = Handler(thread.looper)
        drainHandler!!.post { drainEncoderLoop(latch) }

        state = State.RECORDING
        Log.d(TAG, "start: recording to $uri")
        return "${uri}|${displayName}"
    }

    /**
     * Stops the current recording and finalizes the output file.
     *
     * Signals end-of-stream to the encoder by queuing an EOS input buffer,
     * waits for the drain thread to finish (up to 5 seconds), then stops the
     * muxer, closes the file descriptor, and marks the MediaStore entry as
     * not-pending so the file is visible in the gallery.
     *
     * @return Content URI string of the finalized file.
     */
    fun stop(): String {
        check(state == State.RECORDING) { "stop() called in wrong state: $state" }
        state = State.STOPPING

        val uri = outputUri
            ?: throw IllegalStateException("VideoRecorder: outputUri is null at stop()")

        val currentCodec = codec
            ?: throw IllegalStateException("VideoRecorder: codec is null at stop()")

        // In surface mode, EOS is signalled via signalEndOfInputStream() rather than
        // queuing a buffer — the codec propagates EOS from the surface to the output.
        Log.d(TAG, "stop: signalling EOS via surface")
        currentCodec.signalEndOfInputStream()

        val latch = eosLatch
        if (latch != null) {
            val drained = latch.await(5, TimeUnit.SECONDS)
            if (!drained) {
                Log.w(TAG, "VideoRecorder: EOS drain timeout, forcing stop")
            }
        }

        // If the drain thread caught an exception (e.g. disk full during writeSampleData),
        // clean up and rethrow so the caller can surface the error to Dart.
        val capturedDrainError = drainError
        drainError = null
        if (capturedDrainError != null) {
            drainThread?.quitSafely(); drainThread = null; drainHandler = null; eosLatch = null
            try { context.contentResolver.delete(uri, null, null) } catch (_: Exception) {}
            muxer?.let { try { it.release() } catch (_: Exception) {} }; muxer = null
            outputFd?.close(); outputFd = null
            currentCodec.stop()
            outputUri = null
            state = State.IDLE
            throw java.io.IOException(
                "Encoding failed (storage full?): ${capturedDrainError.message}",
                capturedDrainError,
            )
        }

        // Shut down the drain thread.
        drainThread?.quitSafely()
        drainThread = null
        drainHandler = null
        eosLatch = null

        // Stop and release the muxer — this writes the moov atom.
        // Use a flag so the IS_PENDING update is skipped when the muxer failed and the
        // MediaStore entry was already deleted.
        var muxerFinalized = false
        val currentMuxer = muxer
        if (currentMuxer != null) {
            if (muxerStarted) {
                try {
                    currentMuxer.stop()
                    muxerFinalized = true
                } catch (e: Exception) {
                    Log.e(TAG, "stop: muxer.stop() threw an exception", e)
                    try { context.contentResolver.delete(uri, null, null) } catch (_: Exception) {}
                }
            } else {
                Log.w(TAG, "stop: muxer was never started (no frames encoded), deleting pending entry")
                try { context.contentResolver.delete(uri, null, null) } catch (_: Exception) {}
            }
            // Release the muxer in its own try block so a release() failure does not
            // suppress the earlier stop() result or prevent cleanup below.
            try {
                currentMuxer.release()
            } catch (e: Exception) {
                Log.e(TAG, "stop: muxer.release() threw an exception", e)
            }
            muxer = null
        }

        outputFd?.close()
        outputFd = null

        // Stop the codec — the instance is reused on the next prepare() call.
        currentCodec.stop()

        // Mark the MediaStore entry as finalized only when muxer.stop() succeeded.
        // If it failed the entry was already deleted above, so skip the update.
        if (muxerFinalized) {
            val cv = ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }
            context.contentResolver.update(uri, cv, null, null)
        }
        outputUri = null

        state = State.IDLE
        Log.d(TAG, "stop: done, uri=$uri")
        return uri.toString()
    }

    /**
     * Releases the codec.
     *
     * After this call the object is unusable. Should be called when the owning
     * component is torn down.
     */
    fun release() {
        Log.d(TAG, "release")
        // If still recording, stop first to avoid use-after-release in the drain thread.
        if (state == State.RECORDING) {
            Log.w(TAG, "release() called while RECORDING — stopping first")
            try { stop() } catch (e: Exception) {
                Log.e(TAG, "release: stop() threw during forced stop", e)
            }
        }
        codec?.release()
        codec = null
        inputSurface = null
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    /**
     * Selects the best available video encoder MIME type.
     *
     * Prefers HEVC ("video/hevc") for higher compression efficiency; falls back
     * to AVC ("video/avc") if no HEVC encoder is present.
     *
     * @return The MIME type string for the selected codec.
     */
    private fun selectEncoderMime(): String {
        val codecList = MediaCodecList(MediaCodecList.REGULAR_CODECS)
        val hasHevc = codecList.codecInfos.any { info ->
            info.isEncoder && info.supportedTypes.any { it.equals(MIME_HEVC, ignoreCase = true) }
        }
        return if (hasHevc) {
            Log.d(TAG, "selectEncoderMime: HEVC encoder available")
            MIME_HEVC
        } else {
            Log.d(TAG, "selectEncoderMime: no HEVC encoder, falling back to AVC")
            MIME_AVC
        }
    }

    /**
     * Drain loop executed on the [drainThread].
     *
     * Polls the codec output, routes format-change events to [MediaMuxer.addTrack],
     * writes encoded samples to the muxer, and counts down [eosLatch] when the
     * end-of-stream buffer arrives.
     *
     * @param eosLatch Counted down to zero when EOS is received or the loop exits.
     */
    private fun drainEncoderLoop(eosLatch: CountDownLatch) {
        val bufferInfo = MediaCodec.BufferInfo()
        val currentCodec = codec
        val currentMuxer = muxer

        if (currentCodec == null || currentMuxer == null) {
            Log.e(TAG, "drainEncoderLoop: codec or muxer is null, aborting")
            eosLatch.countDown()
            return
        }

        try {
            while (true) {
                val index = currentCodec.dequeueOutputBuffer(bufferInfo, 100_000L)
                when {
                    index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        trackIndex = currentMuxer.addTrack(currentCodec.outputFormat)
                        currentMuxer.start()
                        muxerStarted = true
                        Log.d(TAG, "drainEncoderLoop: muxer started, trackIndex=$trackIndex")
                    }
                    index >= 0 -> {
                        if (muxerStarted &&
                            (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0
                        ) {
                            val outputBuffer = currentCodec.getOutputBuffer(index)
                            if (outputBuffer != null) {
                                currentMuxer.writeSampleData(trackIndex, outputBuffer, bufferInfo)
                            }
                        }
                        currentCodec.releaseOutputBuffer(index, false)

                        if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                            Log.d(TAG, "drainEncoderLoop: EOS reached")
                            break
                        }
                    }
                    // INFO_TRY_AGAIN_LATER or INFO_OUTPUT_BUFFERS_CHANGED — just loop again.
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "drainEncoderLoop: exception during drain", e)
            drainError = e
        } finally {
            eosLatch.countDown()
        }
    }

    // -------------------------------------------------------------------------
    // Companion
    // -------------------------------------------------------------------------

    companion object {
        private const val TAG = "VideoRecorder"
        private const val MIME_HEVC = "video/hevc"
        private const val MIME_AVC = "video/avc"
    }
}
