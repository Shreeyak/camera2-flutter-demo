#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Per-lane mailbox-overwrite metrics emitted by the C++ PixelSinkPool (D-11).
// `mailbox_overwrite_count` is cumulative for the lane since pool creation;
// the Swift facade differences successive samples into per-window deltas.
typedef struct {
    uint32_t stream;
    uint64_t mailbox_overwrite_count;
} PixelSinkMetrics;

// Metrics callback invoked once per FPS measurement window, once per lane.
// `context` is the opaque pointer registered alongside the callback.
typedef void (*MetricsCallbackFn)(void* context, PixelSinkMetrics metrics);

#ifdef __cplusplus
}
#endif
