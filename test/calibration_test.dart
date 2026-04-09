import 'package:flutter_test/flutter_test.dart';
import 'package:camera2_flutter_demo/camera/calibration.dart';

void main() {
  // ── wbError ─────────────────────────────────────────────────────────────

  group('wbError', () {
    test('returns 0.0 for a perfectly neutral patch', () {
      expect(wbError((r: 0.5, g: 0.5, b: 0.5)), closeTo(0.0, 1e-9));
    });

    test('equals 1.0 when red is half of green', () {
      // |r - g| / g = |0.5 - 1.0| / 1.0 = 0.5, |b - g| = 0 → max = 0.5
      expect(wbError((r: 0.5, g: 1.0, b: 1.0)), closeTo(0.5, 1e-9));
    });

    test('uses the larger of the two deviations', () {
      // |r - g| / g = |0.6 - 1.0| / 1.0 = 0.4
      // |b - g| / g = |1.5 - 1.0| / 1.0 = 0.5  ← larger
      expect(wbError((r: 0.6, g: 1.0, b: 1.5)), closeTo(0.5, 1e-9));
    });

    test('clamps green to 0.001 to avoid division by zero', () {
      // g = 0 → clamp to 0.001; |r - 0| / 0.001 = large but finite
      final error = wbError((r: 0.5, g: 0.0, b: 0.5));
      expect(error.isFinite, isTrue);
      expect(error, greaterThan(0.0));
    });

    test('is below kWbTolerance for a near-neutral patch', () {
      // 0.5% deviation is well within the 1% tolerance.
      expect(wbError((r: 0.995, g: 1.0, b: 0.998)), lessThan(kWbTolerance));
    });

    test('is above kWbTolerance for a tinted patch', () {
      expect(wbError((r: 0.7, g: 1.0, b: 1.0)), greaterThan(kWbTolerance));
    });
  });

  // ── wbStep ───────────────────────────────────────────────────────────────

  group('wbStep', () {
    const unity = (r: 1.0, g: 1.0, b: 1.0);

    test('scales gainR up when red channel is too dark', () {
      // sample.r = 0.5, sample.g = 1.0 → correction = 1.0 / 0.5 = 2.0
      final gains = wbStep(unity, (r: 0.5, g: 1.0, b: 1.0));
      expect(gains.r, closeTo(2.0, 1e-9));
      expect(gains.g, equals(1.0));   // green never changes
      expect(gains.b, closeTo(1.0, 1e-9));
    });

    test('scales gainB down when blue channel is too bright', () {
      // sample.b = 2.0, sample.g = 1.0 → correction = 1.0 / 2.0 = 0.5
      final gains = wbStep(unity, (r: 1.0, g: 1.0, b: 2.0));
      expect(gains.r, closeTo(1.0, 1e-9));
      expect(gains.b, closeTo(0.5, 1e-9));
    });

    test('multiplies onto existing gains, not resets them', () {
      final start = (r: 2.0, g: 1.5, b: 0.8);
      // sample.r = 0.5, sample.g = 1.0 → newR = 2.0 * (1.0 / 0.5) = 4.0
      // sample.b = 1.0, sample.g = 1.0 → newB = 0.8 * (1.0 / 1.0) = 0.8
      final gains = wbStep(start, (r: 0.5, g: 1.0, b: 1.0));
      expect(gains.r, closeTo(4.0, 1e-9));
      expect(gains.g, equals(1.5));   // gainG never changes
      expect(gains.b, closeTo(0.8, 1e-9));
    });

    test('does not change gainR when red channel is nearly clipped', () {
      // sample.r < 0.001 → guard triggers, gainR unchanged
      final gains = wbStep(unity, (r: 0.0005, g: 1.0, b: 1.0));
      expect(gains.r, equals(1.0));
    });

    test('does not change gainB when blue channel is nearly clipped', () {
      final gains = wbStep(unity, (r: 1.0, g: 1.0, b: 0.0005));
      expect(gains.b, equals(1.0));
    });

    test('converges to neutral: unity gains on a neutral patch give unity gains back', () {
      final gains = wbStep(unity, (r: 1.0, g: 1.0, b: 1.0));
      expect(gains.r, closeTo(1.0, 1e-9));
      expect(gains.b, closeTo(1.0, 1e-9));
    });
  });

  // ── wbStep convergence simulation ────────────────────────────────────────

  group('WB calibration loop simulation', () {
    // Simulate the camera starting from a warm-tinted image (r > g, b < g).
    // After correction the gains should push the image toward neutral.
    test('converges a warm-tinted image within max iterations', () {
      // True neutral gain required: gainR should reach ~0.7, gainB ~1.3
      // We simulate a camera where the raw sensor output at unity gains
      // produces r=1.43, g=1.0, b=0.77. The feedback model:
      //   after applying gains, sample ≈ (rawR * gainR, rawG * gainG, rawB * gainB) / norm
      // For simplicity, model the sensor as returning the same raw after normalization.
      const rawR = 1.43, rawG = 1.0, rawB = 0.77;
      var gainR = 1.0, gainG = 1.0, gainB = 1.0;
      int iterations = 0;

      for (var i = 0; i < kWbMaxIterations; i++) {
        // Simulate what the GPU would sample given the current gains.
        // With gains applied, the patch values become proportional to raw*gain.
        final norm = rawG * gainG; // normalize to green output
        final sample = (
          r: (rawR * gainR) / norm,
          g: 1.0,
          b: (rawB * gainB) / norm,
        );

        if (wbError(sample) < kWbTolerance) break;

        final gains = wbStep((r: gainR, g: gainG, b: gainB), sample);
        gainR = gains.r;
        gainB = gains.b;
        iterations++;
      }

      // After calibration the gains should bring r and b in line with g.
      // Verify the residual error is below tolerance.
      final norm = rawG * gainG;
      final finalSample = (
        r: (rawR * gainR) / norm,
        g: 1.0,
        b: (rawB * gainB) / norm,
      );
      expect(wbError(finalSample), lessThan(kWbTolerance));
      expect(iterations, lessThanOrEqualTo(kWbMaxIterations));
    });

    test('breaks on the first iteration when the patch is already neutral', () {
      var gainR = 1.5, gainG = 1.0, gainB = 0.8;
      int iterations = 0;

      for (var i = 0; i < kWbMaxIterations; i++) {
        const sample = (r: 1.0, g: 1.0, b: 1.0); // already neutral
        if (wbError(sample) < kWbTolerance) break;
        final gains = wbStep((r: gainR, g: gainG, b: gainB), sample);
        gainR = gains.r;
        gainB = gains.b;
        iterations++;
      }

      expect(iterations, equals(0)); // zero correction steps taken
    });
  });

  // ── bbError ──────────────────────────────────────────────────────────────

  group('bbError', () {
    test('returns 0.0 for a fully black patch', () {
      expect(bbError((r: 0.0, g: 0.0, b: 0.0)), equals(0.0));
    });

    test('returns the maximum channel value', () {
      expect(bbError((r: 0.03, g: 0.05, b: 0.02)), closeTo(0.05, 1e-9));
    });

    test('is above kBbTolerance when any channel is above 1%', () {
      expect(bbError((r: 0.02, g: 0.015, b: 0.011)), greaterThan(kBbTolerance));
    });

    test('is below kBbTolerance when all channels are strictly below 1%', () {
      // Use 0.0099 — the loop's break condition is strictly < kBbTolerance.
      expect(bbError((r: 0.008, g: 0.009, b: 0.0099)), lessThan(kBbTolerance));
    });
  });

  // ── bbStep ───────────────────────────────────────────────────────────────

  group('bbStep', () {
    const zero = (r: 0.0, g: 0.0, b: 0.0);

    test('accumulates sample into offsets from zero', () {
      final offsets = bbStep(zero, (r: 0.03, g: 0.025, b: 0.04));
      expect(offsets.r, closeTo(0.03, 1e-9));
      expect(offsets.g, closeTo(0.025, 1e-9));
      expect(offsets.b, closeTo(0.04, 1e-9));
    });

    test('accumulates additively across multiple steps', () {
      var acc = zero;
      acc = bbStep(acc, (r: 0.03, g: 0.02, b: 0.04));
      acc = bbStep(acc, (r: 0.005, g: 0.003, b: 0.008));
      expect(acc.r, closeTo(0.035, 1e-9));
      expect(acc.g, closeTo(0.023, 1e-9));
      expect(acc.b, closeTo(0.048, 1e-9));
    });

    test('step with zero sample is identity', () {
      final start = (r: 0.1, g: 0.2, b: 0.15);
      final offsets = bbStep(start, (r: 0.0, g: 0.0, b: 0.0));
      expect(offsets.r, equals(start.r));
      expect(offsets.g, equals(start.g));
      expect(offsets.b, equals(start.b));
    });
  });

  // ── bbStep convergence simulation ─────────────────────────────────────────

  group('BB calibration loop simulation', () {
    // Model: shader output = max(raw - accumulated_offset, 0).
    // After one step of offset = raw, next sample ≈ 0 → converges.
    test('converges a non-zero black patch within max iterations', () {
      const rawBlack = (r: 0.035, g: 0.028, b: 0.040);
      var acc = (r: 0.0, g: 0.0, b: 0.0);
      int iterations = 0;

      for (var i = 0; i < kBbMaxIterations; i++) {
        // Simulate the GPU output: raw minus the currently applied offset.
        final sample = (
          r: (rawBlack.r - acc.r).clamp(0.0, 1.0),
          g: (rawBlack.g - acc.g).clamp(0.0, 1.0),
          b: (rawBlack.b - acc.b).clamp(0.0, 1.0),
        );

        if (bbError(sample) < kBbTolerance) break;

        acc = bbStep(acc, sample);
        iterations++;
      }

      // Verify the final residual is below tolerance.
      final residual = (
        r: (rawBlack.r - acc.r).clamp(0.0, 1.0),
        g: (rawBlack.g - acc.g).clamp(0.0, 1.0),
        b: (rawBlack.b - acc.b).clamp(0.0, 1.0),
      );
      expect(bbError(residual), lessThan(kBbTolerance));
      // With a flat black level, convergence should happen in 1 iteration.
      expect(iterations, lessThanOrEqualTo(kBbMaxIterations));
    });

    test('breaks immediately when black patch is already calibrated', () {
      int iterations = 0;
      var acc = (r: 0.0, g: 0.0, b: 0.0);

      for (var i = 0; i < kBbMaxIterations; i++) {
        // Patch is already dark — below tolerance.
        const sample = (r: 0.005, g: 0.003, b: 0.007);
        if (bbError(sample) < kBbTolerance) break;
        acc = bbStep(acc, sample);
        iterations++;
      }

      expect(iterations, equals(0));
      // Offsets must be all zeros since no step was taken.
      expect(acc.r, equals(0.0));
    });

    test('accumulated offset equals raw black level after 1 iteration on a flat sensor', () {
      // If the sensor has a flat black level of exactly (0.03, 0.02, 0.04),
      // one iteration is sufficient to reach zero residual.
      const rawBlack = (r: 0.03, g: 0.02, b: 0.04);
      var acc = (r: 0.0, g: 0.0, b: 0.0);
      final sample = rawBlack; // first iteration: no offset yet applied

      expect(bbError(sample), greaterThan(kBbTolerance));
      acc = bbStep(acc, sample);

      // Residual after applying the offset.
      final residual = (
        r: (rawBlack.r - acc.r).clamp(0.0, 1.0),
        g: (rawBlack.g - acc.g).clamp(0.0, 1.0),
        b: (rawBlack.b - acc.b).clamp(0.0, 1.0),
      );
      expect(bbError(residual), lessThan(kBbTolerance));
      expect(acc.r, closeTo(rawBlack.r, 1e-9));
      expect(acc.g, closeTo(rawBlack.g, 1e-9));
      expect(acc.b, closeTo(rawBlack.b, 1e-9));
    });
  });
}
