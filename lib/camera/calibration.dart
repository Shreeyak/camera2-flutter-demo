/// Pure calibration math for White Balance and Black Balance.
///
/// These functions contain no Flutter or camera dependencies — they operate
/// only on numeric inputs and return new values. Extracting them here makes
/// the algorithms independently testable.
library;

/// A sampled RGB triple from the center patch of the GPU framebuffer.
/// All values are normalized to [0.0, 1.0].
typedef RgbSample = ({double r, double g, double b});

/// WB gain triple: (gainR, gainG, gainB).
typedef WbGains = ({double r, double g, double b});

/// BB accumulated offset triple: (blackR, blackG, blackB).
typedef BbOffsets = ({double r, double g, double b});

// ── White Balance ────────────────────────────────────────────────────────────

/// Maximum 10 iterations; break when [wbError] drops below this.
const double kWbTolerance = 0.01;

/// Maximum number of WB calibration iterations.
const int kWbMaxIterations = 10;

/// Proportional error for WB: max per-channel deviation from green, normalized
/// by green (clamped to avoid divide-by-zero).
///
/// Returns 0.0 when the sample is exactly neutral (r == g == b).
double wbError(RgbSample s) {
  final errR = (s.r - s.g).abs();
  final errB = (s.b - s.g).abs();
  return (errR > errB ? errR : errB) / s.g.clamp(0.001, 1.0);
}

/// Applies one proportional-correction step to the WB gains.
///
/// Green is the fixed reference channel. Each iteration scales gainR and gainB
/// by the ratio `green / channel` so that subsequent frames push the sampled
/// patch toward neutral.
///
/// The 0.001 guard prevents divide-by-zero on a fully clipped channel.
WbGains wbStep(WbGains gains, RgbSample s) {
  final newR = s.r > 0.001 ? gains.r * (s.g / s.r) : gains.r;
  final newB = s.b > 0.001 ? gains.b * (s.g / s.b) : gains.b;
  return (r: newR, g: gains.g, b: newB);
}

// ── Black Balance ────────────────────────────────────────────────────────────

/// Maximum 10 iterations; break when [bbError] drops below this.
const double kBbTolerance = 0.01;

/// Maximum number of BB calibration iterations.
const int kBbMaxIterations = 10;

/// Maximum channel value in [s]. When this is below [kBbTolerance] the black
/// point is considered calibrated and no further accumulation is needed.
double bbError(RgbSample s) =>
    s.r > s.g
        ? (s.r > s.b ? s.r : s.b)
        : (s.g > s.b ? s.g : s.b);

/// Accumulates one BB correction step.
///
/// The GPU shader subtracts the accumulated offset: `output = max(input − acc, 0)`.
/// Adding `sample` to the accumulator moves the black point down by the
/// current residual; the next sample will measure what remains.
BbOffsets bbStep(BbOffsets acc, RgbSample s) =>
    (r: acc.r + s.r, g: acc.g + s.g, b: acc.b + s.b);
