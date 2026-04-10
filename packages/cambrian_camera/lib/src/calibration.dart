/// Pure calibration math for White Balance and Black Balance.
///
/// These functions contain no Flutter or camera dependencies — they operate
/// only on numeric inputs and return new values, making them independently
/// testable.
///
/// High-level callers should use [CambrianCamera.calibrateWhiteBalance] and
/// [CambrianCamera.calibrateBlackBalance] instead of calling these primitives
/// directly.
library;

/// The trimmed-mean R, G, B of the 96×96 center patch sampled from the GPU
/// framebuffer. All values are normalized to [0.0, 1.0].
typedef RgbSample = ({double r, double g, double b});

/// WB gain triple: (gainR, gainG, gainB).
typedef WbGains = ({double r, double g, double b});

/// BB accumulated offset triple: (blackR, blackG, blackB).
typedef BbOffsets = ({double r, double g, double b});

/// Result returned by [CambrianCamera.calibrateWhiteBalance].
///
/// [gains] — converged R/G/B gain multipliers; pass to [WhiteBalance.manual].
/// [patchBefore] — mean RGB of the 96×96 center patch sampled before any
///   corrections were applied. Each channel in [0.0, 1.0].
/// [patchAfter] — mean RGB of the 96×96 center patch sampled after the final
///   gains settled. Useful for before/after display in the UI.
typedef WbCalibrationResult = ({
  WbGains gains,
  RgbSample patchBefore,
  RgbSample patchAfter,
});

/// Result returned by [CambrianCamera.calibrateBlackBalance].
///
/// [offsets] — converged R/G/B black-level offsets; store and toggle via
///   [ProcessingParams.copyWith].
/// [patchBefore] — mean RGB of the 96×96 center patch sampled before any
///   offsets were applied. Each channel in [0.0, 1.0].
/// [patchAfter] — mean RGB of the 96×96 center patch sampled after the final
///   offsets settled.
typedef BbCalibrationResult = ({
  BbOffsets offsets,
  RgbSample patchBefore,
  RgbSample patchAfter,
});

// ── Shared calibration timing ────────────────────────────────────────────────

/// Milliseconds to wait between calibration loop iterations.
///
/// ≈6 frames at 30 fps — enough time for Camera2 to apply new gains/offsets
/// and expose a fresh frame before the next patch sample is taken.
const int kCalibrationSettleMs = 200;

// ── White Balance ────────────────────────────────────────────────────────────

/// Channels below this value are treated as fully clipped — avoids
/// divide-by-zero in gain and error calculations.
const double _kClipGuard = 0.001;

/// Per-channel error threshold at which WB is considered converged.
///
/// 0.01 ≈ 1% deviation — imperceptible to the human eye under typical
/// viewing conditions.
const double kWbTolerance = 0.01;

/// Hard cap on WB loop iterations.
///
/// At [kCalibrationSettleMs] per step, 10 iterations = up to 2 s total;
/// neutral scenes typically converge in 3–5 steps.
const int kWbMaxIterations = 10;

/// Proportional error for WB: max per-channel deviation from green, normalized
/// by green (clamped to avoid divide-by-zero).
///
/// Returns 0.0 when the sample is exactly neutral (r == g == b).
double wbError(RgbSample s) {
  final errR = (s.r - s.g).abs();
  final errB = (s.b - s.g).abs();
  return (errR > errB ? errR : errB) / s.g.clamp(_kClipGuard, 1.0);
}

/// Applies one proportional-correction step to the WB gains.
///
/// Green is the fixed reference channel. Each iteration scales gainR and gainB
/// by the ratio `green / channel` so that subsequent frames push the sampled
/// patch toward neutral.
///
/// Channels below [_kClipGuard] are skipped to avoid divide-by-zero on a
/// fully clipped channel.
WbGains wbStep(WbGains gains, RgbSample s) {
  final newR = s.r > _kClipGuard ? gains.r * (s.g / s.r) : gains.r;
  final newB = s.b > _kClipGuard ? gains.b * (s.g / s.b) : gains.b;
  return (r: newR, g: gains.g, b: newB);
}

// ── Black Balance ────────────────────────────────────────────────────────────

/// Per-channel error threshold at which BB is considered converged.
///
/// 0.01 ≈ 1% residual brightness — below the eye's detection threshold for
/// black-level lift under normal display conditions.
const double kBbTolerance = 0.01;

/// Hard cap on BB loop iterations.
///
/// At [kCalibrationSettleMs] per step, 10 iterations = up to 2 s total;
/// a dark scene typically converges in 2–4 steps.
const int kBbMaxIterations = 10;

/// Maximum channel value in [s]. When this is below [kBbTolerance] the black
/// point is considered calibrated and no further accumulation is needed.
double bbError(RgbSample s) =>
    s.r > s.g ? (s.r > s.b ? s.r : s.b) : (s.g > s.b ? s.g : s.b);

/// Accumulates one BB correction step.
///
/// The GPU shader subtracts the accumulated offset: `output = max(input − acc, 0)`.
/// Adding `sample` to the accumulator moves the black point down by the
/// current residual; the next sample will measure what remains.
BbOffsets bbStep(BbOffsets acc, RgbSample s) =>
    (r: acc.r + s.r, g: acc.g + s.g, b: acc.b + s.b);
