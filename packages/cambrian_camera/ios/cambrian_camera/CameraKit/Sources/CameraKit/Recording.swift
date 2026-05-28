import AVFoundation
import Atomics
import CoreMedia
import Foundation
import UIKit

/// Abstraction over the UIApplication background-task API.
///
/// Per 06-capture-and-recording.md §Background drain: lets the recording drain
/// run inside an OS-granted background-task assertion, and lets tests exercise
/// the expiration path without a live `UIApplication`.
public protocol BackgroundTaskProviding: Sendable {
    /// Begins a background task; the returned identifier must be passed to
    /// `endBackgroundTask` exactly once. `expirationHandler` runs on an
    /// arbitrary queue if the OS reclaims the assertion before completion.
    func beginBackgroundTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> Int
    /// Ends the background task identified by `id`. A no-op for an invalid id.
    func endBackgroundTask(_ id: Int) async
}

/// Production `BackgroundTaskProviding` backed by `UIApplication.shared`.
public struct UIApplicationBackgroundTaskProvider: BackgroundTaskProviding {
    public init() {}

    public func beginBackgroundTask(
        name: String,
        expirationHandler: @escaping @Sendable () -> Void
    ) async -> Int {
        await MainActor.run {
            UIApplication.shared.beginBackgroundTask(
                withName: name, expirationHandler: expirationHandler
            ).rawValue
        }
    }

