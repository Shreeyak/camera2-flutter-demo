import AVFoundation
import CoreMedia
import Foundation

/// KVO → AsyncStream<DeviceStateSnapshot> adapter per ADR-14.
///
/// Tokens-box lifetime: observations are held in a reference-type box whose
/// `deinit` invalidates them. The stream's `onTermination` keeps the box alive
/// until the consumer ends its `for await` loop; on termination the box drops
/// and KVO detaches deterministically.
final class DeviceKVOObserver: @unchecked Sendable {

    /// Internal visibility so the Stage 03 test-only factory extension
    /// can construct token boxes.
    // @unchecked Sendable: mutations are single-threaded (inside the AsyncStream
    // build closure); deinit is deterministic via onTermination.
    final class Tokens: @unchecked Sendable {
        var values: [NSKeyValueObservation] = []
        deinit { values.forEach { $0.invalidate() } }
    }

    fileprivate var tokens: Tokens?

    /// Shared producer.
    ///
    /// `install` populates `box.values` with KVO observations
    /// that call `cont.yield(snap)` per change. Production and test factories
    /// both call this helper to share lifetime + buffering logic.
    static func makeStreamFromObservations(
        install:
            @escaping @Sendable (
                _ cont: AsyncStream<DeviceStateSnapshot>.Continuation,
                _ box: Tokens
            ) -> Void
    ) -> (AsyncStream<DeviceStateSnapshot>, DeviceKVOObserver) {
        let observer = DeviceKVOObserver()
        let stream = AsyncStream<DeviceStateSnapshot>(
            DeviceStateSnapshot.self,
            bufferingPolicy: .bufferingOldest(Constants.stateStreamBufferSize)
        ) { [weak observer] cont in
            let box = Tokens()
            install(cont, box)
            observer?.tokens = box
            cont.onTermination = { _ in _ = box }
        }
        return (stream, observer)
    }

    /// Production entry — wraps a live `AVCaptureDevice`.
    static func makeStream(
        avDevice: AVCaptureDevice
    ) -> (AsyncStream<DeviceStateSnapshot>, DeviceKVOObserver) {
        // AVCaptureDevice is not Sendable; nonisolated(unsafe) is safe here
        // because KVO callbacks only read device properties — all mutations are
        // gated by lockForConfiguration() on sessionQueue (ADR-07).
        nonisolated(unsafe) let device = avDevice
        return makeStreamFromObservations { cont, box in
            box.values = [
                device.observe(\.iso, options: [.initial, .new]) { dev, _ in
                    cont.yield(Self.snapshot(avDevice: dev))
                },
                device.observe(\.exposureDuration, options: [.new]) { dev, _ in
                    cont.yield(Self.snapshot(avDevice: dev))
                },
                device.observe(\.lensPosition, options: [.new]) { dev, _ in
                    cont.yield(Self.snapshot(avDevice: dev))
                },
                device.observe(\.deviceWhiteBalanceGains, options: [.new]) { dev, _ in
                    cont.yield(Self.snapshot(avDevice: dev))
                },
            ]
        }
    }

    /// Snapshot builder for AVCaptureDevice.
    static func snapshot(avDevice d: AVCaptureDevice) -> DeviceStateSnapshot {
        let ns = Int64(CMTimeGetSeconds(d.exposureDuration) * 1_000_000_000)
        return DeviceStateSnapshot(
            iso: d.iso,
            exposureDurationNs: ns,
            lensPosition: d.lensPosition,
            whiteBalanceGains: WhiteBalanceGains(
                red: d.deviceWhiteBalanceGains.redGain,
                green: d.deviceWhiteBalanceGains.greenGain,
                blue: d.deviceWhiteBalanceGains.blueGain),
            isAdjustingExposure: d.isAdjustingExposure,
            systemPressureLevel: .nominal)
    }
}
