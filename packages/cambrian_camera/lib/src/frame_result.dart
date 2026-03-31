// Copyright (c) 2025 Cambrian. All rights reserved.

/// Actual sensor values reported by the camera hardware after each frame.
///
/// All fields are nullable — null means the hardware did not report that value
/// for this frame (e.g. focus distance is null on fixed-focus cameras).
///
/// Delivered via [CambrianCamera.frameResultStream] at approximately 3 Hz.
class FrameResult {
  const FrameResult({
    this.iso,
    this.exposureTimeNs,
    this.focusDistanceDiopters,
    this.wbGainR,
    this.wbGainG,
    this.wbGainB,
  });

  /// Actual sensor sensitivity (ISO) used for this frame.
  final int? iso;

  /// Actual exposure duration in nanoseconds used for this frame.
  final int? exposureTimeNs;

  /// Actual focus distance in diopters (1/metres). 0.0 = infinity.
  final double? focusDistanceDiopters;

  /// Red channel gain from COLOR_CORRECTION_GAINS.
  final double? wbGainR;

  /// Green channel gain (average of greenEven and greenOdd).
  final double? wbGainG;

  /// Blue channel gain from COLOR_CORRECTION_GAINS.
  final double? wbGainB;
}
