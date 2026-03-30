#pragma once
// Flat array indices for JNI metadata transfer between Kotlin and C++.
//
// The Kotlin side (CameraController) packs Camera2 CaptureResult values into
// two primitive arrays — long[] and int[] — at these fixed offsets before
// crossing the JNI boundary. The C++ side reads them by the same indices.
//
// IMPORTANT: This file and MetadataLayout.kt must stay in sync. Any addition,
// removal, or reordering here requires an identical change in Kotlin and vice
// versa. The static_asserts below catch *_COUNT mismatches at compile time.

namespace cam::meta {

// ---------------------------------------------------------------------------
// long[] — 64-bit sensor values
// ---------------------------------------------------------------------------
constexpr int LONG_COUNT              = 5;
constexpr int LONG_FRAME_NUMBER       = 0; ///< Monotonic frame counter
constexpr int LONG_TIMESTAMP_NS       = 1; ///< Sensor start timestamp (ns)
constexpr int LONG_EXPOSURE_NS        = 2; ///< Exposure duration (ns)
constexpr int LONG_FRAME_DURATION     = 3; ///< Total frame duration (ns)
constexpr int LONG_ROLLING_SHUTTER_SKEW = 4; ///< Rolling shutter skew (ns)

// ---------------------------------------------------------------------------
// int[] — 32-bit control/state values
// ---------------------------------------------------------------------------
constexpr int INT_COUNT    = 4;
constexpr int INT_ISO      = 0; ///< Sensor sensitivity (ISO equivalent)
constexpr int INT_AE_STATE = 1; ///< AE state (CaptureResult.CONTROL_AE_STATE_*)
constexpr int INT_AF_STATE = 2; ///< AF state (CaptureResult.CONTROL_AF_STATE_*)
constexpr int INT_AWB_STATE = 3; ///< AWB state (CaptureResult.CONTROL_AWB_STATE_*)

// Compile-time verification: catch COUNT mismatches between .h and .kt at
// NDK build time rather than at runtime.
static_assert(LONG_COUNT == 5, "MetadataLayout LONG_COUNT mismatch");
static_assert(INT_COUNT  == 4, "MetadataLayout INT_COUNT mismatch");

} // namespace cam::meta