    public func endBackgroundTask(_ id: Int) async {
        let identifier = UIBackgroundTaskIdentifier(rawValue: id)
        guard identifier != .invalid else { return }
        await MainActor.run {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
}

/// Recording coordinator — owns AVAssetWriter + adaptor lifecycle (D-04, ADR-16).
///
/// Single-session: one `start` call, one `stop` call. Instance discarded between recordings.
public actor Recording {

    // MARK: - Hooks

    public struct Hooks: Sendable {
        /// Called each time `state` transitions.
        public var publishState: @Sendable (RecordingState) -> Void
        /// Called to surface non-fatal and fatal recording errors.
        public var emitError: @Sendable (CameraError) -> Void

        public init(
            publishState: @escaping @Sendable (RecordingState) -> Void,
            emitError: @escaping @Sendable (CameraError) -> Void
        ) {
            self.publishState = publishState
            self.emitError = emitError
        }
    }

    // MARK: - Properties

    private let clock: any CameraKitClock
    private let hooks: Hooks
    private let writerFactory: AssetWriterFactory
    private let backgroundTaskProvider: any BackgroundTaskProviding

    private var writer: (any AssetWriting)?
    private var adaptor: (any AssetWriterPixelBufferAdapting)?
    private var state: RecordingState = .idle(lastUri: nil)
    private var outputURL: URL?
    /// Captured at `start` so the engine can read it back post-`stop` and
    /// dispatch to `PhotosLibraryClient.publish` without re-passing options.
    var photosDestination: PhotosDestination = .none
    private var startPTS: CMTime?
    private var droppedNotReady: Int = 0

    // MARK: - Initialization

    public init(
        clock: any CameraKitClock,
        hooks: Hooks,
        writerFactory: @escaping AssetWriterFactory,
        backgroundTaskProvider: any BackgroundTaskProviding = UIApplicationBackgroundTaskProvider()
    ) {
        self.clock = clock
        self.hooks = hooks
        self.writerFactory = writerFactory
        self.backgroundTaskProvider = backgroundTaskProvider
    }

    // MARK: - Public Methods

    /// Test seam: publish the current state through the hook so tests can observe it.
    func observeCurrentStateForTest() {
        hooks.publishState(state)
    }

    public func currentState() -> RecordingState { state }
    public func currentDroppedNotReady() -> Int { droppedNotReady }

    /// Start a recording session.
    ///
    /// Returns the `RecordingStart` on success.
    public func start(
        options: RecordingOptions,
        captureSize: Size
    ) async throws -> RecordingStart {
        guard case .idle = state else {
            throw RecordingError.writerStartFailed(status: -1)
        }
        let url = try PhotosLibraryClient.resolve(outputURL: options.outputURL, defaultExt: "mp4")
        let bitrate = options.bitrateBps ?? Constants.recordingTargetBitrateBpsDefault
        let fps = options.fps ?? Constants.frameRateTargetFPS

        let (w, a) = try await writerFactory(url, captureSize, bitrate, fps)
        writer = w
        adaptor = a
        outputURL = url
        photosDestination = options.photosDestination

        let ok = await w.startWriting()
        if !ok {
            let err = await w.writerError
            throw RecordingError.writerStartFailed(
                status: Int((err as NSError?)?.code ?? -1)
            )
        }
        state = .recording
        hooks.publishState(state)
        return RecordingStart(uri: url.absoluteString, displayName: url.lastPathComponent)
    }

    /// Submit an encoded NV12 buffer.
    ///
    /// Returns true if appended; false if dropped.
    @discardableResult
    public func submitEncodedBuffer(_ buffer: CVPixelBuffer, pts: CMTime) async -> Bool {
        guard case .recording = state,
            let writer, let adaptor
        else { return false }
        if startPTS == nil {
            startPTS = pts
            await writer.startSession(atSourceTime: pts)
        }
        guard await adaptor.isReadyForMoreMediaData else {
            droppedNotReady += 1
            return false
        }
        return await adaptor.append(buffer, pts: pts)
    }

    /// Stop the recording and finalize (or cancel on deadline).
    public func stop() async -> String {
        guard case .recording = state, let writer else {
            CameraKitLog.notice(
                .engine,
                "[recording] Recording.stop early exit (state=\(state))"
            )
            if case .idle(let last) = state { return last ?? "" }
            return outputURL?.absoluteString ?? ""
        }
        let stopEntryMs = clock.nowMs()
        CameraKitLog.notice(
            .engine,
            "[recording] Recording.stop entry: state=\(state) droppedNotReady=\(droppedNotReady)"
        )
        state = .finalizing
        hooks.publishState(state)

        await writer.markInputFinished()

        let deadlineMs = Int(Constants.recordingFinishTimeoutSeconds * 1000)
        let clock = self.clock
        let didCancel = ManagedAtomic<Bool>(false)

        // Background-task assertion around the drain (06-capture-and-recording.md
        // §Background drain). If the OS reclaims the assertion mid-drain the
        // expiration handler cancels the writer — never `finishWriting` (ADR-16,
        // G-08): an interrupted `finishWriting` produces a corrupt MP4 with no
        // `moov` atom, whereas `cancelWriting` produces an empty file. The
        // handler runs on an arbitrary queue; it schedules `cancelWriting`
        // through a detached `Task`, requiring no engine-actor hop.
        let bgTaskId = await backgroundTaskProvider.beginBackgroundTask(
            name: "recording-drain"
        ) {
            didCancel.store(true, ordering: .sequentiallyConsistent)
            Task { await writer.cancelWriting() }
        }

        // ADR-30 pattern (see AsyncWithTimeout.swift): CAS race between the work
        // branch and the deadline branch with a `ManagedAtomic<Bool>` resume-once
        // gate. `withTaskGroup` is NOT used here because `group.waitForAll()`
        // waits for every child task to terminate, and the deadline child has no
        // early-out — that made every stop block for `recordingFinishTimeoutSeconds`
        // regardless of how fast `finishWriting` actually completed, which then
        // silently swallowed taps in the `.finalizing` window.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumed = ManagedAtomic<Bool>(false)
            let resumeOnce: @Sendable () -> Void = {
                let (won, _) = resumed.compareExchange(
                    expected: false, desired: true,
                    ordering: .sequentiallyConsistent
                )
                if won { cont.resume() }
            }

            // Deadline branch
            Task {
                try? await clock.sleep(milliseconds: deadlineMs)
                if resumed.load(ordering: .acquiring) { return }
                if await writer.status != .completed {
                    didCancel.store(true, ordering: .sequentiallyConsistent)
                    await writer.cancelWriting()
                }
                resumeOnce()
            }

            // Work branch
            Task {
                await writer.finishWriting()
                resumeOnce()
            }
        }

        // `endBackgroundTask` on every exit path (Stage 12 §7): this single site
        // after the drain covers normal finalize, deadline cancel, expiration
        // cancel, and the writer-error path below.
        await backgroundTaskProvider.endBackgroundTask(bgTaskId)

        let stopGroupDoneMs = self.clock.nowMs()
        let stopWriterStatus = await writer.status.rawValue
        CameraKitLog.notice(
            .engine,
            "[recording] Recording.stop group done: durationMs=\(stopGroupDoneMs - stopEntryMs) writerStatus=\(stopWriterStatus) didCancel=\(didCancel.load(ordering: .acquiring))"
        )

        let url = outputURL?.absoluteString ?? ""
        if didCancel.load(ordering: .acquiring) {
            let truncErr = CameraError(
                code: .recordingTruncated,
                message: "finishWriting exceeded \(Constants.recordingFinishTimeoutSeconds)s; cancelled",
                isFatal: false
            )
            hooks.emitError(truncErr)
        }
        if await writer.status == .failed {
            let writerErr = await writer.writerError
            let failErr = CameraError(
                code: .recordingFailed,
                message: "writer failed: \(String(describing: writerErr))",
                isFatal: true
            )
            hooks.emitError(failErr)
            state = .idle(lastUri: url)
            hooks.publishState(state)
            return url
        }
        state = .idle(lastUri: url)
        hooks.publishState(state)
        return url
    }
}
