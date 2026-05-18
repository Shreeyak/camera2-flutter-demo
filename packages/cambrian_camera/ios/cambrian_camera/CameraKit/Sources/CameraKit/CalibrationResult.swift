import Foundation

/// Returned by `CameraEngine.calibrateWhiteBalance()` /
/// `calibrateBlackBalance()`.
///
/// Fields mirror the Pigeon contract's `CamCalibrationResult` (Phase-2 design
/// §2d.8). For the Phase-2 single-shot iOS algorithm, `converged = true` and
/// `iterations = 1`; the future Dart-iterative-loop port (see
/// `docs/superpowers/plans/2026-05-15-wb-calibration-dart-port.md`) populates
/// the fields meaningfully without a contract change.
public struct CalibrationResult: Sendable, Hashable {
    /// RGB sample of the center patch *before* the calibration was applied.
    public let before: RgbSample
    /// RGB sample of the center patch *after* the calibration was applied.
    public let after: RgbSample
    /// Whether the algorithm converged.
    ///
    /// Always `true` for single-shot.
    public let converged: Bool
    /// Iteration count.
    ///
    /// Always `1` for single-shot.
    public let iterations: Int

    public init(before: RgbSample, after: RgbSample, converged: Bool, iterations: Int) {
        self.before = before
        self.after = after
        self.converged = converged
        self.iterations = iterations
    }
}
