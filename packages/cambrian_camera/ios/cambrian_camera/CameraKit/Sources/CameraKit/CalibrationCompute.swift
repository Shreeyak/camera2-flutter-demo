import Foundation

/// Pure helpers for white-balance and black-balance calibration math.
///
/// Called from `CalibrationViewModel` (07-settings.md §Calibration). The engine
/// applies `ProcessingParameters` / `CameraSettings`; the math derivation lives
/// here so it stays unit-testable without an `AVCaptureSession`.
public enum CalibrationCompute {

    /// Gray-world reciprocal gains with per-iteration log-cap damping,
    /// stacked onto current device gains.
    ///
    /// Operates in **gamma-encoded sample space**. Linearization was tried and
    /// rejected — see "History" below. The per-iteration log2-space cap
    /// (`Constants.wbGrayWorldLogCap`) bounds the multiplicative gain change
    /// per call to `[2^-k, 2^k]` so a single step can't overshoot into the
    /// `[1.0, maxGain]` hardware boundaries.
    ///
    /// Source: WWDC 2014 §508 + `AVCaptureDevice.h` lines 1244–1434.
    ///
    /// - Parameter sample: per-channel trimmed-mean read from `naturalTex`
    ///   (BT.601 full-range RGB, gamma-encoded by the sensor/ISP).
    /// - Parameter current: WB gains applied by `AVCaptureDevice` at the moment
    ///   the sample was taken — `device.deviceWhiteBalanceGains`.
    /// - Parameter maxGain: `device.maxWhiteBalanceGain` — used for the final
    ///   per-channel clamp.
    ///
    /// Steps:
    ///   1. Compute per-channel reciprocal `mean / channel` on the raw
    ///      (gamma-encoded) sample.
    ///   2. Cap each ratio to `[2^-k, 2^k]` where `k = wbGrayWorldLogCap`.
    ///   3. Stack onto current gains: `newGain = current × cappedRatio`.
    ///   4. Normalize to `min == 1.0`.
    ///   5. Per-channel clamp to `[1.0, maxGain]`.
    ///
    /// **Why log-cap:** undamped gray-world demands a single step that can be
    /// 2× or more in either direction on a strong initial cast. After the
    /// stack-and-normalize-to-min, that lands one channel exactly on the
    /// 1.0 floor and another on the `maxGain` ceiling. With two channels
    /// pinned at boundaries the loop loses degrees of freedom and oscillates.
    /// Capping the per-step magnitude at √2 (k=0.5) keeps the trajectory
    /// inside the feasible gain box and the loop converges in 2–4 steps from
    /// a near-optimal seed (Apple's `grayWorldDeviceWhiteBalanceGains`).
    ///
    /// **History — why not linearize:** the physically-correct approach is to
    /// apply sRGB EOTF before computing ratios, since AVF's gains operate
    /// pre-gamma in the sensor pipeline. We tried this — and it deadlocked.
    /// On warm-lit scenes, linear-space R-ratios are below 0.5, which after
    /// `current.red × ratio` and the min-normalize lands R-gain on the 1.0
    /// floor. With one channel pinned at the floor, the algorithm has no
    /// degree of freedom left for that channel and the loop oscillates
    /// between two states. Gamma-encoded ratios are mathematically a
    /// compression of the linear ratios, but operationally they keep gains
    /// off the floor/ceiling boundaries.
    public static func grayWorldGains(
        sample: RgbSample,
        current: WhiteBalanceGains,
        maxGain: Float
    ) -> WhiteBalanceGains {
        let eps = 1e-4
        let r = max(eps, sample.r)
        let g = max(eps, sample.g)
        let b = max(eps, sample.b)
        let mean = (r + g + b) / 3.0

        let k = Constants.wbGrayWorldLogCap
        let cappedR = capLogRatio(Float(mean / r), cap: k)
        let cappedG = capLogRatio(Float(mean / g), cap: k)
        let cappedB = capLogRatio(Float(mean / b), cap: k)

        var newR = current.red * cappedR
        var newG = current.green * cappedG
        var newB = current.blue * cappedB

        let m = min(newR, min(newG, newB))
        if m > 0 {
            newR /= m
            newG /= m
            newB /= m
        }

        return WhiteBalanceGains(
            red: min(maxGain, max(1.0, newR)),
            green: min(maxGain, max(1.0, newG)),
            blue: min(maxGain, max(1.0, newB))
        )
    }

    /// Clamps `|log2(ratio)| ≤ cap`, returning the corresponding linear ratio.
    /// `ratio = 1.0` (no change) maps to `1.0` regardless of cap.
    private static func capLogRatio(_ ratio: Float, cap: Float) -> Float {
        let logR = log2(max(ratio, 1e-6))
        let cappedLog = max(-cap, min(cap, logR))
        return exp2(cappedLog)
    }

    /// Black-balance pedestal: per-channel dark-patch sample passes through as offsets.
    ///
    /// **Important:** the BB pedestal is subtracted at the *end* of the GPU color
    /// pipeline (after brightness/contrast/saturation/gamma) per `ColorShaders.metal`
    /// step 5. The sample fed in here MUST come from a render where **BCSG is
    /// applied and BB is zeroed** — typically `CameraEngine.sampleCenterPatchForBBCalibration`,
    /// which runs a one-shot Pass-2 encode into a scratch texture with BB
    /// temporarily zeroed. This satisfies two requirements simultaneously:
    /// the sample is in the same color space the pedestal will operate on
    /// (BCSG applied), and it isn't biased by the prior pedestal (BB zeroed).
    /// Caller writes these into `ProcessingParameters.blackR/G/B`.
    ///
    /// `Constants.blackBalanceOverscan` (1.5×) over-subtracts the trimmed-mean
    /// sample. The sample is the *average* of the patch, but per-pixel noise
    /// means many pixels sit above the mean — subtracting only the mean leaves
    /// the brighter end of the dark-patch distribution above zero. Multiplying
    /// by 1.5 drives roughly the upper σ of pixel noise to the clamp floor,
    /// making the calibrated dark patch render as actual black on iPad HITL.
    public static func blackBalanceOffsets(sample: RgbSample) -> (r: Double, g: Double, b: Double) {
        let k = Constants.blackBalanceOverscan
        return (sample.r * k, sample.g * k, sample.b * k)
    }

}
