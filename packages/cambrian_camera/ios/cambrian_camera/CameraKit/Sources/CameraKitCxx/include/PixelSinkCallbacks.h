#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include "PixelSinkMetrics.h"

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - C-ABI callback function pointer types (D-03)

typedef void (*OnFrameFn)(void* context, uint32_t stream,
                          uint64_t frameNumber, int64_t presentationTimeNs,
                          void* surface);
typedef void (*OnOverwriteFn)(void* context, uint32_t stream);
typedef void (*OnErrorFn)(void* context, int32_t code);

typedef struct {
    OnFrameFn     on_frame;
    OnOverwriteFn on_overwrite;
    OnErrorFn     on_error;
    void*         context;
} PixelSinkCallbacks;

// MARK: - PixelSinkPool C-ABI (pixel_sink_pool_*)

void*    pixel_sink_pool_create(void);
void     pixel_sink_pool_destroy(void* handle);
uint64_t pixel_sink_pool_register(void* handle, uint32_t stream, PixelSinkCallbacks cbs);
void     pixel_sink_pool_unregister(void* handle, uint64_t token);
void     pixel_sink_pool_dispatch(void* handle, uint32_t stream,
                                  uint64_t frameNumber, int64_t presentationTimeNs,
                                  void* surface);
unsigned pixel_sink_pool_consumer_count(void* handle, uint32_t stream);
uintptr_t pixel_sink_pool_raw_pointer(void* handle);

// MARK: - D-11 observability (mailbox-overwrite metrics)

// Records a mailbox-overwrite event for `stream` (cumulative per-lane counter)
// and notifies that lane's registered consumers via their on_overwrite callback.
void     pixel_sink_pool_note_overwrite(void* handle, uint32_t stream);
// Current cumulative mailbox-overwrite count for `stream`.
uint64_t pixel_sink_pool_overwrite_count(void* handle, uint32_t stream);
// Registers the per-window metrics callback (nullptr clears it).
void     pixel_sink_pool_set_metrics_callback(void* handle, MetricsCallbackFn cb, void* context);
// Forces an immediate metrics emission for every lane (test seam; the pool
// otherwise emits automatically once per FPS measurement window).
void     pixel_sink_pool_emit_metrics(void* handle);

// MARK: - CaptureAtomic C-ABI (capture_atomic_*)

void* capture_atomic_create(void);
void  capture_atomic_destroy(void* handle);
bool  capture_atomic_try_acquire(void* handle);
void  capture_atomic_release(void* handle);

// Phase 1B (2026-05-15): the canny_stub_* C-ABI relocated to the
// eva-swift-stitch app target — see eva-swift-stitch/AppCxx/include/CannyConsumer.h.

#ifdef __cplusplus
}
#endif
