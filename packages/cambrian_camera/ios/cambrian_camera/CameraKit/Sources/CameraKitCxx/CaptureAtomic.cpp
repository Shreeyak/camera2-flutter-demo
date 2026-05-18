// CaptureAtomic — C++ std::atomic<bool> capture-in-flight guard.
// Retires scaffolding:07:swift-side-capture-atomic; Invariant 7 now lives here.
#include "CaptureAtomic.hpp"
#include "PixelSinkCallbacks.h"

void* capture_atomic_create(void) {
    return new CaptureAtomicImpl();
}

void capture_atomic_destroy(void* handle) {
    delete static_cast<CaptureAtomicImpl*>(handle);
}

bool capture_atomic_try_acquire(void* handle) {
    auto* a = static_cast<CaptureAtomicImpl*>(handle);
    bool expected = false;
    return a->flag.compare_exchange_strong(expected, true,
        std::memory_order_acq_rel, std::memory_order_relaxed);
}

void capture_atomic_release(void* handle) {
    static_cast<CaptureAtomicImpl*>(handle)->flag.store(false, std::memory_order_release);
}
